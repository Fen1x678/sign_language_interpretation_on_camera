package com.fen1x.speech

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fen1x.speech.camera.CameraController
import com.fen1x.speech.camera.CameraFrame
import com.fen1x.speech.core.AppMode
import com.fen1x.speech.core.BodyReference
import com.fen1x.speech.core.Command
import com.fen1x.speech.core.CustomSign
import com.fen1x.speech.core.FrameFeatures
import com.fen1x.speech.core.Gesture
import com.fen1x.speech.core.GestureRecognizer
import com.fen1x.speech.core.HandGeometry
import com.fen1x.speech.core.HandSample
import com.fen1x.speech.core.HandSmoother
import com.fen1x.speech.core.MotionSpotter
import com.fen1x.speech.core.MotionStream
import com.fen1x.speech.core.Pt
import com.fen1x.speech.core.RecognitionResult
import com.fen1x.speech.core.RestingHandFilter
import com.fen1x.speech.core.ShoulderSmoother
import com.fen1x.speech.core.Sign
import com.fen1x.speech.core.SignFrame
import com.fen1x.speech.core.SignLibrary
import com.fen1x.speech.core.SignMatching
import com.fen1x.speech.core.Timed
import com.fen1x.speech.core.dist
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Экран демо-интерфейса в режиме «Управление». */
data class DemoScreen(val title: String, val icon: String)

/** Состояние записи нового жеста. */
sealed class RecordingState {
    object Idle : RecordingState()
    data class Countdown(val n: Int) : RecordingState()
    data class Recording(val progress: Float) : RecordingState()
}

/** Режим подсветки. */
enum class LightMode(val title: String) {
    AUTO("Авто"),
    ON("Всегда вкл."),
    OFF("Выключена"),
}

/** Вибрация-отклик на действие. */
enum class Haptic { LIGHT, MEDIUM, SUCCESS, WARNING, ERROR }

/**
 * Данные, которые меняются на каждом кадре. Вынесены отдельно, чтобы 30 раз в секунду
 * перерисовывались только скелет рук и индикаторы, а не весь интерфейс.
 */
class LiveState {
    /** Точки найденных рук (одна или две) в dp экрана — для отрисовки скелета. */
    var handPoints by mutableStateOf<List<List<Pt>>>(emptyList())
    /** Прогресс удержания статичного жеста, 0…1. */
    var holdProgress by mutableFloatStateOf(0f)
    var fps by mutableIntStateOf(0)
    /** Плечи в dp экрана (две точки или пусто) — для отрисовки. */
    var shoulders by mutableStateOf<List<Pt>>(emptyList())
    /** Для каждой руки из [handPoints]: рука опущена и не учитывается (рисуется серым). */
    var resting by mutableStateOf<List<Boolean>>(emptyList())
}

/** Кадр для жестов с движением: все руки в кадре и отдельно ведущая (движущаяся) рука. */
private class MotionSample(val all: FrameFeatures, val main: FrameFeatures?)

/**
 * Связывает камеру, распознавание и интерфейс.
 * Блоки схемы «Определение команды → Выполнение действия → Отображение результата».
 */
class GestureViewModel(app: Application) : AndroidViewModel(app) {
    // MARK: Камера
    val camera = CameraController(app)
    var isFront by mutableStateOf(true)
        private set

    // MARK: Режим
    var mode by mutableStateOf(AppMode.TRANSLATE)
        private set

    // MARK: Результат распознавания
    /** Скелет рук, прогресс удержания и FPS — меняются на каждом кадре. */
    val live = LiveState()
    /** Сколько рук учитывается в распознавании (опущенная вторая рука не считается). */
    var handCount by mutableIntStateOf(0)
        private set
    /** В кадре есть опущенная рука, которая не учитывается. */
    var hasRestingHand by mutableStateOf(false)
        private set
    val isHandDetected: Boolean get() = handCount > 0
    /** Плечи найдены: положение рук относительно тела учитывается. */
    var isBodyDetected by mutableStateOf(false)
        private set
    /** Подсказка в режиме «Перевод»: на какое слово похоже то, что сейчас в кадре, и насколько. */
    var hint by mutableStateOf<String?>(null)
        private set
    private var lastHintUpdate = 0.0
    var currentSign by mutableStateOf<Sign>(Sign.None)
        private set
    var cameraError by mutableStateOf<String?>(null)
        private set
    var notice by mutableStateOf<String?>(null)
        private set
    private var noticeJob: Job? = null
    var isRecognitionEnabled by mutableStateOf(true)
        private set

    /** Отклик вибрацией: экран подписывается и вибрирует. */
    val haptics = MutableSharedFlow<Haptic>(extraBufferCapacity = 8)

    // MARK: Подсветка
    var lightMode by mutableStateOf(LightMode.AUTO)
        private set
    /** Подсветка включена (фонарик у задней камеры или экран у фронтальной). */
    var isLightOn by mutableStateOf(false)
        private set
    /** Подсветка экраном (у фронтальной камеры нет фонарика): яркость на максимум и белая рамка. */
    var isScreenLightOn by mutableStateOf(false)
        private set
    private var sceneBrightness: Double? = null
    private var darkSince: Double? = null
    private var brightSince: Double? = null
    private var lightChangedAt = 0.0
    private var brightnessWithLight: Double? = null
    private var lastAutoOffAt = -100.0
    private var offMargin = 2.0
    /** Приложение на экране и активно. */
    private var isAppActive = true
    /** Камера остановлена, пока открыта страница «Речь → текст». */
    private var isCameraPaused = false
    /** Ниже этой яркости (шкала APEX) сцена считается тёмной. */
    private val darkLevel = -1.0

    // MARK: Словарь жестов и обучение
    val library = SignLibrary()
    private val store = SignStore(app)
    var signs by mutableStateOf<List<CustomSign>>(emptyList())
        private set
    var sensitivity by mutableStateOf(1.0)
        private set
    var useShoulders by mutableStateOf(true)
        private set
    var recording by mutableStateOf<RecordingState>(RecordingState.Idle)
        private set
    var recordingWord by mutableStateOf("")
        private set
    var recordingDynamic by mutableStateOf(false)
        private set
    /** Подсказка к текущей записи: какой ракурс показать. */
    var recordingPrompt by mutableStateOf("")
        private set
    /** Номер ракурса и сколько их всего (запись с нескольких ракурсов). */
    var recordingStep by mutableIntStateOf(1)
        private set
    var recordingSteps by mutableIntStateOf(1)
        private set
    private val pendingPrompts = ArrayList<String>()
    private val recordedFrames = ArrayList<Timed<SignFrame>>()
    /** Для жестов с движением: кадры только ведущей руки и скорости рук на каждом кадре. */
    private val recordedMainFrames = ArrayList<Timed<SignFrame>>()
    private val recordedSpeeds = ArrayList<Pair<Double, Double?>>()
    /** Похожее слово словаря, найденное при записи (предупреждаем в конце записи). */
    private var similarWord: String? = null
    private var recordingTooStill = false
    private var recordingStart = 0.0
    private val recordingDuration: Double get() = if (recordingDynamic) 2.5 else 2.0

    // MARK: Плечи
    /** Плечи в dp экрана, слева направо (сглажены). Пусто — не найдены. */
    private var shoulderPoints: List<Pt> = emptyList()
    private val shoulderSmoother = ShoulderSmoother()

    // MARK: Движение рук
    private val smoother = HandSmoother()
    /** Опущенная (лежащая) вторая рука не участвует в распознавании. */
    private val restingFilter = RestingHandFilter()
    private val motionBuffer = ArrayList<Timed<MotionSample>>()
    /** Центры рук за последние доли секунды — для скорости каждой руки. */
    private val centerHistory = ArrayList<Timed<List<Pt>>>()
    /** Где была ведущая (движущаяся) рука на прошлом кадре. */
    private var mainCenter: Pt? = null
    private val spotter = MotionSpotter()
    private var lastHandSeenTime = 0.0
    private var frameCounter = 0
    private var motionCooldownUntil = 0.0

    // MARK: Режим «Перевод»
    var phraseWords by mutableStateOf<List<String>>(emptyList())
        private set
    var phraseHistory by mutableStateOf<List<String>>(emptyList())
        private set
    var lastWord by mutableStateOf<String?>(null)
        private set
    var isSpeechEnabled by mutableStateOf(true)
        private set
    val phraseText: String get() = sentence(phraseWords)
    /** Если рук нет в кадре дольше этого времени, фраза заканчивается сама. */
    private val phrasePause = 2.0
    private val speaker = Speaker(app)

    // MARK: Режим «Управление» (демо-интерфейс)
    val screens = listOf(
        DemoScreen("Главная", "🏠"),
        DemoScreen("Музыка", "🎵"),
        DemoScreen("Фото", "🖼️"),
        DemoScreen("Настройки", "⚙️"),
    )
    var screenIndex by mutableIntStateOf(0)
        private set
    var selectedIndex by mutableStateOf<Int?>(null)
        private set
    var volume by mutableIntStateOf(50)
        private set
    var isPlaying by mutableStateOf(true)
        private set
    var confirmation by mutableStateOf<String?>(null)
        private set
    var log by mutableStateOf<List<String>>(emptyList())
        private set
    var lastGesture by mutableStateOf(Gesture.IDLE)
        private set
    var lastCommand by mutableStateOf<Command?>(null)
        private set

    private val recognizer = GestureRecognizer()
    private var lastFrameTime = 0.0
    private var fpsAverage = 0.0
    private var lastFPSUpdate = 0.0

    /** Размер изображения камеры на экране в dp (координаты точек переводятся в них). */
    private var viewWidth = 0f
    private var viewHeight = 0f

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingFrame = AtomicReference<CameraFrame?>(null)

    init {
        store.load(library)
        signs = library.signs
        sensitivity = library.sensitivity
        useShoulders = store.useShoulders
        camera.bodyTracking = useShoulders
        library.onChange = {
            signs = library.signs
            store.save(library)
        }
        // Кадры обрабатываются на главном потоке; если обработка не успевает, берётся самый свежий кадр.
        camera.onFrame = { frame ->
            if (pendingFrame.getAndSet(frame) == null) {
                mainHandler.post { pendingFrame.getAndSet(null)?.let { process(it) } }
            }
        }
        camera.onError = { cameraError = it }
        applyModeSettings()
    }

    override fun onCleared() {
        camera.onFrame = null
        camera.release()
        speaker.shutdown()
    }

    private fun now(): Double = SystemClock.elapsedRealtimeNanos() / 1e9

    // MARK: Запуск и настройки

    fun setViewSize(widthDp: Float, heightDp: Float) {
        viewWidth = widthDp
        viewHeight = heightDp
    }

    fun cameraPermissionDenied() {
        cameraError = "Нет доступа к камере. Разрешите его: Настройки → Приложения → speech → Разрешения → Камера."
    }

    fun cameraPermissionGranted() {
        if (cameraError?.startsWith("Нет доступа к камере") == true) cameraError = null
    }

    fun changeMode(newMode: AppMode) {
        if (mode == newMode) return
        mode = newMode
        applyModeSettings()
    }

    fun toggleRecognition() {
        isRecognitionEnabled = !isRecognitionEnabled
        if (!isRecognitionEnabled) resetRecognition()
    }

    fun toggleSpeech() {
        isSpeechEnabled = !isSpeechEnabled
        if (!isSpeechEnabled) speaker.stop()
    }

    fun changeSensitivity(value: Double) {
        sensitivity = value
        library.sensitivity = value
        store.sensitivity = value
    }

    fun changeUseShoulders(on: Boolean) {
        useShoulders = on
        store.useShoulders = on
        camera.bodyTracking = on
    }

    fun deleteSign(id: String) {
        library.delete(id)
    }

    /** Фронтальная ↔ задняя камера. Экран сам переподключит камеру, увидев новое значение [isFront]. */
    fun switchCamera() {
        val wasLightOn = isLightOn
        setLight(false)
        isFront = !isFront
        camera.setFront(isFront)
        live.handPoints = emptyList()
        centerHistory.clear()
        mainCenter = null
        shoulderPoints = emptyList()
        shoulderSmoother.reset()
        smoother.reset()
        restingFilter.reset()
        sceneBrightness = null
        resetRecognition()
        haptic(Haptic.LIGHT)
        if (wasLightOn) {
            // Фонарик новой камеры доступен, когда она подключится.
            viewModelScope.launch {
                delay(800)
                setLight(true)
            }
        }
    }

    /**
     * Приложение свёрнуто или снова открыто. Подсветка выключается сразу, как только
     * приложение перестаёт быть активным; яркость экрана Android возвращает сам.
     */
    fun onAppActive(active: Boolean) {
        isAppActive = active
        if (active) {
            if (lightMode == LightMode.ON && !isCameraPaused) setLight(true)
        } else {
            setLight(false)
        }
    }

    /** Камера не нужна, пока открыта страница «Речь → текст». */
    fun setCameraPaused(paused: Boolean) {
        if (paused == isCameraPaused) return
        isCameraPaused = paused
        if (paused) {
            setLight(false)
            resetRecognition()
            live.handPoints = emptyList()
            live.shoulders = emptyList()
            handCount = 0
            hasRestingHand = false
            restingFilter.reset()
        } else if (lightMode == LightMode.ON && isAppActive) {
            setLight(true)
        }
    }

    private fun applyModeSettings() {
        // В переводе жесты показывают быстро: короче удержание, свайпы не мешают.
        recognizer.swipesEnabled = mode == AppMode.CONTROL
        recognizer.holdDuration = if (mode == AppMode.TRANSLATE) 0.3 else 0.4
        resetRecognition()
    }

    private fun resetRecognition() {
        recognizer.reset()
        spotter.reset()
        motionBuffer.clear()
        currentSign = Sign.None
        live.holdProgress = 0f
    }

    private fun haptic(type: Haptic) {
        haptics.tryEmit(type)
    }

    // MARK: Обработка кадра

    private fun process(frame: CameraFrame) {
        if (isCameraPaused) return
        val now = now()
        updateFPS(now)
        updateLight(frame.brightness, now)

        val width = viewWidth
        val height = viewHeight
        if (width <= 0f || height <= 0f) return

        // Координаты кадра → dp экрана, затем сглаживание дрожания точек.
        var samples = frame.hands.map { hand ->
            HandSample(
                hand.points.map { p -> if (p.x < 0f || p.y < 0f) Pt.MISSING else Pt(p.x * width, p.y * height) },
                hand.confidence,
                hand.chirality,
            )
        }
        samples = smoother.smooth(samples, now)

        // Задняя камера видит собеседника «не в зеркале». Отражаем по горизонтали, чтобы
        // жест выглядел одинаково с обеих камер, а «влево/вправо» считались со стороны жестикулирующего.
        val allRecognitionSamples = if (!isFront) samples.map { it.flipped(width) } else samples

        // Плечи находятся автоматически; относительно них считается, где находятся руки.
        val shoulders = updateShoulders(frame, now)
        var body: BodyReference? = null
        if (shoulders.size == 2) {
            body = BodyReference.from(if (!isFront) shoulders.map { Pt(width - it.x, it.y) } else shoulders)
        }

        // Опущенная неподвижная вторая рука (на столе, на коленях) не учитывается,
        // пока не поднимется или не начнёт двигаться.
        val active = restingFilter.update(allRecognitionSamples, body, height, now)
        val recognitionSamples = allRecognitionSamples.filterIndexed { i, _ -> active[i] }
        val handsForRecognition = recognitionSamples.map { it.thresholded() }

        // Для рисования скелета — только уверенно найденные точки; опущенная рука — серым.
        val screenHands = samples.map { it.thresholded() }
        if (handCount != recognitionSamples.size) handCount = recognitionSamples.size
        val resting = active.size > recognitionSamples.size
        if (hasRestingHand != resting) hasRestingHand = resting
        if (!(screenHands.isEmpty() && live.handPoints.isEmpty())) {
            live.handPoints = screenHands
            live.resting = active.map { !it }
        }

        val geometries = handsForRecognition.mapNotNull { HandGeometry.from(it) }
        if (geometries.isNotEmpty()) lastHandSeenTime = now
        val usable = recognitionSamples.filter { it.palmSize > 10f }
        val (velocities, main) = trackHands(usable, now)
        val mainSample = main?.let { usable[it] }
        val mainVelocity = main?.let { velocities[it] }
        val poseFrame = SignFrame.make(recognitionSamples, body = body)
        val motionFrame = mainVelocity?.let { SignFrame.make(recognitionSamples, it, body) }
        // Если в кадре две руки, отдельно берём ведущую: жест одной рукой должен узнаваться,
        // даже когда вторая (опущенная) рука тоже видна.
        val mainMotionFrame: SignFrame? = if (motionFrame?.handCount == 2) {
            mainSample?.let { SignFrame.make(listOf(it), mainVelocity, body) }
        } else {
            motionFrame
        }
        val poseVariants = ArrayList<SignFrame>()
        if (poseFrame != null) poseVariants.add(poseFrame)
        if (poseFrame?.handCount == 2) {
            usable.mapNotNullTo(poseVariants) { SignFrame.make(listOf(it), body = body) }
        }

        // Запись нового жеста.
        when (recording) {
            is RecordingState.Countdown -> return
            is RecordingState.Recording -> {
                if (recordingDynamic) {
                    if (motionFrame != null) {
                        recordedFrames.add(Timed(now, motionFrame))
                        if (mainMotionFrame != null) recordedMainFrames.add(Timed(now, mainMotionFrame))
                        if (main != null) {
                            val speeds = velocities.map { hypot(it.x, it.y).toDouble() }
                            val other = speeds.indices.filter { it != main }.maxOfOrNull { speeds[it] }
                            recordedSpeeds.add(Pair(speeds[main], other))
                        }
                    }
                } else if (poseFrame != null) {
                    recordedFrames.add(Timed(now, poseFrame))
                }
                val elapsed = now - recordingStart
                if (elapsed >= recordingDuration) {
                    finishRecording()
                } else {
                    recording = RecordingState.Recording((elapsed / recordingDuration).toFloat())
                }
                return
            }
            RecordingState.Idle -> Unit
        }

        if (!isRecognitionEnabled) {
            if (hint != null) hint = null
            return
        }

        if (mode == AppMode.TRANSLATE) {
            // Руки опущены — фраза закончена.
            if (geometries.isEmpty() && phraseWords.isNotEmpty() && now - lastHandSeenTime > phrasePause) {
                finishPhrase()
            }
            // Жесты с движением: сравниваем последние 1,5–3 секунды с записанными жестами.
            if (recognizeMotion(motionFrame, mainMotionFrame, now)) {
                updateHint(now)
                return
            }
        }

        val poseFeatures = poseVariants.map { FrameFeatures.from(it) }
        val result = recognizer.process(handsForRecognition, now) { hands -> classifyStatic(hands, poseFeatures) }
        apply(result)
        updateHint(now)
    }

    /**
     * Подсказка под жестом: на какое слово похоже то, что сейчас в кадре, и насколько (100% — достаточно
     * для распознавания). Помогает понять, почему слово не засчитывается и нужно ли сдвинуть «Чувствительность».
     */
    private fun updateHint(now: Double) {
        if (now - lastHintUpdate < 0.25) return
        lastHintUpdate = now
        var text: String? = null
        val candidate = library.lastCandidate
        if (mode == AppMode.TRANSLATE && currentSign == Sign.None && isHandDetected && candidate != null) {
            val percent = (max(0f, min(1f, 2 - candidate.ratio)) * 100).roundToInt()
            if (percent >= 20) {
                var line = "Похоже на «${candidate.word}» — $percent%"
                if (candidate.reason != null) line += " (${candidate.reason})"
                text = line
            }
        }
        // Берём самое похожее слово за последние 0,25 с и начинаем копить заново.
        library.resetCandidate()
        if (hint != text) hint = text
    }

    /** Плечи в dp экрана. Камера ищет их на каждом кадре; здесь они сглаживаются тем же фильтром, что и руки. */
    private fun updateShoulders(frame: CameraFrame, now: Double): List<Pt> {
        if (useShoulders) {
            val found = frame.shoulders?.map { Pt(it.x * viewWidth, it.y * viewHeight) }?.sortedBy { it.x }
            shoulderPoints = shoulderSmoother.smooth(found, now)
        } else {
            shoulderSmoother.reset()
            shoulderPoints = emptyList()
        }
        if (live.shoulders != shoulderPoints) live.shoulders = shoulderPoints
        val detected = shoulderPoints.size == 2
        if (isBodyDetected != detected) isBodyDetected = detected
        return shoulderPoints
    }

    private fun updateFPS(now: Double) {
        if (lastFrameTime > 0) {
            val dt = now - lastFrameTime
            if (dt > 0) {
                fpsAverage = if (fpsAverage == 0.0) 1 / dt else fpsAverage * 0.9 + (1 / dt) * 0.1
            }
        }
        lastFrameTime = now
        // Показываем FPS два раза в секунду, а не на каждом кадре.
        if (now - lastFPSUpdate >= 0.5) {
            lastFPSUpdate = now
            val value = fpsAverage.roundToInt()
            if (live.fps != value) live.fps = value
        }
    }

    /**
     * Скорость каждой руки в ладонях в секунду и какая рука ведущая. Ведущая — та, что ближе
     * к прошлому положению (чтобы не «прыгать» между руками). Скорость считается по смещению
     * примерно за 0,1 с: так она меньше зависит от дрожания точек, чем смещение за один кадр.
     */
    private fun trackHands(hands: List<HandSample>, now: Double): Pair<List<Pt>, Int?> {
        centerHistory.removeAll { now - it.time > 0.4 }
        if (hands.isEmpty()) {
            centerHistory.clear()
            mainCenter = null
            return Pair(emptyList(), null)
        }
        val reference = centerHistory.lastOrNull { now - it.time >= 0.08 }
        centerHistory.add(Timed(now, hands.map { it.center }))

        val velocities = hands.map { hand ->
            val size = hand.palmSize
            val start = reference?.item?.minByOrNull { dist(it, hand.center) }
            if (reference == null || size <= 0f || start == null || dist(start, hand.center) >= size * 3) {
                Pt.ZERO
            } else {
                val dt = (now - reference.time).toFloat()
                Pt((hand.center.x - start.x) / size / dt, (hand.center.y - start.y) / size / dt)
            }
        }
        val speeds = velocities.map { hypot(it.x, it.y) }

        // Прошлая ведущая рука — та, что ближе к её прошлому положению; в начале — самая крупная.
        val previous = mainCenter
        var main = if (previous != null) {
            hands.indices.minByOrNull { dist(hands[it].center, previous) }!!
        } else {
            hands.indices.maxByOrNull { hands[it].palmSize }!!
        }
        // Ведущей становится другая рука, если она движется заметно быстрее
        // (неподвижная опущенная рука не должна «перехватывать» жест).
        val fastest = speeds.indices.maxByOrNull { speeds[it] }
        if (fastest != null && fastest != main && speeds[fastest] > 1.0f && speeds[fastest] > speeds[main] * 1.5f) {
            main = fastest
        }
        mainCenter = hands[main].center
        return Pair(velocities, main)
    }

    /** Возвращает true, если распознан жест с движением. */
    private fun recognizeMotion(frame: SignFrame?, mainFrame: SignFrame?, now: Double): Boolean {
        if (!library.hasDynamicSigns) return false

        if (now - lastHandSeenTime > 0.5) motionBuffer.clear()
        if (frame != null && now >= motionCooldownUntil) {
            val sample = MotionSample(FrameFeatures.from(frame), mainFrame?.let { FrameFeatures.from(it) })
            motionBuffer.add(Timed(now, sample))
        }
        val window = library.motionWindow
        motionBuffer.removeAll { now - it.time > window }

        // Сравниваем через кадр: этого хватает при частоте последовательностей 15 кадров в секунду.
        frameCounter += 1
        if (frameCounter % 2 != 0) return false

        // Кадры с равным шагом по времени — так же, как при подготовке записанного жеста.
        var best: MotionSpotter.Match? = null
        if (frame != null && motionBuffer.size >= 8) {
            val samples = SignMatching.resample(motionBuffer)
            val streams = arrayListOf(MotionStream(samples.map { it.all }))
            // Если в кадре бывает вторая рука, отдельно сравниваем ведущую руку с жестами одной рукой.
            if (samples.any { it.all.handCount == 2 }) {
                val mainOnly = samples.mapNotNull { it.main }
                if (mainOnly.size >= 4) streams.add(MotionStream(mainOnly))
            }
            best = library.bestMotion(streams)
        }
        // Жест засчитывается, когда сходство перестало расти (см. MotionSpotter).
        val id = spotter.update(best, now) ?: return false
        val sign = library.sign(id) ?: return false

        motionBuffer.clear()
        spotter.reset()
        motionCooldownUntil = now + 0.5
        recognizer.reset()
        recognizer.latchNextSign(now)   // конечная поза жеста не засчитывается отдельным словом
        val recognized = Sign.Custom(sign.id, sign.word)
        currentSign = recognized
        live.holdProgress = 1f
        translate(recognized)
        return true
    }

    /**
     * Статичный жест.
     * «Перевод»: только жесты из словаря пользователя. «Управление»: встроенные жесты.
     */
    private fun classifyStatic(hands: List<HandGeometry>, variants: List<FrameFeatures>): Sign {
        return when (mode) {
            AppMode.TRANSLATE -> {
                if (variants.isEmpty()) return Sign.None
                val sticky = (currentSign as? Sign.Custom)?.id
                val sign = library.classifyPose(variants, sticky) ?: return Sign.None
                Sign.Custom(sign.id, sign.word)
            }
            AppMode.CONTROL -> {
                val main = hands.maxByOrNull { it.size } ?: return Sign.None
                val gesture = main.staticGesture()
                if (gesture == Gesture.IDLE) Sign.None else Sign.BuiltIn(gesture)
            }
        }
    }

    private fun apply(result: RecognitionResult) {
        if (currentSign != result.sign) currentSign = result.sign
        val progress = result.holdProgress.toFloat()
        if (live.holdProgress != progress) live.holdProgress = progress

        val fired = result.fired ?: return
        when (mode) {
            AppMode.CONTROL -> {
                if (fired is Sign.BuiltIn) {
                    val command = fired.gesture.command
                    if (command != null) execute(command, fired.gesture)
                }
            }
            AppMode.TRANSLATE -> translate(fired)
        }
    }

    // MARK: Автоматическая подсветка

    fun changeLightMode(newMode: LightMode) {
        lightMode = newMode
        when (newMode) {
            LightMode.ON -> setLight(true)
            LightMode.OFF -> setLight(false)
            LightMode.AUTO -> {
                darkSince = null
                brightSince = null
                offMargin = 2.0
                val b = sceneBrightness
                if (b != null && b >= darkLevel) setLight(false)
            }
        }
    }

    /**
     * Включает подсветку в темноте и выключает, когда стало светло.
     * Когда подсветка включена, камера видит сцену светлее. Поэтому выключаем её,
     * только если стало заметно светлее, чем было с подсветкой (включили свет в комнате).
     */
    private fun updateLight(brightness: Double, now: Double) {
        if (!brightness.isFinite()) return
        val smoothed = sceneBrightness?.let { it * 0.9 + brightness * 0.1 } ?: brightness
        sceneBrightness = smoothed

        if (lightMode != LightMode.AUTO || recording != RecordingState.Idle || !isAppActive || isCameraPaused ||
            now - lightChangedAt <= 2
        ) return

        if (!isLightOn) {
            brightSince = null
            if (smoothed < darkLevel) {
                if (darkSince == null) darkSince = now
                val since = darkSince
                if (since != null && now - since > 1.0) {
                    // Если только что выключили, а снова темно — выключать в следующий раз осторожнее.
                    if (now - lastAutoOffAt < 6) offMargin = min(4.0, offMargin + 1)
                    setLight(true)
                }
            } else {
                darkSince = null
            }
        } else {
            darkSince = null
            val withLight = brightnessWithLight
            if (withLight == null) {
                brightnessWithLight = smoothed
                return
            }
            val offLevel = max(darkLevel + 2.5, withLight + offMargin)
            if (smoothed > offLevel) {
                if (brightSince == null) brightSince = now
                val since = brightSince
                if (since != null && now - since > 1.5) {
                    lastAutoOffAt = now
                    setLight(false)
                }
            } else {
                brightSince = null
            }
        }
    }

    private fun setLight(on: Boolean) {
        lightChangedAt = now()
        brightnessWithLight = null
        darkSince = null
        brightSince = null

        if (on) {
            if (!isFront && camera.hasTorch) {
                camera.setTorch(true)
                isScreenLightOn = false
            } else {
                isScreenLightOn = true   // у фронтальной камеры фонарика нет — светим экраном
            }
        } else {
            camera.setTorch(false)
            isScreenLightOn = false
        }
        if (isLightOn != on) isLightOn = on
    }

    // MARK: Обучение новому жесту

    /**
     * Запись нового жеста. [multiAngle] — записать сразу с трёх ракурсов (прямо, левее, правее):
     * так жест потом лучше узнаётся, когда его показывают под углом.
     */
    fun startRecording(word: String, dynamic: Boolean, multiAngle: Boolean = true) {
        val cleaned = word.trim().lowercase()
        if (cleaned.isEmpty() || recording != RecordingState.Idle) return
        recordingWord = cleaned
        recordingDynamic = dynamic
        if (mode != AppMode.TRANSLATE) changeMode(AppMode.TRANSLATE)

        pendingPrompts.clear()
        if (multiAngle) {
            pendingPrompts += listOf(
                "Прямо к камере",
                "Чуть поверните руку влево (или сместите телефон)",
                "Чуть поверните руку вправо (или сместите телефон)",
            )
        } else {
            pendingPrompts += "Прямо к камере"
        }
        recordingSteps = pendingPrompts.size
        recordingStep = 0
        similarWord = null
        recordingTooStill = false
        startNextAngle()
    }

    private fun startNextAngle() {
        if (pendingPrompts.isEmpty()) return
        recordingPrompt = pendingPrompts.removeAt(0)
        recordingStep += 1
        recordedFrames.clear()
        recordedMainFrames.clear()
        recordedSpeeds.clear()
        val countdown = if (recordingStep == 1) 3 else 2

        viewModelScope.launch {
            for (n in countdown downTo 1) {
                recording = RecordingState.Countdown(n)
                delay(1000)
            }
            recordingStart = now()
            recording = RecordingState.Recording(0f)
        }
    }

    private fun finishRecording() {
        recording = RecordingState.Idle
        resetRecognition()

        val timed: List<Timed<SignFrame>>
        if (recordingDynamic) {
            // Жест двумя руками — если вторая рука видна почти всё время и тоже движется.
            // Иначе вторая рука просто оказалась в кадре: записываем только ведущую руку.
            val withOther = recordedSpeeds.mapNotNull { it.second }
            val mainSpeed = recordedSpeeds.sumOf { it.first } / max(1, recordedSpeeds.size)
            val otherSpeed = withOther.sum() / max(1, withOther.size)
            val twoHanded = withOther.size >= 0.6 * max(1, recordedSpeeds.size) && otherSpeed >= 0.4 * mainSpeed
            timed = if (twoHanded) {
                recordedFrames.filter { it.item.handCount == 2 }
            } else {
                recordedMainFrames.filter { it.item.handCount == 1 }
            }
        } else {
            // Поза: кадры с тем числом рук, которое было видно чаще всего.
            val count = recordedFrames.groupBy { it.item.handCount }.maxByOrNull { it.value.size }?.key ?: 1
            timed = recordedFrames.filter { it.item.handCount == count }
        }
        val handCount = timed.firstOrNull()?.item?.handCount ?: 1
        val frames = timed.map { it.item }
        recordedFrames.clear()
        recordedMainFrames.clear()
        recordedSpeeds.clear()
        // Похожее слово проверяем по первой записи («прямо к камере»), до того как она попадёт в словарь.
        val isFirstStep = recordingStep == 1

        var saved = false
        if (recordingDynamic) {
            val template = SignMatching.prepareTemplate(timed)
            if (frames.size >= 15 && template.size >= 5) {
                if (isFirstStep) {
                    similarWord = library.similarMotion(template, recordingWord)?.word
                    recordingTooStill = SignMatching.isMostlyStill(template)
                }
                library.addMotion(recordingWord, template)
                saved = true
            }
        } else if (frames.size >= 8) {
            if (isFirstStep) {
                similarWord = library.similarPose(frames, recordingWord)?.word
            }
            library.addPoses(recordingWord, frames)
            saved = true
        }

        if (!saved) {
            pendingPrompts.clear()
            showNotice("Не получилось: руки не были видны целиком. Попробуйте ещё раз.")
            haptic(Haptic.ERROR)
            return
        }
        if (pendingPrompts.isEmpty()) {
            savedNotice(handCount)
        } else {
            haptic(Haptic.LIGHT)
            startNextAngle()
        }
    }

    private fun savedNotice(handCount: Int) {
        val hands = if (handCount == 2) "двумя руками" else "одной рукой"
        var text = "Жест «$recordingWord» $hands сохранён"
        val similar = similarWord
        if (similar != null) {
            text += "\nОн похож на «$similar» — их можно перепутать. Лучше показать жест иначе."
        }
        if (recordingTooStill) {
            text += "\nДвижения почти не было: для такого жеста лучше подходит тип «Поза»."
        }
        val warning = similar != null || recordingTooStill
        showNotice(text, if (warning) 5.0 else 3.0)
        haptic(if (similar == null) Haptic.SUCCESS else Haptic.WARNING)
    }

    private fun showNotice(text: String, duration: Double = 3.0) {
        notice = text
        noticeJob?.cancel()
        noticeJob = viewModelScope.launch {
            delay((duration * 1000).toLong())
            if (notice == text) notice = null
        }
    }

    // MARK: Перевод жестов в текст и речь

    private fun translate(sign: Sign) {
        val word = sign.word ?: return
        phraseWords = phraseWords + word
        lastWord = word
        if (isSpeechEnabled) speaker.speak(word)
        haptic(Haptic.MEDIUM)
    }

    fun deleteLastWord() {
        if (phraseWords.isEmpty()) return
        phraseWords = phraseWords.dropLast(1)
        lastWord = phraseWords.lastOrNull()
        haptic(Haptic.LIGHT)
    }

    fun finishPhrase() {
        if (phraseWords.isEmpty()) return
        phraseHistory = (listOf("$phraseText.") + phraseHistory).take(3)
        phraseWords = emptyList()
        haptic(Haptic.MEDIUM)
    }

    fun clearTranslation() {
        phraseWords = emptyList()
        phraseHistory = emptyList()
        lastWord = null
        speaker.stop()
    }

    fun speakPhrase() {
        val text = if (phraseWords.isEmpty()) phraseHistory.firstOrNull() ?: "" else phraseText
        if (text.isNotEmpty()) speaker.speak(text)
    }

    // MARK: Выполнение команд (режим «Управление»)

    private fun execute(command: Command, gesture: Gesture) {
        when (command) {
            Command.CONFIRM -> {
                val selected = selectedIndex
                confirmation = if (selected != null) "Подтверждён выбор: ${screens[selected].title}" else "Подтверждено"
            }
            Command.PAUSE -> isPlaying = !isPlaying
            Command.SELECT -> selectedIndex = screenIndex
            Command.NEXT_SCREEN -> screenIndex = (screenIndex + 1) % screens.size
            Command.PREVIOUS_SCREEN -> screenIndex = (screenIndex - 1 + screens.size) % screens.size
            Command.INCREASE -> volume = min(100, volume + 10)
            Command.DECREASE -> volume = max(0, volume - 10)
        }

        lastGesture = gesture
        lastCommand = command

        val time = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        log = (listOf("$time  ${gesture.emoji} ${command.title}") + log).take(3)

        haptic(Haptic.MEDIUM)
    }

    companion object {
        fun sentence(words: List<String>): String =
            words.joinToString(" ").replaceFirstChar { it.uppercase() }
    }
}
