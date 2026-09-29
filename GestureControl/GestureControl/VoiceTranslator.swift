import Foundation
import Speech
import AVFoundation
import Accelerate
import CallKit
import UIKit

/// Фраза распознанной речи. Новая фраза начинается после паузы в разговоре —
/// так реплики разных людей оказываются на разных строках.
struct SpokenPhrase: Identifiable, Equatable {
    let id: Int
    var text: String
    /// Фраза закончена (человек замолчал), текст больше не изменится.
    var isFinal: Bool
    let time: Date
}

/// Громкость микрофона для индикатора. Отдельный объект: индикатор обновляется 10 раз в секунду,
/// а список фраз при этом не перерисовывается.
@MainActor
final class SpeechMeter: ObservableObject {
    /// 0…1: насколько звук громче фонового шума.
    @Published private(set) var level: Double = 0
    /// Сейчас слышен голос.
    @Published private(set) var hearsVoice = false

    func update(level: Double, hearsVoice: Bool) {
        if abs(level - self.level) >= 0.04 || (level == 0 && self.level != 0) { self.level = level }
        if hearsVoice != self.hearsVoice { self.hearsVoice = hearsVoice }
    }
}

/// Звук с микрофона. Вызывается с аудиопотока, поэтому всё защищено блокировкой.
///
/// • Весь звук передаётся в текущий запрос распознавания — и в тишине тоже. Решать, есть ли речь,
///   должно само распознавание: в шуме (транспорт, улица) голос бывает почти не громче шума,
///   и отбор звука по громкости терял бы речь.
/// • Громкость и уровень фонового шума считаются только для индикатора на экране.
/// • Если запроса на мгновение нет (он закончился сам или после ошибки), звук копится
///   в запасе на 1 с и уходит в следующий запрос — ничего не теряется.
private final class AudioSink: @unchecked Sendable {
    struct Snapshot {
        /// Громкость, дБ (сглажена за ~0,1 с).
        var level: Float
        /// Уровень фонового шума, дБ.
        var noise: Float
        /// Секунд с последнего звука голоса.
        var silence: TimeInterval

        /// Для индикатора: 0…1, громкость от −65 до −15 дБ.
        var meterLevel: Double { Double(min(max((level + 65) / 50, 0), 1)) }
    }

    /// Для индикатора: голос — звук громче фонового шума на столько децибел не меньше 60 мс подряд.
    private static let voiceMargin: Float = 8
    private static let voiceDuration = 0.06
    private static let prerollSeconds = 1.0
    /// Фоновый шум — минимум громкости за 16 отрезков по 0,25 с (4 с): в речи всегда есть
    /// короткие паузы между словами, поэтому речь не принимается за шум.
    private static let noiseBlock: TimeInterval = 0.25
    private static let noiseBlocks = 16

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0

    private var level: Float = -100
    private var noise: Float = -90
    private var hasLevel = false
    private var blockMinimum = Float.greatestFiniteMagnitude
    private var blockStart: TimeInterval = 0
    private var minima: [Float] = []
    private var loudTime: TimeInterval = 0
    private var lastVoice: TimeInterval = 0

    /// Новый запрос распознавания (nil — запроса пока нет). Запас звука сразу уходит в него.
    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
        if let request {
            for buffer in preroll { request.append(buffer) }
        }
        preroll.removeAll()
        prerollFrames = 0
    }

    /// Сбросить всё (микрофон включается заново).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        request = nil
        preroll.removeAll()
        prerollFrames = 0
        level = -100
        noise = -90
        hasLevel = false
        blockMinimum = .greatestFiniteMagnitude
        blockStart = 0
        minima.removeAll()
        loudTime = 0
        lastVoice = 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let decibels = Self.decibels(of: buffer)
        // Длительность буфера: система присылает их по 20–100 мс, как ей удобно.
        let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        lock.lock()
        defer { lock.unlock() }
        analyze(decibels, seconds: seconds, now: now)
        if let request {
            request.append(buffer)
        } else if let copy = Self.copy(buffer) {
            preroll.append(copy)
            prerollFrames += copy.frameLength
            let limit = AVAudioFrameCount(buffer.format.sampleRate * Self.prerollSeconds)
            while prerollFrames > limit, let first = preroll.first {
                prerollFrames -= first.frameLength
                preroll.removeFirst()
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return Snapshot(level: level, noise: noise,
                        silence: lastVoice > 0 ? now - lastVoice : .infinity)
    }

    private func analyze(_ decibels: Float?, seconds: TimeInterval, now: TimeInterval) {
        guard let decibels else { return }   // громкость не узнать (необычный формат звука)
        if hasLevel {
            // Сглаживание ~0,1 с независимо от размера буфера.
            level += (decibels - level) * Float(1 - exp(-seconds / 0.1))
        } else {
            level = decibels
            hasLevel = true
            blockStart = now
        }

        blockMinimum = min(blockMinimum, level)
        if now - blockStart >= Self.noiseBlock {
            minima.append(blockMinimum)
            if minima.count > Self.noiseBlocks { minima.removeFirst() }
            noise = max(minima.min() ?? level, -90)
            blockMinimum = .greatestFiniteMagnitude
            blockStart = now
        }

        // Голос ищем, когда уровень шума уже известен (через 0,25 с после включения).
        if !minima.isEmpty && level > noise + Self.voiceMargin {
            loudTime += seconds
        } else {
            loudTime = 0
        }
        if loudTime >= Self.voiceDuration { lastVoice = now }
    }

    /// Громкость буфера, дБ относительно полной шкалы.
    private static func decibels(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        return 20 * log10(max(rms, 0.000_000_1))
    }

    /// Копия буфера: буферы микрофона система использует повторно, а запас хранится дольше.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

/// Голосовой перевод: живая расшифровка речи в текст (распознавание речи Apple, русский язык).
///
/// • Слушает непрерывно, пока открыта страница: весь звук идёт на распознавание.
/// • Каждая фраза — отдельный запрос распознавания. Фраза заканчивается, когда распознанный
///   текст не меняется `splitPause` секунд (человек замолчал): реплики разных людей
///   не сливаются в одну строку. Следующий запрос начинается сразу, без пропуска звука.
/// • После звонка, Siri, сворачивания приложения или смены микрофона прослушивание
///   продолжается само. Если iPhone сообщает, что сервер недоступен, распознавание идёт
///   на телефоне (если iPhone это умеет).
/// • Текст исправляется `SpeechCorrector`: запинки, повторы, звуки-паузы, слова из словаря.
@MainActor
final class VoiceTranslator: ObservableObject {
    @Published private(set) var phrases: [SpokenPhrase] = []
    /// Прослушивание включено (кнопка микрофона).
    @Published private(set) var isListening = false
    @Published private(set) var error: String?
    /// Пояснение под кнопками: пауза из-за звонка, распознавание без интернета.
    @Published private(set) var notice: String?

    /// Громкость микрофона для индикатора.
    let meter = SpeechMeter()

    /// Размер текста на экране.
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }
    /// Пауза, после которой начинается новая строка, секунд. Короче — когда говорящие
    /// быстро сменяют друг друга; длиннее — для медленной речи с паузами внутри фразы.
    @Published var splitPause: Double {
        didSet { UserDefaults.standard.set(splitPause, forKey: Self.splitPauseKey) }
    }
    /// Распознавать только на телефоне, без отправки звука на серверы Apple
    /// (точность может быть ниже; доступно не на всех iPhone).
    @Published var onDeviceOnly: Bool {
        didSet {
            UserDefaults.standard.set(onDeviceOnly, forKey: Self.onDeviceKey)
            if request != nil {
                endPhrase()
                beginPhrase()
            }
        }
    }
    /// Слова, которые должны распознаваться точно: имена, названия, термины.
    @Published var customWords: [String] {
        didSet {
            UserDefaults.standard.set(customWords, forKey: Self.wordsKey)
            updateVocabulary()
        }
    }

    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Для индикатора: голос был слышен за последние столько секунд.
    private let voiceHold: TimeInterval = 0.3
    /// Длинная речь без пауз делится на фразы: после этой длительности — на первой короткой паузе…
    private let softPhraseDuration: TimeInterval = 35
    private let shortPause: TimeInterval = 0.6
    /// …и не позже этой (у распознавания Apple есть ограничение на длину запроса).
    private let maxPhraseDuration: TimeInterval = 55
    /// Если окончательный текст фразы так и не пришёл, она закрывается через столько секунд.
    private let finalTimeout: TimeInterval = 6
    private let maxPhrases = 400

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let audioEngine = AVAudioEngine()
    private let sink = AudioSink()
    /// Только чтобы узнать, идёт ли звонок: ни звук, ни номер звонящего iOS приложениям не даёт.
    private let callObserver = CXCallObserver()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var generation = 0
    private var phraseStart = Date()
    private var lastChange = Date()
    private var currentHasText = false
    /// Последний необработанный текст каждой незаконченной фразы: одинаковые результаты не исправляются заново.
    private var lastRaw: [Int: String] = [:]
    /// Фразы, ожидающие окончательного текста, и когда они закончились.
    private var endedPhrases: [Int: Date] = [:]
    /// Микрофон включён (при звонке или в фоне выключается, хотя прослушивание остаётся включённым).
    private var running = false
    private var startToken = 0
    private var nextPhraseAllowed = Date.distantPast
    private var lastFailure = ""
    private var lastAudioRestart = Date.distantPast
    private var monitor: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var failures: [Date] = []
    private var dictionaryWords: [String] = []
    private var corrector = SpeechCorrector()

    private static let fontSizeKey = "speechFontSize"
    private static let splitPauseKey = "speechSplitPause"
    private static let onDeviceKey = "speechOnDeviceOnly"
    private static let wordsKey = "speechCustomWords"
    private static let offlineNotice = "Нет связи с сервером — распознаю на телефоне"
    private static let busyNotice = "Пауза: микрофон занят другим приложением. Продолжу автоматически."
    private static let callNotice = "Идёт звонок. iPhone не даёт приложениям слушать телефонные разговоры — перевод продолжится после звонка."

    init() {
        let defaults = UserDefaults.standard
        let size = defaults.double(forKey: Self.fontSizeKey)
        fontSize = size > 0 ? size : 30
        let pause = defaults.double(forKey: Self.splitPauseKey)
        splitPause = pause > 0 ? pause : 1.2
        onDeviceOnly = defaults.bool(forKey: Self.onDeviceKey)
        customWords = defaults.stringArray(forKey: Self.wordsKey) ?? []
        updateVocabulary()
    }

    /// Слова из словаря жестов тоже должны распознаваться точно.
    func setDictionaryWords(_ words: [String]) {
        dictionaryWords = words
        updateVocabulary()
    }

    private var vocabulary: [String] {
        var seen = Set<String>()
        return (customWords + dictionaryWords).filter { seen.insert($0.lowercased()).inserted }
    }

    private func updateVocabulary() {
        corrector.vocabulary = vocabulary
    }

    // MARK: Запуск и остановка

    func start() async {
        guard !isListening else { return }
        startToken += 1
        let token = startToken
        error = nil
        guard let recognizer else {
            error = "Распознавание русской речи на этом iPhone недоступно."
            return
        }
        guard await Self.requestSpeechPermission() == .authorized else {
            error = "Нет доступа к распознаванию речи. Разрешите его: Настройки → speech → Распознавание речи."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Нет доступа к микрофону. Разрешите его: Настройки → speech → Микрофон."
            return
        }
        // Пока спрашивали разрешения, страницу могли закрыть.
        guard token == startToken, !isListening else { return }
        guard recognizer.isAvailable || recognizer.supportsOnDeviceRecognition else {
            error = "Распознавание речи сейчас недоступно. Проверьте интернет."
            return
        }

        isListening = true
        failures = []
        finalizeEnded()
        observeSystemEvents()
        resumeAudio(automatic: false)
    }

    func stop() {
        startToken += 1
        retry?.cancel()
        retry = nil
        guard isListening else { return }
        isListening = false
        setNotice(nil)
        removeObservers()
        suspendAudio()
        // Возвращаем звук для озвучки перевода жестов (как на главном экране).
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func clear() {
        phrases.removeAll()
        lastRaw.removeAll()
    }

    // MARK: Микрофон

    /// Включить микрофон: при старте и после перерыва (звонок, сворачивание, смена микрофона).
    private func resumeAudio(automatic: Bool) {
        guard isListening, !running else { return }
        guard UIApplication.shared.applicationState != .background else { return }
        lastAudioRestart = Date()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "GestureControl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен."])
            }
            input.removeTap(onBus: 0)
            sink.reset()
            let sink = self.sink
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                sink.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            if automatic {
                // Микрофон ещё занят (например, идёт звонок) — пробуем снова чуть позже.
                setNotice(pauseNotice)
                scheduleResume(after: 2)
            } else {
                stop()
                self.error = "Не удалось включить микрофон: \(error.localizedDescription)"
            }
            return
        }
        running = true
        setNotice(nil)
        beginPhrase()
        startMonitor()
    }

    /// Выключить микрофон; текущая фраза дописывается.
    private func suspendAudio() {
        monitor?.cancel()
        monitor = nil
        endPhrase()
        if running {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            running = false
        }
        sink.reset()
        meter.update(level: 0, hearsVoice: false)
    }

    private func restartAudio() {
        guard isListening, running else { return }
        suspendAudio()
        resumeAudio(automatic: true)
    }

    private func scheduleResume(after seconds: Double) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.resumeAudio(automatic: true)
        }
    }

    // MARK: События системы

    private func observeSystemEvents() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Звонок, будильник, Siri: микрофон отбирают — ставим на паузу и продолжаем после.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = type == AVAudioSession.InterruptionType.began.rawValue
            let translator = self
            Task { @MainActor in translator?.interruption(began: began) }
        })
        // Подключили или отключили наушники, сменился микрофон: система останавливает звук.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: audioEngine, queue: nil) { [weak self] _ in
            let translator = self
            Task { @MainActor in translator?.audioConfigurationChanged() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            let translator = self
            Task { @MainActor in translator?.enteredBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            let translator = self
            Task { @MainActor in translator?.becameActive() }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func interruption(began: Bool) {
        guard isListening else { return }
        if began {
            suspendAudio()
            setNotice(pauseNotice)
            // Сообщение о конце перерыва приходит не всегда — время от времени пробуем сами.
            scheduleResume(after: 3)
        } else {
            scheduleResume(after: 0.4)
        }
    }

    /// Почему пауза: телефонный звонок или микрофон занят другим приложением.
    private var pauseNotice: String {
        callObserver.calls.contains(where: { !$0.hasEnded }) ? Self.callNotice : Self.busyNotice
    }

    private func audioConfigurationChanged() {
        guard isListening, running, !audioEngine.isRunning else { return }
        restartAudio()
    }

    private func enteredBackground() {
        guard isListening else { return }
        retry?.cancel()
        suspendAudio()
    }

    private func becameActive() {
        guard isListening, !running else { return }
        resumeAudio(automatic: true)
    }

    // MARK: Фразы

    /// Новый запрос распознавания — новая фраза. Звук, пришедший, пока запроса не было, берётся из запаса.
    private func beginPhrase() {
        guard let recognizer, running, request == nil else { return }
        generation += 1
        let id = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = Array(vocabulary.prefix(100))
        let onDevice = useOnDevice(recognizer)
        if onDevice { request.requiresOnDeviceRecognition = true }
        setNotice(onDevice && !onDeviceOnly ? Self.offlineNotice : nil)

        self.request = request
        phraseStart = Date()
        lastChange = phraseStart
        currentHasText = false

        recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Из результата берём только строки и числа — их можно передать на главный поток.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error.map { $0 as NSError }
            let domain = nsError?.domain
            let code = nsError?.code ?? 0
            let translator = self
            Task { @MainActor in
                translator?.handle(id: id, text: text, isFinal: isFinal, errorDomain: domain, errorCode: code)
            }
        }
        sink.set(request)
    }

    /// Фраза закончена: запрос дописывает окончательный текст. Следующий запрос начинает вызывающий.
    private func endPhrase() {
        guard let request else { return }
        request.endAudio()
        self.request = nil
        sink.set(nil)
        endedPhrases[generation] = Date()
    }

    /// На телефоне — если так выбрано или iPhone сообщает, что сервер распознавания недоступен.
    private func useOnDevice(_ recognizer: SFSpeechRecognizer) -> Bool {
        guard recognizer.supportsOnDeviceRecognition else { return false }
        return onDeviceOnly || !recognizer.isAvailable
    }

    private func handle(id: Int, text: String?, isFinal: Bool, errorDomain: String?, errorCode: Int) {
        let existing = phrases.lastIndex { $0.id == id }
        // Запоздавший промежуточный результат уже закрытой фразы.
        if let existing, phrases[existing].isFinal, !isFinal { return }

        if let text, !text.isEmpty, lastRaw[id] != text {
            lastRaw[id] = text
            let corrected = corrector.correct(text)
            if let existing {
                if corrected.isEmpty {
                    phrases.remove(at: existing)
                } else if phrases[existing].text != corrected {
                    phrases[existing].text = corrected
                }
            } else if !corrected.isEmpty {
                // Фразы по порядку, даже если текст предыдущей пришёл позже начала следующей.
                let position = phrases.lastIndex { $0.id < id }.map { $0 + 1 } ?? 0
                phrases.insert(SpokenPhrase(id: id, text: corrected, isFinal: false, time: Date()), at: position)
                if phrases.count > maxPhrases { phrases.removeFirst(phrases.count - maxPhrases) }
            }
            if id == generation && request != nil {
                lastChange = Date()
                currentHasText = true
            }
        }

        let failed = errorDomain != nil
        guard isFinal || failed else { return }
        finalize(id)

        // Текущий запрос закончился сам (тишина, ошибка сети, ограничение длительности) —
        // сразу слушаем дальше с новым; звук за это время сохранён в запасе.
        guard id == generation, request != nil else { return }
        request = nil
        sink.set(nil)
        if let errorDomain, !Self.isHarmless(domain: errorDomain, code: errorCode) {
            lastFailure = "\(errorDomain) \(errorCode)"
            registerFailure()
        }
        if canBeginPhrase(at: Date()) { beginPhrase() }
    }

    private func finalize(_ id: Int) {
        lastRaw[id] = nil
        endedPhrases[id] = nil
        guard let i = phrases.lastIndex(where: { $0.id == id }) else { return }
        if !phrases[i].isFinal { phrases[i].isFinal = true }
    }

    private func finalizeEnded() {
        for id in endedPhrases.keys { finalize(id) }
    }

    /// «Речь не обнаружена» и отмена запроса — не ошибки.
    private static func isHarmless(domain: String, code: Int) -> Bool {
        switch (domain, code) {
        case ("kAFAssistantErrorDomain", 1110), ("kAFAssistantErrorDomain", 216), ("kLSRErrorDomain", 301):
            return true
        default:
            return false
        }
    }

    private func registerFailure() {
        let now = Date()
        nextPhraseAllowed = now.addingTimeInterval(0.5)
        failures = failures.filter { now.timeIntervalSince($0) < 10 } + [now]
        if failures.count >= 5 {
            let code = lastFailure
            stop()
            error = "Распознавание речи прерывается. Проверьте интернет"
                + (supportsOnDevice && !onDeviceOnly ? " или включите «Только на телефоне»." : ".")
                + " (код: \(code))"
        }
    }

    // MARK: Слежение за паузами

    /// 10 раз в секунду: индикатор громкости и конец фраз.
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        // Звук остановился, а уведомление о смене микрофона не пришло.
        if !audioEngine.isRunning {
            if now.timeIntervalSince(lastAudioRestart) > 2 { restartAudio() }
            return
        }

        let audio = sink.snapshot()
        let hearsVoice = audio.silence < voiceHold
        meter.update(level: audio.meterLevel, hearsVoice: hearsVoice)

        for (id, ended) in endedPhrases where now.timeIntervalSince(ended) > finalTimeout {
            finalize(id)
        }

        guard request != nil else {
            // Запрос закончился сам — начинаем новый, не дожидаясь речи.
            if canBeginPhrase(at: now) { beginPhrase() }
            return
        }
        // Конец фразы — по паузе в распознанном тексте: так работает и в тишине, и в шуме,
        // где по громкости паузу не определить.
        let duration = now.timeIntervalSince(phraseStart)
        let textPause = now.timeIntervalSince(lastChange)
        if (currentHasText && textPause >= splitPause)
            || (currentHasText && duration >= softPhraseDuration && textPause >= shortPause)
            || duration >= maxPhraseDuration {
            endPhrase()
            beginPhrase()
        }
    }

    /// Не чаще одного нового запроса в секунду (если распознавание сразу завершает запросы)
    /// и с паузой после ошибки. Звук за это время копится в запасе.
    private func canBeginPhrase(at now: Date) -> Bool {
        now >= nextPhraseAllowed && now.timeIntervalSince(phraseStart) >= 1
    }

    private func setNotice(_ text: String?) {
        if notice != text { notice = text }
    }

    private static func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
