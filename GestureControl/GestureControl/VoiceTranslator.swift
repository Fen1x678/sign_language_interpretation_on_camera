import Foundation
import Speech
import AVFoundation

/// Фраза распознанной речи. Новая фраза начинается после паузы в разговоре —
/// так реплики разных людей оказываются на разных строках.
struct SpokenPhrase: Identifiable, Equatable {
    let id: Int
    var text: String
    /// Фраза закончена (человек замолчал), текст больше не изменится.
    var isFinal: Bool
    let time: Date
}

/// Звук с микрофона передаётся в текущий запрос распознавания. Вызывается с аудиопотока,
/// поэтому запрос защищён блокировкой: при смене фразы он подменяется без пропуска звука.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }
}

/// Голосовой перевод: живая расшифровка речи в текст (распознавание речи Apple, русский язык).
///
/// • Слушает непрерывно, пока открыта страница.
/// • После паузы (`pauseToSplit` секунд) начинается новая фраза: когда говорят несколько человек,
///   их реплики не сливаются в одну строку.
/// • Текст исправляется `SpeechCorrector`: запинки, повторы, звуки-паузы, слова из словаря.
@MainActor
final class VoiceTranslator: ObservableObject {
    @Published private(set) var phrases: [SpokenPhrase] = []
    @Published private(set) var isListening = false
    @Published private(set) var error: String?

    /// Размер текста на экране.
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }
    /// Распознавать только на телефоне, без отправки звука на серверы Apple
    /// (точность может быть ниже; доступно не на всех iPhone).
    @Published var onDeviceOnly: Bool {
        didSet {
            UserDefaults.standard.set(onDeviceOnly, forKey: Self.onDeviceKey)
            if isListening { finishPhrase() }
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

    /// Пауза, после которой начинается новая фраза, секунд.
    private let pauseToSplit: TimeInterval = 1.3
    /// Одна фраза не длиннее этого (у распознавания Apple есть ограничение на длину запроса).
    private let maxPhraseDuration: TimeInterval = 50

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let audioEngine = AVAudioEngine()
    private let sink = AudioSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var generation = 0
    private var phraseStart = Date()
    private var lastChange = Date()
    private var monitor: Task<Void, Never>?
    private var failures: [Date] = []
    private var dictionaryWords: [String] = []
    private var corrector = SpeechCorrector()

    private static let fontSizeKey = "speechFontSize"
    private static let onDeviceKey = "speechOnDeviceOnly"
    private static let wordsKey = "speechCustomWords"

    init() {
        let defaults = UserDefaults.standard
        let size = defaults.double(forKey: Self.fontSizeKey)
        fontSize = size > 0 ? size : 30
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
        error = nil
        guard let recognizer else {
            error = "Распознавание русской речи на этом iPhone недоступно."
            return
        }
        guard await Self.requestSpeechPermission() == .authorized else {
            error = "Нет доступа к распознаванию речи. Разрешите его: Настройки → GestureControl → Распознавание речи."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Нет доступа к микрофону. Разрешите его: Настройки → GestureControl → Микрофон."
            return
        }
        guard recognizer.isAvailable || (onDeviceOnly && recognizer.supportsOnDeviceRecognition) else {
            error = "Распознавание речи сейчас недоступно. Проверьте интернет"
                + (recognizer.supportsOnDeviceRecognition ? " или включите «Только на телефоне»." : ".")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                error = "Микрофон недоступен."
                return
            }
            input.removeTap(onBus: 0)
            let sink = self.sink
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                sink.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            self.error = "Не удалось включить микрофон: \(error.localizedDescription)"
            return
        }

        isListening = true
        failures = []
        startPhrase()
        startMonitor()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        monitor?.cancel()
        monitor = nil
        request?.endAudio()   // последняя фраза ещё допишется
        request = nil
        sink.set(nil)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // Возвращаем звук для озвучки перевода жестов (как на главном экране).
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func clear() {
        phrases.removeAll()
    }

    // MARK: Фразы

    /// Новый запрос распознавания — новая фраза. Звук переключается на него без паузы.
    private func startPhrase() {
        guard let recognizer, isListening else { return }
        generation += 1
        let id = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = Array(vocabulary.prefix(100))
        if onDeviceOnly && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        sink.set(request)
        phraseStart = Date()
        lastChange = Date()

        recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Результат приходит не на главном потоке: берём из него только строки и флаги.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            let translator = self
            Task { @MainActor in
                translator?.handle(id: id, text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    /// Закончить текущую фразу (человек замолчал) и сразу начать следующую.
    private func finishPhrase() {
        request?.endAudio()
        startPhrase()
    }

    private func handle(id: Int, text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            let corrected = corrector.correct(text)
            if let i = phrases.firstIndex(where: { $0.id == id }) {
                if phrases[i].text != corrected { phrases[i].text = corrected }
            } else {
                phrases.append(SpokenPhrase(id: id, text: corrected, isFinal: false, time: Date()))
                if phrases.count > 300 { phrases.removeFirst(phrases.count - 300) }
            }
            if id == generation { lastChange = Date() }
        }

        guard isFinal || failed else { return }
        if let i = phrases.firstIndex(where: { $0.id == id }) { phrases[i].isFinal = true }
        // Текущий запрос закончился сам (тишина, ошибка сети) — продолжаем слушать с новым.
        guard id == generation, isListening else { return }
        if failed {
            let now = Date()
            failures = failures.filter { now.timeIntervalSince($0) < 5 } + [now]
            if failures.count >= 5 {
                stop()
                error = "Распознавание речи прерывается. Проверьте интернет"
                    + (supportsOnDevice ? " или включите «Только на телефоне»." : ".")
                return
            }
        }
        startPhrase()
    }

    /// Раз в 0,3 с: если после последнего слова пауза — фраза закончена, начинается новая строка.
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                self.checkPause()
            }
        }
    }

    private func checkPause() {
        guard isListening else { return }
        let now = Date()
        let hasText = phrases.last?.id == generation
        if (hasText && now.timeIntervalSince(lastChange) > pauseToSplit)
            || now.timeIntervalSince(phraseStart) > maxPhraseDuration {
            finishPhrase()
        }
    }

    private static func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
