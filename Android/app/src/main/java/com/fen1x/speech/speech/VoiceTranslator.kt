package com.fen1x.speech.speech

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.fen1x.speech.core.SpeechCorrector

/**
 * Фраза распознанной речи. Новая фраза начинается после паузы в разговоре —
 * так реплики разных людей оказываются на разных строках.
 */
data class SpokenPhrase(
    val id: Int,
    val text: String,
    /** Фраза закончена (человек замолчал), текст больше не изменится. */
    val isFinal: Boolean,
    val time: Long,
)

/**
 * Голосовой перевод: живая расшифровка речи в текст (распознавание речи Android / Google, русский язык).
 *
 * • Слушает непрерывно, пока открыта страница. Распознавание Android заканчивает запрос,
 *   когда человек замолчал, — это и есть конец фразы: следующий запрос начинается сразу,
 *   а реплики разных людей оказываются на разных строках.
 * • Нет связи с сервером — распознавание переходит на телефон (Android 12+, если телефон умеет).
 * • Приложение свернули — прослушивание на паузе, вернулись — продолжается само.
 * • Текст исправляется [SpeechCorrector]: запинки, повторы, звуки-паузы, слова из словаря.
 */
class VoiceTranslator(private val context: Context) {
    val phrases = mutableStateListOf<SpokenPhrase>()
    var isListening by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    /** Пояснение под кнопками: распознавание без интернета, микрофон занят. */
    var notice by mutableStateOf<String?>(null)
        private set
    /** Громкость для индикатора, 0…1. */
    var level by mutableFloatStateOf(0f)
        private set

    private val prefs = context.getSharedPreferences("speech", Context.MODE_PRIVATE)

    /** Размер текста на экране, sp. */
    var fontSize by mutableFloatStateOf(prefs.getFloat(KEY_FONT, 30f))
        private set
    /** Пауза, после которой начинается новая строка, секунд (если телефон это поддерживает). */
    var splitPause by mutableFloatStateOf(prefs.getFloat(KEY_PAUSE, 1.2f))
        private set
    /** Распознавать только на телефоне, без отправки звука на серверы. */
    var onDeviceOnly by mutableStateOf(prefs.getBoolean(KEY_ON_DEVICE, false))
        private set
    /** Приглушать звуковой сигнал, который Android подаёт при каждом начале распознавания. */
    var muteBeep by mutableStateOf(prefs.getBoolean(KEY_MUTE, true))
        private set
    /** Слова, которые должны распознаваться точно: имена, названия, термины. */
    var customWords by mutableStateOf(
        prefs.getString(KEY_WORDS, "").orEmpty().split('\n').filter { it.isNotBlank() },
    )
        private set

    /** Телефон умеет распознавать речь без интернета (Android 12+). */
    val supportsOnDevice: Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    private val corrector = SpeechCorrector()
    private var dictionaryWords: List<String> = emptyList()
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var recognizerOnDevice = false
    private var generation = 0
    private var pausedInBackground = false
    private val failures = ArrayList<Long>()
    private val lastRaw = HashMap<Int, String>()
    /** Сервер недоступен — до этого момента распознаём на телефоне. */
    private var fallbackUntil = 0L
    private val mutedStreams = ArrayList<Int>()
    private val restart = Runnable { listen() }

    init {
        updateVocabulary()
    }

    // MARK: Настройки

    fun changeFontSize() {
        fontSize = if (fontSize >= 48f) 22f else fontSize + 6f
        prefs.edit().putFloat(KEY_FONT, fontSize).apply()
    }

    fun changeSplitPause(seconds: Float) {
        splitPause = seconds
        prefs.edit().putFloat(KEY_PAUSE, seconds).apply()
    }

    fun changeOnDeviceOnly(on: Boolean) {
        onDeviceOnly = on
        prefs.edit().putBoolean(KEY_ON_DEVICE, on).apply()
        if (isListening && !pausedInBackground) {
            recognizer?.cancel()
            scheduleRestart(200)
        }
    }

    fun changeMuteBeep(on: Boolean) {
        muteBeep = on
        prefs.edit().putBoolean(KEY_MUTE, on).apply()
        updateMute()
    }

    fun addWord(word: String) {
        val cleaned = word.trim()
        if (cleaned.isEmpty() || customWords.any { it.equals(cleaned, ignoreCase = true) }) return
        saveWords(customWords + cleaned)
    }

    fun removeWord(word: String) {
        saveWords(customWords.filter { it != word })
    }

    private fun saveWords(words: List<String>) {
        customWords = words
        prefs.edit().putString(KEY_WORDS, words.joinToString("\n")).apply()
        updateVocabulary()
    }

    /** Слова из словаря жестов тоже должны распознаваться точно. */
    fun setDictionaryWords(words: List<String>) {
        dictionaryWords = words
        updateVocabulary()
    }

    private val vocabulary: List<String>
        get() {
            val seen = HashSet<String>()
            return (customWords + dictionaryWords).filter { seen.add(it.lowercase()) }
        }

    private fun updateVocabulary() {
        corrector.vocabulary = vocabulary
    }

    // MARK: Запуск и остановка

    /** Начать слушать (разрешение на микрофон уже есть). */
    fun start() {
        if (isListening) return
        error = null
        if (!SpeechRecognizer.isRecognitionAvailable(context) && !supportsOnDevice) {
            error = "На телефоне нет службы распознавания речи. Установите или обновите приложение Google."
            return
        }
        isListening = true
        pausedInBackground = false
        failures.clear()
        updateMute()
        listen()
    }

    fun permissionDenied() {
        error = "Нет доступа к микрофону. Разрешите его: Настройки → Приложения → speech → Разрешения → Микрофон."
    }

    fun stop() {
        main.removeCallbacks(restart)
        isListening = false
        pausedInBackground = false
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        finalizeAll()
        level = 0f
        notice = null
        updateMute()
    }

    fun clear() {
        phrases.clear()
        lastRaw.clear()
    }

    /** Приложение свернули: микрофон освобождается, текущая фраза остаётся. */
    fun onBackground() {
        if (!isListening) return
        pausedInBackground = true
        main.removeCallbacks(restart)
        recognizer?.cancel()
        finalizeAll()
        level = 0f
        updateMute()
    }

    /** Вернулись в приложение — прослушивание продолжается само. */
    fun onForeground() {
        if (!isListening || !pausedInBackground) return
        pausedInBackground = false
        updateMute()
        listen()
    }

    // MARK: Распознавание

    /** Новый запрос распознавания — новая фраза. */
    private fun listen() {
        main.removeCallbacks(restart)
        if (!isListening || pausedInBackground) return
        val now = SystemClock.elapsedRealtime()
        val onDevice = supportsOnDevice && (onDeviceOnly || now < fallbackUntil)
        var current = recognizer
        if (current == null || recognizerOnDevice != onDevice) {
            current?.destroy()
            current = createRecognizer(onDevice)
            recognizer = current
            recognizerOnDevice = onDevice
        }
        generation += 1
        notice = if (onDevice && !onDeviceOnly) "Нет связи с сервером — распознаю на телефоне" else null
        try {
            current.startListening(intent(onDevice))
        } catch (e: RuntimeException) {
            scheduleRestart(500)
        }
    }

    private fun createRecognizer(onDevice: Boolean): SpeechRecognizer {
        val recognizer = if (onDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }
        recognizer.setRecognitionListener(listener)
        return recognizer
    }

    private fun intent(onDevice: Boolean): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ru-RU")
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        if (onDevice) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        // Сколько тишины считать концом фразы. Учитывается не всеми телефонами.
        val pause = (splitPause * 1000).toLong()
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, pause)
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, pause)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Знаки препинания и «Мои слова» (если служба распознавания это умеет).
            putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
            val words = vocabulary.take(100)
            if (words.isNotEmpty()) putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(words))
        }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (notice?.startsWith("Микрофон занят") == true) notice = null
        }

        override fun onBeginningOfSpeech() {}

        override fun onRmsChanged(rmsdB: Float) {
            level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {}

        override fun onError(error: Int) {
            handleError(error)
        }

        override fun onResults(results: Bundle?) {
            handleText(results, generation, isFinal = true)
            scheduleRestart(50)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            handleText(partialResults, generation, isFinal = false)
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun handleText(bundle: Bundle?, id: Int, isFinal: Boolean) {
        val stable = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
        // Google присылает ещё не устоявшееся окончание фразы отдельно.
        val unstable = bundle?.getStringArrayList(UNSTABLE_TEXT)?.firstOrNull().orEmpty()
        val text = listOf(stable, unstable).filter { it.isNotBlank() }.joinToString(" ").trim()

        val index = phrases.indexOfLast { it.id == id }
        // Запоздавший промежуточный результат уже закрытой фразы.
        if (index >= 0 && phrases[index].isFinal && !isFinal) return

        if (text.isNotEmpty() && lastRaw[id] != text) {
            lastRaw[id] = text
            val corrected = corrector.correct(text)
            if (index >= 0) {
                if (corrected.isEmpty()) {
                    phrases.removeAt(index)
                } else if (phrases[index].text != corrected) {
                    phrases[index] = phrases[index].copy(text = corrected)
                }
            } else if (corrected.isNotEmpty()) {
                phrases.add(SpokenPhrase(id, corrected, false, System.currentTimeMillis()))
                while (phrases.size > MAX_PHRASES) phrases.removeAt(0)
            }
        }
        if (isFinal) finalize(id)
    }

    private fun finalize(id: Int) {
        lastRaw.remove(id)
        val index = phrases.indexOfLast { it.id == id }
        if (index >= 0 && !phrases[index].isFinal) phrases[index] = phrases[index].copy(isFinal = true)
    }

    private fun finalizeAll() {
        for (i in phrases.indices) {
            if (!phrases[i].isFinal) phrases[i] = phrases[i].copy(isFinal = true)
        }
        lastRaw.clear()
    }

    private fun handleError(code: Int) {
        finalize(generation)
        level = 0f
        if (!isListening || pausedInBackground) return
        when (code) {
            // Тишина или неразборчиво — это не ошибки, слушаем дальше.
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> scheduleRestart(50)
            SpeechRecognizer.ERROR_CLIENT -> scheduleRestart(300)
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> {
                recognizer?.destroy()
                recognizer = null
                scheduleRestart(500)
            }
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                stop()
                permissionDenied()
            }
            SpeechRecognizer.ERROR_AUDIO -> {
                // Микрофон занят: звонок, запись в другом приложении.
                notice = "Микрофон занят (звонок или другое приложение). Продолжу автоматически."
                scheduleRestart(2000)
            }
            ERROR_LANGUAGE_NOT_SUPPORTED, ERROR_LANGUAGE_UNAVAILABLE -> {
                if (recognizerOnDevice && !onDeviceOnly) {
                    // На телефоне нет русского языка — возвращаемся к серверу.
                    fallbackUntil = 0L
                    scheduleRestart(300)
                } else {
                    stop()
                    error = "Русский язык для распознавания недоступен. Загрузите его: Настройки → Система → " +
                        "Языки → Распознавание речи (или в приложении Google), либо выключите «Только на телефоне»."
                }
            }
            else -> registerFailure(code)
        }
    }

    private fun registerFailure(code: Int) {
        val now = SystemClock.elapsedRealtime()
        failures.removeAll { now - it > 10_000 }
        failures.add(now)
        val network = code == SpeechRecognizer.ERROR_NETWORK || code == SpeechRecognizer.ERROR_NETWORK_TIMEOUT ||
            code == ERROR_SERVER_DISCONNECTED
        if (network && supportsOnDevice && !onDeviceOnly && now >= fallbackUntil) {
            // Пропал интернет — полминуты распознаём на телефоне, потом снова пробуем сервер.
            fallbackUntil = now + 30_000
            failures.clear()
            scheduleRestart(300)
            return
        }
        if (failures.size >= 5) {
            stop()
            error = "Распознавание речи прерывается. Проверьте интернет" +
                (if (supportsOnDevice && !onDeviceOnly) " или включите «Только на телефоне»." else ".") +
                " (код: $code)"
            return
        }
        scheduleRestart(1000)
    }

    private fun scheduleRestart(delayMs: Long) {
        main.removeCallbacks(restart)
        if (isListening && !pausedInBackground) main.postDelayed(restart, delayMs)
    }

    /**
     * Android подаёт звуковой сигнал при каждом начале распознавания — при непрерывном
     * прослушивании он звучал бы после каждой фразы. Пока страница слушает, звук сигналов приглушён.
     */
    private fun updateMute() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val shouldMute = muteBeep && isListening && !pausedInBackground
        if (shouldMute && mutedStreams.isEmpty()) {
            for (stream in BEEP_STREAMS) {
                try {
                    if (!audio.isStreamMute(stream)) {
                        audio.adjustStreamVolume(stream, AudioManager.ADJUST_MUTE, 0)
                        mutedStreams.add(stream)
                    }
                } catch (e: SecurityException) {
                    // Режим «Не беспокоить» не даёт менять этот звук — пропускаем.
                }
            }
        } else if (!shouldMute && mutedStreams.isNotEmpty()) {
            for (stream in mutedStreams) {
                try {
                    audio.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, 0)
                } catch (e: SecurityException) {
                }
            }
            mutedStreams.clear()
        }
    }

    private companion object {
        const val MAX_PHRASES = 400
        const val UNSTABLE_TEXT = "android.speech.extra.UNSTABLE_TEXT"
        // Коды ошибок Android 12+ (числа, чтобы работало и на старых версиях).
        const val ERROR_SERVER_DISCONNECTED = 11
        const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        const val ERROR_LANGUAGE_UNAVAILABLE = 13
        val BEEP_STREAMS = intArrayOf(AudioManager.STREAM_MUSIC, AudioManager.STREAM_SYSTEM, AudioManager.STREAM_NOTIFICATION)

        const val KEY_FONT = "fontSize"
        const val KEY_PAUSE = "splitPause"
        const val KEY_ON_DEVICE = "onDeviceOnly"
        const val KEY_MUTE = "muteBeep"
        const val KEY_WORDS = "customWords"
    }
}
