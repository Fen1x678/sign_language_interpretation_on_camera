import SwiftUI
import AVFoundation
import Combine

/// Пользовательский интерфейс: изображение с камеры, скелет руки,
/// распознанный жест, состояние системы, перевод или демо-интерфейс управления.
struct ContentView: View {
    @StateObject private var vm = GestureViewModel()
    @State private var showHelp = false
    @State private var showLibrary = false
    @State private var showSpeech = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: vm.session) { layer in
                vm.previewLayer = layer
            }
            .ignoresSafeArea()

            HandOverlay(live: vm.live, isActive: vm.currentSign != .none)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Подсветка экраном для фронтальной камеры: белая рамка на максимальной яркости.
            if vm.isScreenLightOn {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 44)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 10) {
                topBar
                modeBar
                if let notice = vm.notice {
                    Text(notice)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .softCard(cornerRadius: 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                gestureBadge
                if vm.mode == .translate {
                    translationPanel
                } else {
                    demoPanel
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if vm.recording != .idle {
                recordingOverlay
            }

            if let error = vm.cameraError {
                errorOverlay(error)
            }
        }
        .animation(Soft.animation, value: vm.notice)
        .tint(Soft.accent)
        .preferredColorScheme(.dark)
        // Лёгкий отклик вибрацией, когда слово переведено: можно не смотреть на экран.
        .sensoryFeedback(.success, trigger: vm.phraseWords.count) { old, new in new > old }
        .task { await vm.start() }
        .onAppear { openSpeechIfOnCall() }
        .onChange(of: scenePhase) { _, phase in
            vm.scenePhaseChanged(phase)
            if phase == .active { openSpeechIfOnCall() }
        }
        .sheet(isPresented: $showHelp) { GestureHelpView() }
        .fullScreenCover(isPresented: $showSpeech) {
            SpeechView(dictionaryWords: vm.library.signs.map(\.word))
        }
        .onChange(of: showSpeech) { _, shown in
            vm.setCameraPaused(shown)
        }
        .sheet(isPresented: $showLibrary) {
            SignLibraryView(library: vm.library) { word, dynamic, multiAngle in
                vm.startRecording(word: word, dynamic: dynamic, multiAngle: multiAngle)
            }
        }
    }

    /// Во время звонка приложение открыли, чтобы видеть разговор текстом.
    private func openSpeechIfOnCall() {
        guard !showSpeech, !showLibrary, !showHelp, vm.shouldOpenSpeechForCall() else { return }
        showSpeech = true
    }

    // MARK: Запись нового жеста

    private var recordingOverlay: some View {
        VStack(spacing: 14) {
            switch vm.recording {
            case .countdown(let n):
                if vm.recordingSteps > 1 {
                    Text("Ракурс \(vm.recordingStep) из \(vm.recordingSteps)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(vm.recordingPrompt)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("\(n)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
            case .recording(let progress):
                Text(vm.recordingDynamic ? "Покажите жест целиком, с движением" : "Держите жест")
                    .font(.headline)
                ProgressView(value: progress)
                    .tint(Soft.alert)
                    .frame(width: 200)
                Text(vm.recordingDynamic
                     ? "Показывайте так же, как обычно, с обычной скоростью"
                     : "Слегка поворачивайте кисть — так жест будет узнаваться надёжнее")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .idle:
                EmptyView()
            }
            Text("«\(vm.recordingWord)»")
                .font(.title2.bold())
        }
        .padding(26)
        .frame(maxWidth: 310)
        .softCard(cornerRadius: 30)
        .animation(Soft.animation, value: vm.recording)
    }

    // MARK: Верхняя панель: состояние системы и кнопки

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Label(vm.handCount >= 2 ? "Две руки"
                        : (vm.isHandDetected ? "Рука в кадре" : (vm.hasRestingHand ? "Руки опущены" : "Нет руки")),
                      systemImage: vm.isHandDetected ? "hand.raised.fill" : "hand.raised.slash")
                // Плечи найдены — учитывается, где руки относительно тела.
                if vm.isBodyDetected {
                    Image(systemName: "figure.stand")
                        .accessibilityLabel("Плечи найдены")
                }
            }
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .softChip(vm.isHandDetected ? Soft.ok : Soft.muted)
            .animation(Soft.animation, value: vm.isHandDetected)

            Spacer()

            lightMenu
            circleButton("arrow.triangle.2.circlepath.camera") { vm.switchCamera() }
            circleButton(vm.isRecognitionEnabled ? "eye.fill" : "eye.slash.fill") {
                vm.isRecognitionEnabled.toggle()
            }
            circleButton("questionmark") { showHelp = true }
        }
        .foregroundStyle(.white)
    }

    /// Подсветка: авто / всегда / выключена. Жёлтый кружок — подсветка сейчас горит, буква A — авторежим.
    private var lightMenu: some View {
        Menu {
            Picker("Подсветка", selection: $vm.lightMode) {
                ForEach(LightMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode)
                }
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: vm.isLightOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(vm.isLightOn ? Color.black.opacity(0.8) : Color.white)
                    .frame(width: 42, height: 42)
                    .background(vm.isLightOn ? AnyShapeStyle(Soft.warm) : AnyShapeStyle(Material.ultraThinMaterial),
                                in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                if vm.lightMode == .auto {
                    Text("A")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black.opacity(0.8))
                        .frame(width: 17, height: 17)
                        .background(Soft.accent, in: Circle())
                }
            }
        }
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            Picker("Режим", selection: $vm.mode) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())

            FPSLabel(live: vm.live, isFront: vm.cameraPosition == .front)
        }
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(SoftIconButtonStyle(size: 42))
    }

    // MARK: Распознанный жест

    private var gestureBadge: some View {
        HStack(spacing: 14) {
            HoldRing(live: vm.live, emoji: vm.currentSign.emoji)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.isRecognitionEnabled ? vm.currentSign.title : "Распознавание выключено")
                    .font(.headline)
                Text(badgeSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .softCard(cornerRadius: 24)
        .animation(Soft.animation, value: vm.currentSign)
    }

    private var badgeSubtitle: String {
        switch vm.mode {
        case .control:
            if let command = vm.lastCommand {
                return "Команда: \(vm.lastGesture.emoji) \(command.title)"
            }
        case .translate:
            if let hint = vm.hint {
                return hint
            }
            if let word = vm.lastWord {
                return "Последнее слово: «\(word)»"
            }
        }
        return "Покажите жест в камеру"
    }

    // MARK: Режим «Перевод»

    private var translationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                // Голосовой перевод: речь людей вокруг → текст на отдельной странице.
                Button {
                    showSpeech = true
                } label: {
                    Label("Речь → текст", systemImage: "mic.fill")
                }
                .buttonStyle(SoftPillButtonStyle(prominent: true))
                Button {
                    showLibrary = true
                } label: {
                    Label("Словарь", systemImage: "plus")
                }
                .buttonStyle(SoftPillButtonStyle())
                Spacer(minLength: 0)
            }
            .lineLimit(1)

            Text(vm.phraseWords.isEmpty
                 ? (vm.library.signs.isEmpty
                    ? "Словарь пуст. Нажмите «Словарь» и покажите жесты, которые нужно переводить."
                    : "Показывайте жесты — перевод появится здесь")
                 : vm.phraseText)
                .font(vm.phraseWords.isEmpty ? Font.body : Font.system(.largeTitle, design: .rounded).bold())
                .foregroundStyle(vm.phraseWords.isEmpty ? Color.secondary : Color.primary)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentTransition(.opacity)

            HStack(spacing: 8) {
                Button {
                    vm.deleteLastWord()
                } label: {
                    Image(systemName: "delete.left")
                }
                .buttonStyle(SoftIconButtonStyle(size: 42))
                .accessibilityLabel("Стереть слово")
                Button {
                    vm.finishPhrase()
                } label: {
                    Label("Готово", systemImage: "checkmark")
                }
                .buttonStyle(SoftPillButtonStyle(tint: Soft.ok))
                .accessibilityLabel("Фраза готова")
                Spacer(minLength: 0)
                Button {
                    vm.speakPhrase()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(SoftIconButtonStyle(size: 42))
                .accessibilityLabel("Произнести")
                Button {
                    vm.isSpeechEnabled.toggle()
                } label: {
                    Image(systemName: vm.isSpeechEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .buttonStyle(SoftIconButtonStyle(size: 42))
                .accessibilityLabel(vm.isSpeechEnabled ? "Выключить голос" : "Включить голос")
                Button {
                    vm.clearTranslation()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(SoftIconButtonStyle(size: 42, iconColor: Soft.alert))
                .accessibilityLabel("Очистить")
            }
            .lineLimit(1)

            if !vm.phraseHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.phraseHistory.enumerated()), id: \.offset) { _, phrase in
                        Text(phrase)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Label("Опустите руки на 2 секунды — фраза закончится сама", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .softCard(cornerRadius: 30)
        .animation(Soft.animation, value: vm.phraseWords)
    }

    // MARK: Режим «Управление» (демо-интерфейс)

    private var demoPanel: some View {
        let screen = vm.screens[vm.screenIndex]

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: screen.icon)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Soft.accent.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(screen.title).font(.title3.bold())
                    Text("Экран \(vm.screenIndex + 1) из \(vm.screens.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.selectedIndex == vm.screenIndex {
                    Label("Выбран", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Soft.ok)
                }
            }

            HStack(spacing: 6) {
                ForEach(vm.screens.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == vm.screenIndex ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: i == vm.screenIndex ? 18 : 6, height: 6)
                }
            }

            HStack {
                Image(systemName: vm.isPlaying ? "play.fill" : "pause.fill")
                Text(vm.isPlaying ? "Воспроизведение" : "Пауза")
                Spacer()
                Image(systemName: "speaker.wave.2.fill")
                Text("\(vm.volume)%").monospacedDigit()
            }
            .font(.subheadline)

            ProgressView(value: Double(vm.volume), total: 100)

            if let confirmation = vm.confirmation {
                Label(confirmation, systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(Soft.ok)
            }

            if !vm.log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(vm.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .softCard(cornerRadius: 30)
        .animation(Soft.animation, value: vm.screenIndex)
        .animation(Soft.animation, value: vm.volume)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
        }
        .padding(26)
        .softCard()
        .padding(32)
    }
}

// MARK: - Справка по жестам

struct GestureHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Перевод (сурдоперевод)") {
                    Text("Приложение переводит жесты, которым его научили: «Перевод» → «Словарь» → слово → «Записать жест».")
                    Text("«Поза» — жест без движения, его нужно задержать на долю секунды. «С движением» — жест распознаётся целиком, как только закончен, можно показывать быстро.")
                    Text("Каждое слово лучше записать 2–3 раза: с разных камер, при разном свете. Чем больше примеров, тем точнее перевод.")
                    Text("Задняя камера: наведите телефон на собеседника — перевод на экране и голосом. Фронтальная: жестикулирующий сам видит, правильно ли переведено.")
                    Text("Опустите руки на 2 секунды — фраза закончится и уйдёт в историю.")
                    Text("Разные люди: приложение сравнивает углы сгиба пальцев, а не их длину, и понимает левую руку как зеркало правой. Для лучшей точности запишите одно слово у 2–3 разных людей.")
                    Text("Разные ракурсы: записывайте жесты «С трёх ракурсов». Если палец скрыт при повороте, он учитывается слабее, а не ломает распознавание.")
                    Text("Жест одной рукой: вторую руку можно держать опущенной — на столе или на коленях. Неподвижная опущенная рука не учитывается (на экране она серая). Как только она поднимается или двигается, жест считается жестом двумя руками.")
                    Text("Если новый жест похож на уже записанное слово, приложение предупредит об этом после записи. Похожие слова (например, одна форма кисти у подбородка и у груди) распознаются строже, чтобы их не путать, а поза засчитывается, только когда пальцы перестали двигаться — переходы между жестами не превращаются в лишние слова.")
                    Text("Подсказка «Похоже на «слово» — N%»: 100% — жест достаточно похож, чтобы засчитаться. Если процент держится ниже, сдвиньте «Чувствительность» вправо или запишите слово ещё раз — лучше тем же человеком и при том же свете. Для жестов с движением в скобках бывает причина отказа: «мало движения» — покажите с тем же размахом, что при записи; «слишком быстро» — медленнее.")
                    Text("Плечи: приложение само находит плечи на каждом кадре (линия между плечами) и учитывает, где руки относительно тела. Чтобы это работало, в кадре должны быть видны плечи. Отключить — «Словарь» → «Учитывать плечи».")
                }
                .font(.footnote)

                Section("Речь → текст") {
                    Text("Кнопка «Речь → текст» в панели перевода открывает голосовой перевод: всё, что говорят вокруг, сразу появляется на экране крупным текстом. Когда говорят несколько человек, каждая реплика после паузы — с новой строки.")
                    Text("Запинки, повторы и звуки-паузы («э-э») убираются. Имена и редкие слова добавьте в «Мои слова» (кнопка «…») — тогда они распознаются точнее и исправляются, если распознаны с ошибкой.")
                    Text("Дальняя речь: кнопка с ухом (включена сразу) усиливает тихий и далёкий голос — до 10 метров в тихом помещении — и убирает низкий гул. Положите телефон микрофоном (низом) к говорящему. В шуме или на улице дайте говорящему наушники Bluetooth с микрофоном и включите «Микрофон Bluetooth» (кнопка «…»).")
                }
                .font(.footnote)

                Section("Подсветка") {
                    Text("Кнопка с фонариком вверху: «Авто» — включается сама, когда темно, и выключается, когда стало светло; «Всегда вкл.» или «Выключена».")
                    Text("У задней камеры светит фонарик. У фронтальной фонарика нет — светит экран: яркость на максимум и белая рамка вокруг изображения.")
                }
                .font(.footnote)

                Section("Управление — статичные жесты (удерживать 0,4 с)") {
                    ForEach(Gesture.allCases.filter { $0 != .idle && !$0.isDynamic && $0.command != nil }) { row($0) }
                }
                Section("Управление — движения руки") {
                    ForEach(Gesture.allCases.filter(\.isDynamic)) { row($0) }
                }
            }
            .navigationTitle("Справка")
            .toolbar {
                Button("Готово") { dismiss() }
            }
        }
    }

    private func row(_ gesture: Gesture) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(gesture.emoji).font(.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(gesture.title).font(.headline)
                Text(gesture.hint).font(.caption).foregroundStyle(.secondary)
                Text("Команда: \(gesture.command?.title ?? "—")").font(.caption)
            }
        }
    }
}

// MARK: - Словарь жестов для перевода

struct SignLibraryView: View {
    @ObservedObject var library: SignLibrary
    let onRecord: (String, Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newWord = ""
    @State private var isDynamic = true
    @State private var multiAngle = true

    private var canRecord: Bool {
        !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Слово или фраза", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                    Picker("Тип жеста", selection: $isDynamic) {
                        Text("С движением").tag(true)
                        Text("Поза").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle("С трёх ракурсов (рекомендуется)", isOn: $multiAngle)
                    Button {
                        let word = newWord
                        newWord = ""
                        dismiss()
                        onRecord(word, isDynamic, multiAngle)
                    } label: {
                        Label("Записать жест", systemImage: "record.circle")
                    }
                    .disabled(!canRecord)
                } header: {
                    Text("Научить новому жесту")
                } footer: {
                    Text((isDynamic
                          ? "После отсчёта покажите жест целиком за 2,5 секунды, как обычно при разговоре. "
                          : "После отсчёта держите позу 2 секунды. ")
                         + (multiAngle
                            ? "Запись пройдёт 3 раза: прямо, чуть левее и чуть правее — так жест будет узнаваться и под углом."
                            : "Можно одной или двумя руками."))
                }

                Section {
                    if library.signs.isEmpty {
                        Text("Пока пусто. Запишите жесты, которые нужно переводить.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.signs) { sign in
                        HStack {
                            Text(sign.handCount == 2 ? "🙌" : "🤟")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sign.word)
                                Text(sign.isDynamic ? "с движением" : "поза")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("записей: \(sign.exampleCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        library.delete(at: offsets)
                    }
                } header: {
                    Text("Словарь: \(library.signs.count)")
                } footer: {
                    Text("Чтобы жест понимали у всех, запишите одно и то же слово у 2–3 разных людей — записи добавятся к слову. Удалить слово — свайп влево по строке.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Slider(value: $library.sensitivity, in: 0.6...1.6, step: 0.1)
                        HStack {
                            Text("Строже")
                            Spacer()
                            Text("\(Int((library.sensitivity * 100).rounded())) %")
                                .monospacedDigit()
                            Spacer()
                            Text("Мягче")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Чувствительность")
                } footer: {
                    Text("Если жесты часто не распознаются — сдвиньте вправо. Если появляются лишние слова — влево.")
                }

                Section {
                    Toggle("Учитывать плечи", isOn: $library.useShoulders)
                } footer: {
                    Text("Плечи находятся автоматически на каждом кадре (на экране — линия между плечами, как точки рук). Тогда одна и та же форма кисти у подбородка, у груди и у плеча — разные слова. Если плечи не видны, жест распознаётся только по кистям.")
                }
            }
            .navigationTitle("Словарь жестов")
            .toolbar {
                Button("Готово") { dismiss() }
            }
        }
    }
}

// MARK: - Индикаторы, которые меняются на каждом кадре

/// Кольцо удержания статичного жеста.
struct HoldRing: View {
    @ObservedObject var live: LiveState
    let emoji: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: live.holdProgress)
                .stroke(Soft.ok, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(emoji)
                .font(.system(size: 28))
        }
    }
}

/// Частота обработки кадров и текущая камера.
struct FPSLabel: View {
    @ObservedObject var live: LiveState
    let isFront: Bool

    var body: some View {
        Text("\(live.fps) FPS · \(isFront ? "фронт." : "задняя")")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
            .softChip()
    }
}
