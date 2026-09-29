import SwiftUI

/// Страница «Речь → текст»: живая расшифровка того, что говорят вокруг, крупным текстом.
/// Каждая реплика (после паузы) — отдельная строка, поэтому речь нескольких людей не сливается.
struct SpeechView: View {
    /// Слова из словаря жестов: они тоже должны распознаваться точно.
    let dictionaryWords: [String]

    @StateObject private var translator = VoiceTranslator()
    @Environment(\.dismiss) private var dismiss
    @State private var showWords = false

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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phrase.time.formatted(date: .omitted, time: .shortened))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(phrase.text)
                                .font(.system(size: translator.fontSize, weight: .semibold))
                                .foregroundStyle(phrase.isFinal ? Color.primary : Color.yellow)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .id(phrase.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: translator.phrases) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
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
            }
            HStack(spacing: 28) {
                Button {
                    translator.clear()
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
            Text(translator.isListening ? "Слушаю… Новая строка — после паузы в разговоре" : "Пауза")
                .font(.caption)
                .foregroundStyle(.secondary)
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
