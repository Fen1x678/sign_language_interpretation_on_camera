package com.fen1x.speech.speech

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
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
 * • Дальняя речь (Android 13+): микрофон записывает приложение, тихий голос усиливается
 *   ([AudioPump]) и уходит службе распознавания. Если служба такой звук не принимает —
 *   сама возвращается к обычному микрофону.
 * • Микрофон Bluetooth: наушники с микрофоном можно дать говорящему, который далеко.
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
    /** Усиление тихой и дальней речи (Android 13+). */
    var enhanceDistant by mutableStateOf(prefs.getBoolean(KEY_ENHANCE, true))
        private set
    /** Слушать через наушники Bluetooth с микрофоном. */
    var bluetoothMic by mutableStateOf(prefs.getBoolean(KEY_BLUETOOTH, false))
        private set
    /** Приглушать звуковой сигнал, который Android подаёт при каждом начале распознавания. */
    var muteBeep by mutableStateOf(prefs.getBoolean(KEY_MUTE, true))
        private set
    /** Слова, которые должны распознаваться точно: имена, названия, термины. */
    var customWords by mutableStateOf(
        prefs.getString(KEY_WORDS, "").orEmpty().split('\n').filter { it.isNotBlank() },
    )
        private set

    /** Усиление дальней речи доступно: служба распознавания может получать звук от приложения (Android 13+). */
    val supportsEnhance: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

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

    // Дальняя речь: свой микрофон с усилением.
    private var pump: AudioPump? = null
    private var sessionFd: ParcelFileDescriptor? = null
    private var sessionUsesPump = false
    private var sessionStart = 0L
    private var sessionHasText = false
    private var lastTextChange = 0L
    private var stopRequestedAt = 0L
    /** Служба не принимает звук от приложения — до следующего запуска обычный микрофон. */
    private var enhanceBroken = false
    private var pumpHeardText = false
    private var earlyFailures = 0
    private var silentSessions = 0
    private var bluetoothActive = false
    private var bluetoothMissing = false
    private val ticker = object : Runnable {
        override fun run() {
            tick()
            if (isListening && !pausedInBackground) main.postDelayed(this, TICK_MS)
        }
    }

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

    fun changeEnhanceDistant(on: Boolean) {
        enhanceDistant = on
        prefs.edit().putBoolean(KEY_ENHANCE, on).apply()
        enhanceBroken = false
        earlyFailures = 0
        silentSessions = 0
        restartSession()
    }

    fun changeBluetoothMic(on: Boolean) {
        bluetoothMic = on
        prefs.edit().putBoolean(KEY_BLUETOOTH, on).apply()
        updateBluetooth()
        restartSession()
    }

    /** Начать новый запрос с новыми настройками звука. */
    private fun restartSession() {
        if (!isListening || pausedInBackground) return
        recognizer?.cancel()
        endSession()
        finalize(generation)
        scheduleRestart(200)
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
        enhanceBroken = false
        pumpHeardText = false
        earlyFailures = 0
        silentSessions = 0
        updateMute()
        updateBluetooth()
        listen()
        startTicker()
    }

    fun permissionDenied() {
        error = "Нет доступа к микрофону. Разрешите его: Настройки → Приложения → speech → Разрешения → Микрофон."
    }

    fun stop() {
        main.removeCallbacks(restart)
        main.removeCallbacks(ticker)
        isListening = false
        pausedInBackground = false
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        endSession()
        stopPump()
        finalizeAll()
        level = 0f
        notice = null
        updateMute()
        updateBluetooth()
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
        main.removeCallbacks(ticker)
        recognizer?.cancel()
        endSession()
        stopPump()
        finalizeAll()
        level = 0f
        updateMute()
        updateBluetooth()
    }

    /** Вернулись в приложение — прослушивание продолжается само. */
    fun onForeground() {
        if (!isListening || !pausedInBackground) return
        pausedInBackground = false
        updateMute()
        updateBluetooth()
        listen()
        startTicker()
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
        // Наушники подключили уже после включения — пробуем снова.
        if (bluetoothMic && !bluetoothActive) updateBluetooth()
        endSession()
        val source = openPumpSession()
        sessionFd = source
        sessionUsesPump = source != null
        sessionStart = now
        sessionHasText = false
        lastTextChange = now
        stopRequestedAt = 0L
        notice = when {
            onDevice && !onDeviceOnly -> "Нет связи с сервером — распознаю на телефоне"
            bluetoothMissing -> "Наушники Bluetooth не подключены — слушаю микрофоном телефона"
            enhanceBroken -> "Усиление дальней речи на этом телефоне не работает — слушаю обычным микрофоном"
            else -> null
        }
        try {
            current.startListening(intent(onDevice, source))
        } catch (e: RuntimeException) {
            endSession()
            scheduleRestart(500)
        }
    }

    /**
     * Дальняя речь включена — свой микрофон с усилением, канал для нового запроса.
     * null — обычный микрофон службы распознавания.
     */
    private fun openPumpSession(): ParcelFileDescriptor? {
        if (!supportsEnhance || !enhanceDistant || enhanceBroken) {
            stopPump()
            return null
        }
        val current = pump ?: AudioPump().also { pump = it }
        if (!current.isRunning && !current.start()) {
            // Микрофон сейчас занят — этот запрос через обычный микрофон, следующий попробует снова.
            stopPump()
            return null
        }
        return current.openSession() ?: run {
            stopPump()
            null
        }
    }

    private fun stopPump() {
        pump?.stop()
        pump = null
    }

    /** Запрос закончился: канал звука закрывается, звук снова копится в запас. */
    private fun endSession() {
        pump?.closeSession()
        try {
            sessionFd?.close()
        } catch (e: java.io.IOException) {
        }
        sessionFd = null
    }

    /** Служба не принимает звук от приложения: обычный микрофон до следующего запуска. */
    private fun disableEnhance() {
        enhanceBroken = true
        recognizer?.cancel()
        endSession()
        stopPump()
        finalize(generation)
        scheduleRestart(300)
    }

    private fun startTicker() {
        main.removeCallbacks(ticker)
        main.postDelayed(ticker, TICK_MS)
    }

    /** Каждые 0,1 с: индикатор громкости и конец фразы для звука с усилением. */
    private fun tick() {
        if (!isListening || pausedInBackground || !sessionUsesPump) return
        val current = pump ?: return
        if (current.failed) {
            // Микрофон отобрали (звонок) — следующий запрос попробует снова.
            recognizer?.cancel()
            endSession()
            stopPump()
            finalize(generation)
            notice = "Микрофон занят (звонок или другое приложение). Продолжу автоматически."
            scheduleRestart(2000)
            return
        }
        level = current.meterLevel
        val now = SystemClock.elapsedRealtime()
        if (stopRequestedAt == 0L) {
            // Конец фразы — по паузе в распознанном тексте (как на iPhone), не дольше 30 секунд.
            val textPause = now - lastTextChange
            if ((sessionHasText && textPause >= (splitPause * 1000).toLong()) || now - sessionStart >= MAX_PHRASE_MS) {
                stopRequestedAt = now
                recognizer?.stopListening()
            }
        } else if (now - stopRequestedAt >= STOP_TIMEOUT_MS) {
            // Служба не ответила на «стоп» — начинаем новый запрос сами.
            recognizer?.cancel()
            endSession()
            finalize(generation)
            scheduleRestart(50)
        }
    }

    /** Запрос закончился без текста. Если голос был, а текста нет ни разу — служба не слышит наш звук. */
    private fun checkSilentSession() {
        if (!sessionUsesPump || sessionHasText || pumpHeardText) return
        val voice = pump?.sessionVoiceSeconds ?: 0.0
        if (voice < 1.5) return
        silentSessions += 1
        if (silentSessions >= 3) disableEnhance()
    }

    /**
     * Микрофон Bluetooth: наушники с микрофоном становятся микрофоном для распознавания.
     * Android 12+ — через выбор устройства связи, раньше — через канал SCO.
     */
    private fun updateBluetooth() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val want = bluetoothMic && isListening && !pausedInBackground
        if (want && !bluetoothActive) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val device = audio.availableCommunicationDevices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                }
                bluetoothActive = device != null && try {
                    audio.setCommunicationDevice(device)
                } catch (e: RuntimeException) {
                    false
                }
            } else {
                @Suppress("DEPRECATION")
                bluetoothActive = audio.isBluetoothScoAvailableOffCall && try {
                    audio.startBluetoothSco()
                    audio.isBluetoothScoOn = true
                    true
                } catch (e: RuntimeException) {
                    false
                }
            }
            bluetoothMissing = !bluetoothActive
        } else if (!want) {
            if (bluetoothActive) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    audio.clearCommunicationDevice()
                } else {
                    @Suppress("DEPRECATION")
                    audio.isBluetoothScoOn = false
                    @Suppress("DEPRECATION")
                    audio.stopBluetoothSco()
                }
            }
            bluetoothActive = false
            bluetoothMissing = false
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

    private fun intent(onDevice: Boolean, source: ParcelFileDescriptor?): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
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
            // Звук с усилением дальней речи от приложения вместо микрофона службы.
            if (source != null) {
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, source)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, AudioPump.SAMPLE_RATE)
            }
        }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (notice?.startsWith("Микрофон занят") == true) notice = null
        }

        override fun onBeginningOfSpeech() {}

        override fun onRmsChanged(rmsdB: Float) {
            // Со звуком от приложения индикатор показывает громкость с усилением (см. tick).
            if (!sessionUsesPump) level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {}

        override fun onError(error: Int) {
            handleError(error)
        }

        override fun onResults(results: Bundle?) {
            handleText(results, generation, isFinal = true)
            if (sessionUsesPump) earlyFailures = 0
            checkSilentSession()
            endSession()
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
            if (id == generation) {
                sessionHasText = true
                lastTextChange = SystemClock.elapsedRealtime()
                if (sessionUsesPump) {
                    pumpHeardText = true
                    silentSessions = 0
                }
            }
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
        val usedPump = sessionUsesPump
        val early = SystemClock.elapsedRealtime() - sessionStart < 2000
        endSession()
        if (usedPump && !pumpHeardText) {
            when (code) {
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> checkSilentSession()
                SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, ERROR_SERVER_DISCONNECTED,
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS, SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> Unit
                // Служба сразу отказалась от звука приложения — после трёх раз обычный микрофон.
                else -> if (early) {
                    earlyFailures += 1
                    if (earlyFailures >= 3) {
                        disableEnhance()
                        return
                    }
                }
            }
            if (enhanceBroken) return
        }
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
        const val KEY_ENHANCE = "enhanceDistant"
        const val KEY_BLUETOOTH = "bluetoothMic"
        const val TICK_MS = 100L
        const val MAX_PHRASE_MS = 30_000L
        const val STOP_TIMEOUT_MS = 3_000L
        const val KEY_WORDS = "customWords"
    }
}
