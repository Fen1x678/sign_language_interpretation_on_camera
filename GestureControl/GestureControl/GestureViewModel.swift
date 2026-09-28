import SwiftUI
import Combine
import AVFoundation
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
    /// Точки найденных рук (одна или две) в координатах экрана — для отрисовки скелета.
    @Published private(set) var handPoints: [[CGPoint]] = []
    @Published private(set) var handCount = 0
    var isHandDetected: Bool { handCount > 0 }
    @Published private(set) var currentSign: Sign = .none
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var cameraError: String?
    @Published private(set) var notice: String?
    @Published var isRecognitionEnabled = true {
        didSet { if !isRecognitionEnabled { resetRecognition() } }
    }

    // MARK: Словарь жестов и обучение
    let library = SignLibrary()
    @Published private(set) var recording: RecordingState = .idle
    @Published private(set) var recordingWord = ""
    @Published private(set) var recordingDynamic = false
    private var recordedSamples: [[Float]] = []
    private var recordedFrames: [[Float]] = []
    private var recordingStart: Double = 0
    private var recordingDuration: Double { recordingDynamic ? 2.5 : 2.0 }

    // MARK: Жесты с движением
    private var motionBuffer: [(time: Double, frame: [Float])] = []
    private var previousMainCenter: CGPoint?
    private var lastHandSeenTime: Double = 0
    private var frameCounter = 0
    private var motionCooldownUntil: Double = 0
    private let motionWindow: Double = 2.0

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

        for await points in camera.frames {
            process(points)
        }
    }

    /// Фронтальная ↔ задняя камера.
    func switchCamera() {
        do {
            try camera.switchCamera()
            cameraPosition = camera.position
            handPoints = []
            resetRecognition()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            cameraError = error.localizedDescription
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
        motionBuffer.removeAll()
        currentSign = .none
        holdProgress = 0
    }

    // MARK: Обработка кадра

    private func process(_ raw: [[CGPoint]]) {
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0 {
                fps = fps == 0 ? 1 / dt : fps * 0.9 + (1 / dt) * 0.1
            }
        }
        lastFrameTime = now

        // Координаты камеры → координаты экрана (учитывает поворот и зеркалирование фронтальной камеры).
        var screenHands: [[CGPoint]] = []
        var handsForRecognition: [[CGPoint]] = []
        if !raw.isEmpty, let layer = previewLayer {
            screenHands = raw.map { hand in
                hand.map { point in
                    point.x < 0 ? CGPoint(x: -1, y: -1) : layer.layerPointConverted(fromCaptureDevicePoint: point)
                }
            }
            // Задняя камера видит собеседника «не в зеркале». Отражаем по горизонтали, чтобы
            // жест выглядел одинаково с обеих камер, а «влево/вправо» считались со стороны жестикулирующего.
            if cameraPosition == .back {
                let width = layer.bounds.width
                handsForRecognition = screenHands.map { hand in
                    hand.map { p in p.x < 0 ? p : CGPoint(x: width - p.x, y: p.y) }
                }
            } else {
                handsForRecognition = screenHands
            }
        }
        if handCount != screenHands.count { handCount = screenHands.count }
        handPoints = screenHands

        let geometries = handsForRecognition.compactMap { HandGeometry(points: $0) }
        if !geometries.isEmpty { lastHandSeenTime = now }
        let motionFrame = makeMotionFrame(geometries)

        // Запись нового жеста.
        switch recording {
        case .countdown:
            return
        case .recording:
            if recordingDynamic {
                if let motionFrame { recordedFrames.append(motionFrame) }
            } else if let vector = HandFeatures.signVector(from: geometries) {
                recordedSamples.append(vector)
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

        guard isRecognitionEnabled else { return }

        if mode == .translate {
            // Руки опущены — фраза закончена.
            if geometries.isEmpty, !phraseWords.isEmpty, now - lastHandSeenTime > phrasePause {
                finishPhrase()
            }
            // Жесты с движением: сравниваем последние ~2 секунды с записанными жестами.
            if recognizeMotion(frame: motionFrame, now: now) { return }
        }

        let result = recognizer.process(hands: handsForRecognition, time: now) { hands in
            self.classifyStatic(hands)
        }
        apply(result)
    }

    /// Кадр для жестов с движением: поза рук + смещение ведущей руки.
    private func makeMotionFrame(_ hands: [HandGeometry]) -> [Float]? {
        guard let main = hands.max(by: { $0.size < $1.size }) else {
            previousMainCenter = nil
            return nil
        }
        defer { previousMainCenter = main.center }
        guard let shape = HandFeatures.signVector(from: hands) else { return nil }
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if let previous = previousMainCenter {
            dx = (main.center.x - previous.x) / main.size
            dy = (main.center.y - previous.y) / main.size
        }
        return MotionFeatures.frame(shape: shape, dx: dx, dy: dy)
    }

    /// Возвращает true, если распознан жест с движением.
    private func recognizeMotion(frame: [Float]?, now: Double) -> Bool {
        guard library.hasDynamicSigns else { return false }

        if now - lastHandSeenTime > 0.5 { motionBuffer.removeAll() }
        if let frame, now >= motionCooldownUntil {
            motionBuffer.append((time: now, frame: frame))
        }
        let window = motionWindow
        motionBuffer.removeAll { now - $0.time > window }

        frameCounter += 1
        guard frameCounter % 3 == 0, motionBuffer.count >= 10 else { return false }

        // Берём каждый второй кадр — так же, как при подготовке записанного жеста.
        let stream = stride(from: motionBuffer.count % 2, to: motionBuffer.count, by: 2).map { motionBuffer[$0].frame }
        guard let sign = library.classifyMotion(stream) else { return false }

        motionBuffer.removeAll()
        motionCooldownUntil = now + 0.5
        recognizer.reset()
        let recognized = Sign.custom(id: sign.id, word: sign.word)
        currentSign = recognized
        holdProgress = 1
        translate(recognized)
        return true
    }

    /// Статичный жест.
    /// «Перевод»: только жесты из словаря пользователя (сначала двумя руками, потом одной).
    /// «Управление»: встроенные жесты.
    private func classifyStatic(_ hands: [HandGeometry]) -> Sign {
        guard let main = hands.max(by: { $0.size < $1.size }) else { return .none }

        switch mode {
        case .translate:
            if hands.count >= 2,
               let vector = HandFeatures.signVector(from: hands),
               let sign = library.classifyPose(vector) {
                return .custom(id: sign.id, word: sign.word)
            }
            if let vector = HandFeatures.handVector(from: main),
               let sign = library.classifyPose(vector) {
                return .custom(id: sign.id, word: sign.word)
            }
            return .none
        case .control:
            let gesture = main.staticGesture()
            return gesture == .idle ? .none : .builtIn(gesture)
        }
    }

    private func apply(_ result: RecognitionResult) {
        if currentSign != result.sign { currentSign = result.sign }
        holdProgress = result.holdProgress

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

    // MARK: Обучение новому жесту

    func startRecording(word: String, dynamic: Bool) {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, recording == .idle else { return }
        recordingWord = cleaned
        recordingDynamic = dynamic
        recordedSamples = []
        recordedFrames = []
        if mode != .translate { mode = .translate }

        Task {
            for n in stride(from: 3, through: 1, by: -1) {
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

        if recordingDynamic {
            // Оставляем кадры с тем числом рук, которое было видно чаще всего.
            let groups = Dictionary(grouping: recordedFrames, by: { $0.count })
            let length = groups.max { $0.value.count < $1.value.count }?.key
            let frames = recordedFrames.filter { $0.count == length }
            let template = MotionFeatures.prepareTemplate(frames)
            if frames.count >= 15 && template.count >= 5 {
                library.addSequence(word: recordingWord, sequence: template)
                savedNotice(handCount: (length ?? 0) > MotionFeatures.oneHandFrameLength ? 2 : 1)
            } else {
                failedNotice()
            }
        } else {
            let groups = Dictionary(grouping: recordedSamples, by: { $0.count })
            let samples = groups.max { $0.value.count < $1.value.count }?.value ?? []
            if samples.count >= 8 {
                library.add(word: recordingWord, samples: samples)
                savedNotice(handCount: samples[0].count > HandFeatures.oneHandLength ? 2 : 1)
            } else {
                failedNotice()
            }
        }
        recordedSamples = []
        recordedFrames = []
    }

    private func savedNotice(handCount: Int) {
        let hands = handCount == 2 ? "двумя руками" : "одной рукой"
        showNotice("Жест «\(recordingWord)» \(hands) сохранён")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func failedNotice() {
        showNotice("Не получилось: руки не были видны целиком. Попробуйте ещё раз.")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
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
