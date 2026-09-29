import SwiftUI
import Combine
import AVFoundation
import ImageIO
import UIKit

struct DemoScreen {
    let title: String
    let icon: String
}

/// Состояние записи нового жеста.
enum RecordingState: Equatable {
    case idle
    case countdown(Int)
    case recording(Double)   // прогресс 0…1
}

/// Данные, которые меняются на каждом кадре. Вынесены отдельно от `GestureViewModel`,
/// чтобы 30 раз в секунду перерисовывались только скелет рук и индикаторы, а не весь интерфейс.
@MainActor
final class LiveState: ObservableObject {
    /// Точки найденных рук (одна или две) в координатах экрана — для отрисовки скелета.
    @Published var handPoints: [[CGPoint]] = []
    /// Прогресс удержания статичного жеста, 0…1.
    @Published var holdProgress: Double = 0
    @Published var fps = 0
    /// Плечи в координатах экрана (две точки или пусто) — для отрисовки.
    @Published var shoulders: [CGPoint] = []
}

/// Кадр для жестов с движением: все руки в кадре и отдельно ведущая (движущаяся) рука.
struct MotionSample {
    let all: FrameFeatures
    let main: FrameFeatures?
}

/// Режим подсветки.
enum LightMode: String, CaseIterable, Identifiable {
    case auto, on, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .on:   return "Всегда вкл."
        case .off:  return "Выключена"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .on:   return "flashlight.on.fill"
        case .off:  return "flashlight.off.fill"
        }
    }
}

/// Связывает камеру, распознавание и интерфейс.
/// Блоки схемы «Определение команды → Выполнение действия → Отображение результата».
@MainActor
final class GestureViewModel: ObservableObject {
    // MARK: Камера
    let camera = CameraManager()
    var session: AVCaptureSession { camera.session }
    /// Слой предпросмотра — нужен для перевода координат камеры в координаты экрана.
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .front

    // MARK: Режим
    @Published var mode: AppMode = .translate {
        didSet { applyModeSettings() }
    }

    // MARK: Результат распознавания
    /// Скелет рук, прогресс удержания и FPS — меняются на каждом кадре.
    let live = LiveState()
    @Published private(set) var handCount = 0
    var isHandDetected: Bool { handCount > 0 }
    /// Плечи найдены: положение рук относительно тела учитывается.
    @Published private(set) var isBodyDetected = false
    /// Подсказка в режиме «Перевод»: на какое слово похоже то, что сейчас в кадре, и насколько.
    @Published private(set) var hint: String?
    private var lastHintUpdate: Double = 0
    @Published private(set) var currentSign: Sign = .none
    @Published private(set) var cameraError: String?
    @Published private(set) var notice: String?
    @Published var isRecognitionEnabled = true {
        didSet { if !isRecognitionEnabled { resetRecognition() } }
    }

    // MARK: Подсветка
    @Published var lightMode: LightMode = .auto {
        didSet { applyLightMode() }
    }
    /// Подсветка включена (фонарик у задней камеры или экран у фронтальной).
    @Published private(set) var isLightOn = false
    /// Подсветка экраном (для фронтальной камеры — у неё нет фонарика).
    @Published private(set) var isScreenLightOn = false
    private var sceneBrightness: Double?
    private var darkSince: Double?
    private var brightSince: Double?
    private var lightChangedAt: Double = 0
    private var brightnessWithLight: Double?
    private var lastAutoOffAt: Double = -100
    private var offMargin: Double = 2.0
    private var savedScreenBrightness: CGFloat?
    /// Приложение на экране и активно (не свёрнуто, не открыт пункт управления или переключатель приложений).
    private var isAppActive = true
    /// Камера остановлена, пока открыта страница «Речь → текст».
    private(set) var isCameraPaused = false
    /// Ниже этой яркости (шкала APEX) сцена считается тёмной.
    private let darkLevel: Double = -1.0

    // MARK: Словарь жестов и обучение
    let library = SignLibrary()
    @Published private(set) var recording: RecordingState = .idle
    @Published private(set) var recordingWord = ""
    @Published private(set) var recordingDynamic = false
    /// Подсказка к текущей записи: какой ракурс показать.
    @Published private(set) var recordingPrompt = ""
    /// Номер ракурса и сколько их всего (запись с нескольких ракурсов).
    @Published private(set) var recordingStep = 1
    @Published private(set) var recordingSteps = 1
    private var pendingPrompts: [String] = []
    private var recordedFrames: [(time: Double, item: SignFrame)] = []
    /// Для жестов с движением: кадры только ведущей руки и скорости рук на каждом кадре —
    /// чтобы решить, жест одной рукой или двумя.
    private var recordedMainFrames: [(time: Double, item: SignFrame)] = []
    private var recordedSpeeds: [(main: Double, other: Double?)] = []
    /// Похожее слово словаря, найденное при записи (предупреждаем в конце записи).
    private var similarWord: String?
    private var recordingTooStill = false
    private var recordingStart: Double = 0
    private var recordingDuration: Double { recordingDynamic ? 2.5 : 2.0 }

    // MARK: Плечи
    /// Плечи в координатах экрана, слева направо (сглажены). Пусто — не найдены.
    private var shoulderPoints: [CGPoint] = []
    private var shoulderSmoother = ShoulderSmoother()
    private var bodyTrackingConfigured = false
    private var bodyTrackingEnabled = false
    private var bodyOrientation: CGImagePropertyOrientation?

    // MARK: Движение рук
    private var smoother = HandSmoother()
    private var motionBuffer: [(time: Double, item: MotionSample)] = []
    /// Центры рук за последние доли секунды — для скорости каждой руки.
    private var centerHistory: [(time: Double, centers: [CGPoint])] = []
    /// Где была ведущая (движущаяся) рука на прошлом кадре.
    private var mainCenter: CGPoint?
    private var spotter = MotionSpotter()
    private var lastHandSeenTime: Double = 0
    private var frameCounter = 0
    private var motionCooldownUntil: Double = 0

    // MARK: Режим «Перевод»
    @Published private(set) var phraseWords: [String] = []
    @Published private(set) var phraseHistory: [String] = []
    @Published private(set) var lastWord: String?
    @Published var isSpeechEnabled = true {
        didSet { if !isSpeechEnabled { synthesizer.stopSpeaking(at: .immediate) } }
    }
    var phraseText: String { Self.sentence(from: phraseWords) }
    /// Если рук нет в кадре дольше этого времени, фраза заканчивается сама.
    private let phrasePause: Double = 2.0

    // MARK: Режим «Управление» (демо-интерфейс)
    let screens: [DemoScreen] = [
        DemoScreen(title: "Главная", icon: "house.fill"),
        DemoScreen(title: "Музыка", icon: "music.note"),
        DemoScreen(title: "Фото", icon: "photo.fill"),
        DemoScreen(title: "Настройки", icon: "gearshape.fill")
    ]
    @Published private(set) var screenIndex = 0
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var volume = 50
    @Published private(set) var isPlaying = true
    @Published private(set) var confirmation: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var lastGesture: Gesture = .idle
    @Published private(set) var lastCommand: Command?

    private var recognizer = GestureRecognizer()
    private let synthesizer = AVSpeechSynthesizer()
    private var lastFrameTime: Double = 0
    private var fpsAverage: Double = 0
    private var lastFPSUpdate: Double = 0
    private var started = false

    init() {
        applyModeSettings()
    }

    // MARK: Запуск

    func start() async {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true   // экран не гаснет
        // Озвучка слышна, даже если на iPhone включён беззвучный режим.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])

        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            cameraError = "Нет доступа к камере. Разрешите его: Настройки → GestureControl → Камера."
            return
        }

        do {
            try camera.configure()
        } catch {
            cameraError = error.localizedDescription
            return
        }
        cameraPosition = camera.position
        camera.startRunning()

        for await frame in camera.frames {
            process(frame)
        }
    }

    /// Фронтальная ↔ задняя камера.
    func switchCamera() {
        let wasLightOn = isLightOn
        setLight(false)
        do {
            try camera.switchCamera()
            cameraPosition = camera.position
            live.handPoints = []
            centerHistory.removeAll()
            mainCenter = nil
            shoulderPoints = []
            shoulderSmoother.reset()
            bodyTrackingConfigured = false
            smoother.reset()
            sceneBrightness = nil
            resetRecognition()
            if wasLightOn { setLight(true) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            cameraError = error.localizedDescription
        }
    }

    /// Приложение свёрнуто или снова открыто.
    /// Как только приложение перестаёт быть активным (выход на главный экран, переключение приложений,
    /// пункт управления, закрытие), подсветка выключается и яркость экрана возвращается к прежней —
    /// как в других приложениях. Делать это нужно сразу: когда приложение уже в фоне, менять яркость поздно.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isAppActive = true
            if lightMode == .on && !isCameraPaused { setLight(true) }
        default:
            isAppActive = false
            setLight(false)
        }
    }

    /// Камера не нужна, пока открыта страница «Речь → текст»: останавливаем её и подсветку
    /// (яркость экрана возвращается к прежней), а при возврате — включаем снова.
    func setCameraPaused(_ paused: Bool) {
        guard paused != isCameraPaused else { return }
        isCameraPaused = paused
        if paused {
            setLight(false)
            camera.stopRunning()
            resetRecognition()
            live.handPoints = []
            live.shoulders = []
            if handCount != 0 { handCount = 0 }
        } else {
            // Страница речи переключала звук на запись — возвращаем озвучку перевода.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            if started && cameraError == nil { camera.startRunning() }
            if lightMode == .on && isAppActive { setLight(true) }
        }
    }

    private func applyModeSettings() {
        // В переводе жесты показывают быстро: короче удержание, свайпы не мешают.
        recognizer.swipesEnabled = mode == .control
        recognizer.holdDuration = mode == .translate ? 0.3 : 0.4
        resetRecognition()
    }

    private func resetRecognition() {
        recognizer.reset()
        spotter.reset()
        motionBuffer.removeAll()
        currentSign = .none
        live.holdProgress = 0
    }

    // MARK: Обработка кадра

    private func process(_ frame: CameraFrame) {
        let now = CACurrentMediaTime()
        updateFPS(now: now)

        updateLight(brightness: frame.brightness, now: now)

        // Координаты камеры → координаты экрана (учитывает поворот и зеркалирование фронтальной камеры),
        // затем сглаживание дрожания точек.
        var samples: [HandSample] = []
        var width: CGFloat = 0
        if !frame.hands.isEmpty, let layer = previewLayer {
            width = layer.bounds.width
            samples = frame.hands.map { hand in
                HandSample(points: hand.points.map { point in
                               point.x < 0 ? CGPoint(x: -1, y: -1) : layer.layerPointConverted(fromCaptureDevicePoint: point)
                           },
                           confidence: hand.confidence,
                           chirality: hand.chirality)
            }
        }
        samples = smoother.smooth(samples, time: now)

        // Для рисования скелета — только уверенно найденные точки.
        let screenHands = samples.map { $0.thresholded() }
        if handCount != screenHands.count { handCount = screenHands.count }
        if !(screenHands.isEmpty && live.handPoints.isEmpty) { live.handPoints = screenHands }

        // Задняя камера видит собеседника «не в зеркале». Отражаем по горизонтали, чтобы
        // жест выглядел одинаково с обеих камер, а «влево/вправо» считались со стороны жестикулирующего.
        let recognitionSamples = cameraPosition == .back ? samples.map { $0.flipped(width: width) } : samples
        let handsForRecognition = recognitionSamples.map { $0.thresholded() }

        // Плечи находятся автоматически; относительно них считается, где находятся руки.
        let shoulders = updateShoulders(frame, now: now)
        var body: BodyReference?
        if shoulders.count == 2 {
            let layerWidth = previewLayer?.bounds.width ?? 0
            body = BodyReference(shoulders: cameraPosition == .back
                                 ? shoulders.map { CGPoint(x: layerWidth - $0.x, y: $0.y) }
                                 : shoulders)
        }

        let geometries = handsForRecognition.compactMap { HandGeometry(points: $0) }
        if !geometries.isEmpty { lastHandSeenTime = now }
        let usable = recognitionSamples.filter { $0.palmSize > 10 }
        let motion = trackHands(usable, now: now)
        let mainSample = motion.main.map { usable[$0] }
        let mainVelocity = motion.main.map { motion.velocities[$0] }
        let poseFrame = SignFrame.make(from: recognitionSamples, body: body)
        let motionFrame = mainVelocity.flatMap { SignFrame.make(from: recognitionSamples, velocity: $0, body: body) }
        // Если в кадре две руки, отдельно берём ведущую: жест одной рукой должен узнаваться,
        // даже когда вторая (опущенная) рука тоже видна.
        let mainMotionFrame: SignFrame? = motionFrame?.handCount == 2
            ? mainSample.flatMap { SignFrame.make(from: [$0], velocity: mainVelocity, body: body) }
            : motionFrame
        var poseVariants: [SignFrame] = poseFrame.map { [$0] } ?? []
        if poseFrame?.handCount == 2 {
            poseVariants += usable.compactMap { SignFrame.make(from: [$0], body: body) }
        }

        // Запись нового жеста.
        switch recording {
        case .countdown:
            return
        case .recording:
            if recordingDynamic {
                if let f = motionFrame {
                    recordedFrames.append((time: now, item: f))
                    if let m = mainMotionFrame { recordedMainFrames.append((time: now, item: m)) }
                    if let main = motion.main {
                        let speeds = motion.velocities.map { Double(hypot($0.dx, $0.dy)) }
                        let other = speeds.indices.filter { $0 != main }.map { speeds[$0] }.max()
                        recordedSpeeds.append((main: speeds[main], other: other))
                    }
                }
            } else if let f = poseFrame {
                recordedFrames.append((time: now, item: f))
            }
            let elapsed = now - recordingStart
            if elapsed >= recordingDuration {
                finishRecording()
            } else {
                recording = .recording(elapsed / recordingDuration)
            }
            return
        case .idle:
            break
        }

        guard isRecognitionEnabled else {
            if hint != nil { hint = nil }
            return
        }
        defer { updateHint(now: now) }

        if mode == .translate {
            // Руки опущены — фраза закончена.
            if geometries.isEmpty, !phraseWords.isEmpty, now - lastHandSeenTime > phrasePause {
                finishPhrase()
            }
            // Жесты с движением: сравниваем последние 1,5–3 секунды с записанными жестами.
            if recognizeMotion(frame: motionFrame, mainFrame: mainMotionFrame, now: now) { return }
        }

        let poseFeatures = poseVariants.map(FrameFeatures.init)
        let result = recognizer.process(hands: handsForRecognition, time: now) { hands in
            self.classifyStatic(hands, variants: poseFeatures)
        }
        apply(result)
    }

    /// Подсказка под жестом: на какое слово похоже то, что сейчас в кадре, и насколько (100% — достаточно
    /// для распознавания). Помогает понять, почему слово не засчитывается и нужно ли сдвинуть «Чувствительность».
    private func updateHint(now: Double) {
        guard now - lastHintUpdate >= 0.25 else { return }
        lastHintUpdate = now
        // Берём самое похожее слово за последние 0,25 с и начинаем копить заново.
        defer { library.resetCandidate() }
        var text: String?
        if mode == .translate, currentSign == .none, isHandDetected, let candidate = library.lastCandidate {
            let percent = Int((max(0, min(1, 2 - candidate.ratio)) * 100).rounded())
            if percent >= 20 {
                var line = "Похоже на «\(candidate.word)» — \(percent)%"
                if let reason = candidate.reason { line += " (\(reason))" }
                text = line
            }
        }
        if hint != text { hint = text }
    }

    /// Плечи в координатах экрана. Камера ищет их на каждом кадре; здесь они сглаживаются
    /// тем же фильтром, что и точки рук, и следуют за человеком так же быстро.
    private func updateShoulders(_ frame: CameraFrame, now: Double) -> [CGPoint] {
        guard let layer = previewLayer else { return [] }

        // Тело Vision находит, только если человек на кадре стоит прямо. Как повернуть кадр,
        // определяем по слою предпросмотра — так же камера показана на экране.
        let enabled = library.useShoulders
        let orientation = Self.uprightOrientation(of: layer)
        if !bodyTrackingConfigured || enabled != bodyTrackingEnabled || orientation != bodyOrientation {
            bodyTrackingConfigured = true
            bodyTrackingEnabled = enabled
            bodyOrientation = orientation
            camera.configureBodyTracking(enabled: enabled, orientation: orientation)
        }

        if enabled {
            let found = frame.body.map { body in
                body.shoulders
                    .map { layer.layerPointConverted(fromCaptureDevicePoint: $0) }
                    .sorted { $0.x < $1.x }
            }
            shoulderPoints = shoulderSmoother.smooth(found, time: now)
        } else {
            shoulderSmoother.reset()
            shoulderPoints = []
        }

        if live.shoulders != shoulderPoints { live.shoulders = shoulderPoints }
        let detected = shoulderPoints.count == 2
        if isBodyDetected != detected { isBodyDetected = detected }
        return shoulderPoints
    }

    /// Как повернуть кадр камеры, чтобы человек на нём стоял прямо, как на экране.
    /// Смотрим, куда на экране уходят оси кадра: так не нужно гадать, как установлена камера.
    private static func uprightOrientation(of layer: AVCaptureVideoPreviewLayer) -> CGImagePropertyOrientation? {
        let o = layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 0.5, y: 0.5))
        let x = layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 0.6, y: 0.5))
        let y = layer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 0.5, y: 0.6))
        let ex = CGPoint(x: x.x - o.x, y: x.y - o.y)
        let ey = CGPoint(x: y.x - o.x, y: y.y - o.y)
        if abs(ex.y) > abs(ex.x) {
            // Ось X кадра идёт по вертикали экрана: кадр повёрнут на 90°.
            return ex.y < 0 ? .left : .right
        }
        if abs(ey.y) > abs(ey.x) {
            return ey.y > 0 ? .up : .down
        }
        return nil   // слой ещё не готов
    }

    private func updateFPS(now: Double) {
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0 {
                fpsAverage = fpsAverage == 0 ? 1 / dt : fpsAverage * 0.9 + (1 / dt) * 0.1
            }
        }
        lastFrameTime = now
        // Показываем FPS два раза в секунду, а не на каждом кадре.
        if now - lastFPSUpdate >= 0.5 {
            lastFPSUpdate = now
            let value = Int(fpsAverage.rounded())
            if live.fps != value { live.fps = value }
        }
    }

    /// Скорость ведущей руки в ладонях в секунду. Ведущая — та, что ближе к прошлому положению
    /// (чтобы не «прыгать» между руками). Скорость считается по смещению примерно за 0,1 с:
    /// так она меньше зависит от дрожания точек, чем смещение за один кадр.
    private func trackHands(_ hands: [HandSample], now: Double) -> (velocities: [CGVector], main: Int?) {
        centerHistory.removeAll { now - $0.time > 0.4 }
        guard !hands.isEmpty else {
            centerHistory.removeAll()
            mainCenter = nil
            return ([], nil)
        }
        let reference = centerHistory.last { now - $0.time >= 0.08 }
        centerHistory.append((time: now, centers: hands.map(\.center)))

        let velocities: [CGVector] = hands.map { hand in
            let size = hand.palmSize
            guard let reference, size > 0,
                  let start = reference.centers.min(by: { dist($0, hand.center) < dist($1, hand.center) }),
                  dist(start, hand.center) < size * 3 else { return .zero }
            let dt = CGFloat(now - reference.time)
            return CGVector(dx: (hand.center.x - start.x) / size / dt,
                            dy: (hand.center.y - start.y) / size / dt)
        }
        let speeds = velocities.map { hypot($0.dx, $0.dy) }

        // Прошлая ведущая рука — та, что ближе к её прошлому положению; в начале — самая крупная.
        var main = hands.indices.max { hands[$0].palmSize < hands[$1].palmSize }!
        if let previous = mainCenter {
            main = hands.indices.min { dist(hands[$0].center, previous) < dist(hands[$1].center, previous) }!
        }
        // Ведущей становится другая рука, если она движется заметно быстрее
        // (неподвижная опущенная рука не должна «перехватывать» жест).
        if let fastest = speeds.indices.max(by: { speeds[$0] < speeds[$1] }), fastest != main,
           speeds[fastest] > 1.0, speeds[fastest] > speeds[main] * 1.5 {
            main = fastest
        }
        mainCenter = hands[main].center
        return (velocities, main)
    }

    /// Возвращает true, если распознан жест с движением.
    private func recognizeMotion(frame: SignFrame?, mainFrame: SignFrame?, now: Double) -> Bool {
        guard library.hasDynamicSigns else { return false }

        if now - lastHandSeenTime > 0.5 { motionBuffer.removeAll() }
        if let frame, now >= motionCooldownUntil {
            let sample = MotionSample(all: FrameFeatures(frame), main: mainFrame.map(FrameFeatures.init))
            motionBuffer.append((time: now, item: sample))
        }
        let window = library.motionWindow
        motionBuffer.removeAll { now - $0.time > window }

        // Сравниваем через кадр: этого хватает при частоте последовательностей 15 кадров в секунду.
        frameCounter += 1
        guard frameCounter % 2 == 0 else { return false }

        // Кадры с равным шагом по времени — так же, как при подготовке записанного жеста.
        var best: MotionSpotter.Match?
        if frame != nil, motionBuffer.count >= 8 {
            let samples = SignMatching.resample(motionBuffer)
            var streams = [MotionStream(samples.map(\.all))]
            // Если в кадре бывает вторая рука, отдельно сравниваем ведущую руку с жестами одной рукой.
            if samples.contains(where: { $0.all.handCount == 2 }) {
                let main = samples.compactMap(\.main)
                if main.count >= 4 { streams.append(MotionStream(main)) }
            }
            best = library.bestMotion(streams)
        }
        // Жест засчитывается, когда сходство перестало расти (см. `MotionSpotter`).
        guard let id = spotter.update(best: best, time: now), let sign = library.sign(id: id) else { return false }

        motionBuffer.removeAll()
        spotter.reset()
        motionCooldownUntil = now + 0.5
        recognizer.reset()
        recognizer.latchNextSign(at: now)   // конечная поза жеста не засчитывается отдельным словом
        let recognized = Sign.custom(id: sign.id, word: sign.word)
        currentSign = recognized
        live.holdProgress = 1
        translate(recognized)
        return true
    }

    /// Статичный жест.
    /// «Перевод»: только жесты из словаря пользователя.
    /// «Управление»: встроенные жесты.
    private func classifyStatic(_ hands: [HandGeometry], variants: [FrameFeatures]) -> Sign {
        switch mode {
        case .translate:
            guard !variants.isEmpty else { return .none }
            var sticky: UUID?
            if case .custom(let id, _) = currentSign { sticky = id }
            if let sign = library.classifyPose(variants, sticky: sticky) {
                return .custom(id: sign.id, word: sign.word)
            }
            return .none
        case .control:
            guard let main = hands.max(by: { $0.size < $1.size }) else { return .none }
            let gesture = main.staticGesture()
            return gesture == .idle ? .none : .builtIn(gesture)
        }
    }

    private func apply(_ result: RecognitionResult) {
        if currentSign != result.sign { currentSign = result.sign }
        if live.holdProgress != result.holdProgress { live.holdProgress = result.holdProgress }

        guard let fired = result.fired else { return }
        switch mode {
        case .control:
            if case .builtIn(let gesture) = fired, let command = gesture.command {
                execute(command, from: gesture)
            }
        case .translate:
            translate(fired)
        }
    }

    // MARK: Автоматическая подсветка

    private func applyLightMode() {
        switch lightMode {
        case .on:
            setLight(true)
        case .off:
            setLight(false)
        case .auto:
            darkSince = nil
            brightSince = nil
            offMargin = 2.0
            if let b = sceneBrightness, b >= darkLevel { setLight(false) }
        }
    }

    /// Включает подсветку в темноте и выключает, когда стало светло.
    /// Когда подсветка включена, камера видит сцену светлее. Поэтому выключаем её,
    /// только если стало заметно светлее, чем было с подсветкой (включили свет в комнате).
    private func updateLight(brightness: Double, now: Double) {
        guard brightness.isFinite else { return }
        let smoothed = sceneBrightness.map { $0 * 0.9 + brightness * 0.1 } ?? brightness
        sceneBrightness = smoothed

        guard lightMode == .auto, recording == .idle, isAppActive, !isCameraPaused,
              now - lightChangedAt > 2 else { return }

        if !isLightOn {
            brightSince = nil
            if smoothed < darkLevel {
                if darkSince == nil { darkSince = now }
                if let since = darkSince, now - since > 1.0 {
                    // Если только что выключили, а снова темно — выключать в следующий раз осторожнее.
                    if now - lastAutoOffAt < 6 { offMargin = min(4, offMargin + 1) }
                    setLight(true)
                }
            } else {
                darkSince = nil
            }
        } else {
            darkSince = nil
            if brightnessWithLight == nil {
                brightnessWithLight = smoothed
                return
            }
            let offLevel = max(darkLevel + 2.5, (brightnessWithLight ?? smoothed) + offMargin)
            if smoothed > offLevel {
                if brightSince == nil { brightSince = now }
                if let since = brightSince, now - since > 1.5 {
                    lastAutoOffAt = now
                    setLight(false)
                }
            } else {
                brightSince = nil
            }
        }
    }

    private func setLight(_ on: Bool) {
        lightChangedAt = CACurrentMediaTime()
        brightnessWithLight = nil
        darkSince = nil
        brightSince = nil

        if on {
            if cameraPosition == .back, camera.hasTorch {
                camera.setTorch(true)
                setScreenLight(false)
            } else {
                setScreenLight(true)   // у фронтальной камеры фонарика нет — светим экраном
            }
        } else {
            camera.setTorch(false)
            setScreenLight(false)
        }
        if isLightOn != on { isLightOn = on }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private func setScreenLight(_ on: Bool) {
        guard isScreenLightOn != on else { return }
        isScreenLightOn = on
        guard let screen else { return }
        if on {
            savedScreenBrightness = screen.brightness
            screen.brightness = 1.0
        } else if let saved = savedScreenBrightness {
            screen.brightness = saved
            savedScreenBrightness = nil
        }
    }

    // MARK: Обучение новому жесту

    /// Запись нового жеста. `multiAngle` — записать сразу с трёх ракурсов (прямо, левее, правее):
    /// так жест потом лучше узнаётся, когда его показывают под углом.
    func startRecording(word: String, dynamic: Bool, multiAngle: Bool = true) {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, recording == .idle else { return }
        recordingWord = cleaned
        recordingDynamic = dynamic
        if mode != .translate { mode = .translate }

        pendingPrompts = multiAngle
            ? ["Прямо к камере",
               "Чуть поверните руку влево (или сместите телефон)",
               "Чуть поверните руку вправо (или сместите телефон)"]
            : ["Прямо к камере"]
        recordingSteps = pendingPrompts.count
        recordingStep = 0
        similarWord = nil
        recordingTooStill = false
        startNextAngle()
    }

    private func startNextAngle() {
        guard !pendingPrompts.isEmpty else { return }
        recordingPrompt = pendingPrompts.removeFirst()
        recordingStep += 1
        recordedFrames = []
        recordedMainFrames = []
        recordedSpeeds = []
        let countdown = recordingStep == 1 ? 3 : 2

        Task {
            for n in stride(from: countdown, through: 1, by: -1) {
                recording = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
            }
            recordingStart = CACurrentMediaTime()
            recording = .recording(0)
        }
    }

    private func finishRecording() {
        recording = .idle
        resetRecognition()

        let timed: [(time: Double, item: SignFrame)]
        if recordingDynamic {
            // Жест двумя руками — если вторая рука видна почти всё время и тоже движется.
            // Иначе вторая рука просто оказалась в кадре: записываем только ведущую руку.
            let withOther = recordedSpeeds.compactMap(\.other)
            let mainSpeed = recordedSpeeds.map(\.main).reduce(0, +) / Double(max(1, recordedSpeeds.count))
            let otherSpeed = withOther.reduce(0, +) / Double(max(1, withOther.count))
            let twoHanded = Double(withOther.count) >= 0.6 * Double(max(1, recordedSpeeds.count))
                && otherSpeed >= 0.4 * mainSpeed
            timed = twoHanded
                ? recordedFrames.filter { $0.item.handCount == 2 }
                : recordedMainFrames.filter { $0.item.handCount == 1 }
        } else {
            // Поза: кадры с тем числом рук, которое было видно чаще всего.
            let groups = Dictionary(grouping: recordedFrames, by: { $0.item.handCount })
            let count = groups.max { $0.value.count < $1.value.count }?.key ?? 1
            timed = recordedFrames.filter { $0.item.handCount == count }
        }
        let handCount = timed.first?.item.handCount ?? 1
        let frames = timed.map(\.item)
        recordedFrames = []
        recordedMainFrames = []
        recordedSpeeds = []
        // Похожее слово проверяем по первой записи («прямо к камере»), до того как она попадёт в словарь.
        let isFirstStep = recordingStep == 1

        var saved = false
        if recordingDynamic {
            let template = SignMatching.prepareTemplate(timed)
            if frames.count >= 15 && template.count >= 5 {
                if isFirstStep {
                    similarWord = library.similarMotion(to: template, excludingWord: recordingWord)?.word
                    recordingTooStill = SignMatching.isMostlyStill(template)
                }
                library.addMotion(word: recordingWord, frames: template)
                saved = true
            }
        } else if frames.count >= 8 {
            if isFirstStep {
                similarWord = library.similarPose(to: frames, excludingWord: recordingWord)?.word
            }
            library.addPoses(word: recordingWord, frames: frames)
            saved = true
        }

        guard saved else {
            pendingPrompts = []
            failedNotice()
            return
        }
        if pendingPrompts.isEmpty {
            savedNotice(handCount: handCount)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            startNextAngle()
        }
    }

    private func savedNotice(handCount: Int) {
        let hands = handCount == 2 ? "двумя руками" : "одной рукой"
        var text = "Жест «\(recordingWord)» \(hands) сохранён"
        if let similarWord {
            text += "\nОн похож на «\(similarWord)» — их можно перепутать. Лучше показать жест иначе."
        }
        if recordingTooStill {
            text += "\nДвижения почти не было: для такого жеста лучше подходит тип «Поза»."
        }
        let warning = similarWord != nil || recordingTooStill
        showNotice(text, duration: warning ? 5 : 3)
        UINotificationFeedbackGenerator().notificationOccurred(similarWord == nil ? .success : .warning)
    }

    private func failedNotice() {
        showNotice("Не получилось: руки не были видны целиком. Попробуйте ещё раз.")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func showNotice(_ text: String, duration: Double = 3) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if notice == text { notice = nil }
        }
    }

    // MARK: Перевод жестов в текст и речь

    private func translate(_ sign: Sign) {
        guard let word = sign.word else { return }
        phraseWords.append(word)
        lastWord = word
        speak(word)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func deleteLastWord() {
        guard !phraseWords.isEmpty else { return }
        phraseWords.removeLast()
        lastWord = phraseWords.last
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func finishPhrase() {
        guard !phraseWords.isEmpty else { return }
        phraseHistory.insert(phraseText + ".", at: 0)
        if phraseHistory.count > 3 { phraseHistory.removeLast() }
        phraseWords = []
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func clearTranslation() {
        phraseWords = []
        phraseHistory = []
        lastWord = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speakPhrase() {
        let text = phraseWords.isEmpty ? (phraseHistory.first ?? "") : phraseText
        guard !text.isEmpty else { return }
        say(text)
    }

    private func speak(_ text: String) {
        guard isSpeechEnabled else { return }
        say(text)
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    static func sentence(from words: [String]) -> String {
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Выполнение команд (режим «Управление»)

    private func execute(_ command: Command, from gesture: Gesture) {
        switch command {
        case .confirm:
            if let selected = selectedIndex {
                confirmation = "Подтверждён выбор: \(screens[selected].title)"
            } else {
                confirmation = "Подтверждено"
            }
        case .pause:
            isPlaying.toggle()
        case .select:
            selectedIndex = screenIndex
        case .nextScreen:
            screenIndex = (screenIndex + 1) % screens.count
        case .previousScreen:
            screenIndex = (screenIndex - 1 + screens.count) % screens.count
        case .increase:
            volume = min(100, volume + 10)
        case .decrease:
            volume = max(0, volume - 10)
        }

        lastGesture = gesture
        lastCommand = command

        let time = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(time)  \(gesture.emoji) \(command.title)", at: 0)
        if log.count > 3 { log.removeLast() }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
