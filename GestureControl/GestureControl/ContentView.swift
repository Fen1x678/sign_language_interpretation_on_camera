import SwiftUI
import AVFoundation
import Combine

/// Пользовательский интерфейс: изображение с камеры, скелет руки,
/// распознанный жест, состояние системы, перевод или демо-интерфейс управления.
struct ContentView: View {
    @StateObject private var vm = GestureViewModel()
    @State private var showHelp = false
    @State private var showLibrary = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: vm.session) { layer in
                vm.previewLayer = layer
            }
            .ignoresSafeArea()

            HandOverlay(hands: vm.handPoints, isActive: vm.currentSign != .none)
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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
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
        .animation(.snappy, value: vm.notice)
        .preferredColorScheme(.dark)
        .task { await vm.start() }
        .onChange(of: scenePhase) { _, phase in
            vm.scenePhaseChanged(phase)
        }
        .sheet(isPresented: $showHelp) { GestureHelpView() }
        .sheet(isPresented: $showLibrary) {
            SignLibraryView(library: vm.library) { word, dynamic in
                vm.startRecording(word: word, dynamic: dynamic)
            }
        }
    }

    // MARK: Запись нового жеста

    private var recordingOverlay: some View {
        VStack(spacing: 14) {
            switch vm.recording {
            case .countdown(let n):
                Text("Приготовьтесь показать жест")
                    .font(.headline)
                Text("\(n)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
            case .recording(let progress):
                Text(vm.recordingDynamic ? "Покажите жест целиком, с движением" : "Держите жест")
                    .font(.headline)
                ProgressView(value: progress)
                    .tint(.red)
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
        .padding(24)
        .frame(maxWidth: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.snappy, value: vm.recording)
    }

    // MARK: Верхняя панель: состояние системы и кнопки

    private var topBar: some View {
        HStack(spacing: 8) {
            Label(vm.handCount >= 2 ? "Две руки" : (vm.isHandDetected ? "Рука в кадре" : "Нет руки"),
                  systemImage: vm.isHandDetected ? "hand.raised.fill" : "hand.raised.slash")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(vm.isHandDetected ? Color.green.opacity(0.8) : Color.red.opacity(0.7),
                            in: Capsule())

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
                    .foregroundStyle(vm.isLightOn ? Color.black : Color.white)
                    .frame(width: 38, height: 38)
                    .background(vm.isLightOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(Material.ultraThinMaterial),
                                in: Circle())
                if vm.lightMode == .auto {
                    Text("A")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Color.blue, in: Circle())
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

            Text("\(Int(vm.fps.rounded())) FPS · \(vm.cameraPosition == .front ? "фронт." : "задняя")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: Распознанный жест

    private var gestureBadge: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: vm.holdProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(vm.currentSign.emoji)
                    .font(.system(size: 28))
            }
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
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var badgeSubtitle: String {
        switch vm.mode {
        case .control:
            if let command = vm.lastCommand {
                return "Команда: \(vm.lastGesture.emoji) \(command.title)"
            }
        case .translate:
            if let word = vm.lastWord {
                return "Последнее слово: «\(word)»"
            }
        }
        return "Покажите жест в камеру"
    }

    // MARK: Режим «Перевод»

    private var translationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Перевод", systemImage: "character.bubble")
                    .font(.headline)
                Spacer()
                Button {
                    showLibrary = true
                } label: {
                    Label("Словарь", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                Button {
                    vm.speakPhrase()
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                Button {
                    vm.isSpeechEnabled.toggle()
                } label: {
                    Image(systemName: vm.isSpeechEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                        .frame(width: 32)
                }
            }

            Text(vm.phraseWords.isEmpty
                 ? (vm.library.signs.isEmpty
                    ? "Словарь пуст. Нажмите «Словарь» и покажите жесты, которые нужно переводить."
                    : "Показывайте жесты — перевод появится здесь")
                 : vm.phraseText)
                .font(vm.phraseWords.isEmpty ? Font.body : Font.largeTitle.bold())
                .foregroundStyle(vm.phraseWords.isEmpty ? Color.secondary : Color.primary)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    vm.deleteLastWord()
                } label: {
                    Label("Стереть", systemImage: "delete.left")
                }
                Button {
                    vm.finishPhrase()
                } label: {
                    Label("Фраза готова", systemImage: "return")
                }
                Spacer()
                Button(role: .destructive) {
                    vm.clearTranslation()
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)

            if !vm.phraseHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.phraseHistory.enumerated()), id: \.offset) { _, phrase in
                        Text(phrase)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Опустите руки на 2 секунды — фраза закончится сама")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.snappy, value: vm.phraseWords)
    }

    // MARK: Режим «Управление» (демо-интерфейс)

    private var demoPanel: some View {
        let screen = vm.screens[vm.screenIndex]

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: screen.icon)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        .foregroundStyle(.green)
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
                    .foregroundStyle(.green)
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
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.snappy, value: vm.screenIndex)
        .animation(.snappy, value: vm.volume)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
    let onRecord: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newWord = ""
    @State private var isDynamic = true

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
                    Button {
                        let word = newWord
                        newWord = ""
                        dismiss()
                        onRecord(word, isDynamic)
                    } label: {
                        Label("Записать жест", systemImage: "record.circle")
                    }
                    .disabled(!canRecord)
                } header: {
                    Text("Научить новому жесту")
                } footer: {
                    Text(isDynamic
                         ? "После отсчёта 3-2-1 покажите жест целиком за 2,5 секунды, как обычно при разговоре. Можно одной или двумя руками."
                         : "После отсчёта 3-2-1 держите позу 2 секунды. Можно одной или двумя руками.")
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
            }
            .navigationTitle("Словарь жестов")
            .toolbar {
                Button("Готово") { dismiss() }
            }
        }
    }
}
