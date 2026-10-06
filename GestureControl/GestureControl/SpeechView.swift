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
            .background(Soft.background.ignoresSafeArea())
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
        .tint(Soft.accent)
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    if translator.phrases.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: translator.isListening ? "waveform" : "mic")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(Soft.accent)
                            Text(translator.isListening
                                 ? "Говорите — текст появится здесь"
                                 : "Нажмите на микрофон, чтобы начать")
                                .font(.title3.weight(.medium))
                            Text("Можно положить телефон на стол между собеседниками. Если человек далеко, держите телефон низом (микрофоном) к нему.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Soft.card, in: RoundedRectangle(cornerRadius: Soft.cornerRadius, style: .continuous))
                        .padding(.top, 24)
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
                    }
                    .buttonStyle(SoftPillButtonStyle(prominent: true))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        VStack(spacing: 12) {
            if let error = translator.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Soft.alert)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            ListeningStatus(meter: translator.meter,
                            isListening: translator.isListening,
                            notice: translator.notice)
            HStack(spacing: 16) {
                Button {
                    translator.clear()
                    follow = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SoftIconButtonStyle(size: 50))
                .disabled(translator.phrases.isEmpty)
                .opacity(translator.phrases.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Очистить")

                // Дальняя речь: усиление тихого и далёкого голоса.
                Button {
                    translator.enhanceDistant.toggle()
                } label: {
                    Image(systemName: "ear")
                }
                .buttonStyle(SoftIconButtonStyle(size: 50, tint: translator.enhanceDistant ? Soft.accent : nil))
                .accessibilityLabel(translator.enhanceDistant ? "Дальняя речь включена" : "Дальняя речь выключена")

                Button {
                    if translator.isListening {
                        translator.stop()
                    } else {
                        Task { await translator.start() }
                    }
                } label: {
                    Image(systemName: translator.isListening ? "stop.fill" : "mic.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(SoftIconButtonStyle(size: 76, tint: translator.isListening ? Soft.alert : Soft.accent))
                .shadow(color: (translator.isListening ? Soft.alert : Soft.accent).opacity(0.35), radius: 14, y: 4)
                .accessibilityLabel(translator.isListening ? "Остановить" : "Слушать")

                Button {
                    translator.fontSize = translator.fontSize >= 48 ? 22 : translator.fontSize + 6
                } label: {
                    Image(systemName: "textformat.size")
                }
                .buttonStyle(SoftIconButtonStyle(size: 50))
                .accessibilityLabel("Размер текста")

                // Микрофон Bluetooth: наушники можно дать говорящему.
                Button {
                    translator.bluetoothMic.toggle()
                } label: {
                    Image(systemName: "headphones")
                }
                .buttonStyle(SoftIconButtonStyle(size: 50, tint: translator.bluetoothMic ? Soft.accent : nil))
                .accessibilityLabel(translator.bluetoothMic ? "Микрофон Bluetooth включён" : "Микрофон Bluetooth выключен")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(Soft.animation, value: translator.isListening)
        .animation(Soft.animation, value: translator.enhanceDistant)
        .animation(Soft.animation, value: translator.bluetoothMic)
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
            Toggle(isOn: $translator.enhanceDistant) {
                Label("Дальняя и тихая речь (усиление)", systemImage: "ear")
            }
            Toggle(isOn: $translator.bluetoothMic) {
                Label("Микрофон Bluetooth", systemImage: "headphones")
            }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(phrase.time.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(phrase.text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(highlighted ? Soft.warm : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(highlighted ? Soft.warm.opacity(0.10) : Soft.card,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(meter.hearsVoice ? Soft.ok : Soft.muted)
                            .frame(width: max(8, geometry.size.width * CGFloat(meter.level)))
                    }
                }
                .frame(width: 180, height: 8)
                .animation(.linear(duration: 0.1), value: meter.level)
                .accessibilityHidden(true)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(notice == nil ? Color.secondary : Soft.warm)
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
