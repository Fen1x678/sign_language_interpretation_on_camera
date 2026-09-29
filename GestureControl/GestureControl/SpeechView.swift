import SwiftUI

/// Страница «Речь → текст»: живая расшифровка того, что говорят вокруг, крупным текстом.
/// Каждая реплика (после паузы) — отдельная строка, поэтому речь нескольких людей не сливается.
struct SpeechView: View {
    /// Слова из словаря жестов: они тоже должны распознаваться точно.
    let dictionaryWords: [String]

    @StateObject private var translator = VoiceTranslator()
    @Environment(\.dismiss) private var dismiss
    @State private var showWords = false
    /// Прокручивать к новым фразам. Выключается, когда человек листает вверх, чтобы перечитать.
    @State private var follow = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                controls
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Речь → текст")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") {
                        translator.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    settingsMenu
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            translator.setDictionaryWords(dictionaryWords)
            await translator.start()
        }
        .onDisappear { translator.stop() }
        .sheet(isPresented: $showWords) {
            SpeechWordsView(translator: translator)
        }
    }

    // MARK: Текст

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if translator.phrases.isEmpty {
                        Text(translator.isListening
                             ? "Говорите — текст появится здесь"
                             : "Нажмите на микрофон, чтобы начать")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(translator.phrases) { phrase in
                        // Строка перерисовывается, только когда меняется её текст.
                        PhraseRow(phrase: phrase,
                                  fontSize: translator.fontSize,
                                  highlighted: !phrase.isFinal && translator.isListening)
                            .equatable()
                            .id(phrase.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .modifier(FollowNewText(follow: $follow))
            // Новая фраза — плавная прокрутка; новое слово в фразе — без анимации (не дёргается).
            .onChange(of: translator.phrases.count) { _, _ in
                scrollToEnd(proxy, animated: true)
            }
            .onChange(of: translator.phrases.last?.text) { _, _ in
                scrollToEnd(proxy, animated: false)
            }
            .overlay(alignment: .bottom) {
                if !follow && !translator.phrases.isEmpty {
                    Button {
                        follow = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } label: {
                        Label("К новым", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard follow else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: Управление

    private var controls: some View {
        VStack(spacing: 10) {
            if let error = translator.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            ListeningStatus(meter: translator.meter,
                            isListening: translator.isListening,
                            notice: translator.notice)
            HStack(spacing: 28) {
                Button {
                    translator.clear()
                    follow = true
                } label: {
                    Image(systemName: "trash")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(translator.phrases.isEmpty)
                .accessibilityLabel("Очистить")

                Button {
                    if translator.isListening {
                        translator.stop()
                    } else {
                        Task { await translator.start() }
                    }
                } label: {
                    Image(systemName: translator.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 78, height: 78)
                        .background(translator.isListening ? Color.red : Color.accentColor, in: Circle())
                }
                .accessibilityLabel(translator.isListening ? "Остановить" : "Слушать")

                Button {
                    translator.fontSize = translator.fontSize >= 48 ? 22 : translator.fontSize + 6
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Размер текста")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var settingsMenu: some View {
        Menu {
            Button {
                showWords = true
            } label: {
                Label("Мои слова", systemImage: "text.book.closed")
            }
            Picker(selection: $translator.splitPause) {
                Text("Быстрый разговор — 0,8 с").tag(0.8)
                Text("Обычно — 1,2 с").tag(1.2)
                Text("Медленная речь — 2 с").tag(2.0)
            } label: {
                Label("Новая строка после паузы", systemImage: "timer")
            }
            .pickerStyle(.menu)
            if translator.supportsOnDevice {
                Toggle(isOn: $translator.onDeviceOnly) {
                    Label("Только на телефоне (без интернета)", systemImage: "iphone")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

/// Одна фраза: время и текст. Жёлтая — фраза ещё звучит и может измениться.
private struct PhraseRow: View, Equatable {
    let phrase: SpokenPhrase
    let fontSize: Double
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phrase.time.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(phrase.text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(highlighted ? Color.yellow : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// Индикатор громкости (зелёный — звук похож на голос) и что сейчас происходит.
/// Обновляется отдельно от текста.
private struct ListeningStatus: View {
    @ObservedObject var meter: SpeechMeter
    let isListening: Bool
    let notice: String?

    var body: some View {
        VStack(spacing: 6) {
            if isListening {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule()
                            .fill(meter.hearsVoice ? Color.green : Color.gray)
                            .frame(width: max(6, geometry.size.width * CGFloat(meter.level)))
                    }
                }
                .frame(width: 160, height: 6)
                .animation(.linear(duration: 0.1), value: meter.level)
                .accessibilityHidden(true)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(notice == nil ? Color.secondary : Color.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    private var status: String {
        guard isListening else { return "Пауза — нажмите на микрофон" }
        if let notice { return notice }
        return "Слушаю. Новая строка — после паузы в разговоре"
    }
}

/// Автопрокрутка к новым фразам выключается, когда человек листает текст, и включается снова,
/// когда он долистал до конца. На iOS 17 текст всегда прокручивается к новым фразам.
private struct FollowNewText: ViewModifier {
    @Binding var follow: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { oldPhase, newPhase, context in
                if newPhase == .interacting {
                    follow = false
                } else if newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating {
                    let geometry = context.geometry
                    follow = geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                }
            }
        } else {
            content
        }
    }
}

/// Слова, которые должны распознаваться точно: имена, названия, термины.
/// Если слово распознано с ошибкой в одну-две буквы, оно исправляется на слово из этого списка.
struct SpeechWordsView: View {
    @ObservedObject var translator: VoiceTranslator
    @Environment(\.dismiss) private var dismiss
    @State private var newWord = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Имя, название, термин", text: $newWord)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("Добавить", action: add)
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Эти слова распознаются точнее. Если слово распознано с ошибкой в одну-две буквы (например, из-за особенностей произношения), оно исправится на слово из списка. Слова из словаря жестов учитываются автоматически.")
                }
                Section("Мои слова: \(translator.customWords.count)") {
                    ForEach(translator.customWords, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { offsets in
                        translator.customWords.remove(atOffsets: offsets)
                    }
                }
            }
            .navigationTitle("Мои слова")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Готово") { dismiss() }
            }
        }
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty,
              !translator.customWords.contains(where: { $0.lowercased() == word.lowercased() }) else { return }
        translator.customWords.append(word)
        newWord = ""
    }
}
