package com.fen1x.speech.speech

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import com.fen1x.speech.core.SpeechEnhancer
import java.io.IOException

/**
 * Звук для распознавания с усилением тихой и дальней речи (Android 13+).
 *
 * Микрофон записывает само приложение, звук проходит через [SpeechEnhancer] (фильтр гула,
 * автоматическая громкость, ограничитель) и по каналу (pipe) уходит службе распознавания
 * (`RecognizerIntent.EXTRA_AUDIO_SOURCE`). Между фразами звук не теряется: последняя
 * секунда хранится и сразу уходит в следующий запрос.
 *
 * Запись идёт в своём потоке; канал неблокирующий, поэтому поток никогда не зависает,
 * даже если служба перестала читать звук.
 */
class AudioPump {
    private val enhancer = SpeechEnhancer()
    private val lock = Any()
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    private var output: ParcelFileDescriptor? = null
    private val preroll = ArrayDeque<ByteArray>()
    private var prerollBytes = 0

    /** Громкость для индикатора, 0…1 (с усилением). */
    @Volatile var meterLevel = 0f
        private set
    /** Сейчас слышен голос. */
    @Volatile var hearsVoice = false
        private set
    /** Сколько секунд голоса ушло в текущий запрос — чтобы проверить, что служба его слышит. */
    @Volatile var sessionVoiceSeconds = 0.0
        private set
    /** Запись прервалась (микрофон отобрали) — нужен обычный режим. */
    @Volatile var failed = false
        private set

    val isRunning: Boolean get() = running

    /** Включить микрофон. false — не получилось (микрофон занят или недоступен). */
    @SuppressLint("MissingPermission")   // разрешение проверяется до открытия страницы
    fun start(): Boolean {
        if (running) return true
        failed = false
        val minSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minSize <= 0) return false
        val created = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minSize, FRAME * 2 * 8),
            )
        } catch (e: RuntimeException) {
            return false
        }
        if (created.state != AudioRecord.STATE_INITIALIZED) {
            created.release()
            return false
        }
        try {
            created.startRecording()
        } catch (e: IllegalStateException) {
            created.release()
            return false
        }
        if (created.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            created.release()
            return false
        }
        enhancer.reset()
        record = created
        running = true
        thread = Thread({ loop(created) }, "speech-audio").also {
            it.priority = Thread.MAX_PRIORITY
            it.start()
        }
        return true
    }

    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        record?.let {
            try {
                it.stop()
            } catch (e: IllegalStateException) {
            }
            it.release()
        }
        record = null
        synchronized(lock) {
            closeOutput()
            preroll.clear()
            prerollBytes = 0
        }
        meterLevel = 0f
        hearsVoice = false
    }

    /**
     * Канал для нового запроса распознавания: его нужно передать службе и закрыть,
     * когда запрос закончится. Запас звука (последняя секунда) сразу уходит в него.
     */
    fun openSession(): ParcelFileDescriptor? {
        val pipe = try {
            ParcelFileDescriptor.createPipe()
        } catch (e: IOException) {
            return null
        }
        try {
            // Неблокирующая запись: если служба не читает, звук просто пропускается.
            val flags = Os.fcntlInt(pipe[1].fileDescriptor, OsConstants.F_GETFL, 0)
            Os.fcntlInt(pipe[1].fileDescriptor, OsConstants.F_SETFL, flags or OsConstants.O_NONBLOCK)
        } catch (e: ErrnoException) {
            pipe[0].close()
            pipe[1].close()
            return null
        }
        synchronized(lock) {
            closeOutput()
            output = pipe[1]
            sessionVoiceSeconds = 0.0
            for (chunk in preroll) write(chunk, chunk.size)
            preroll.clear()
            prerollBytes = 0
        }
        return pipe[0]
    }

    /** Запрос закончился: звук снова копится в запас до следующего запроса. */
    fun closeSession() {
        synchronized(lock) { closeOutput() }
    }

    private fun closeOutput() {
        try {
            output?.close()
        } catch (e: IOException) {
        }
        output = null
    }

    private fun loop(record: AudioRecord) {
        val shorts = ShortArray(FRAME)
        val floats = FloatArray(FRAME)
        while (running) {
            val count = record.read(shorts, 0, FRAME)
            if (count < 0) {
                // Микрофон отобрали (звонок) или он отключился.
                failed = true
                break
            }
            if (count == 0) continue
            for (i in 0 until count) floats[i] = shorts[i] / 32768f
            enhancer.process(floats, count, SAMPLE_RATE)
            val bytes = ByteArray(count * 2)
            for (i in 0 until count) {
                val v = (floats[i] * 32767f).toInt().coerceIn(-32768, 32767)
                bytes[2 * i] = (v and 0xFF).toByte()
                bytes[2 * i + 1] = ((v shr 8) and 0xFF).toByte()
            }
            meterLevel = enhancer.meterLevel
            hearsVoice = enhancer.hearsVoice
            synchronized(lock) {
                if (output != null) {
                    if (hearsVoice) sessionVoiceSeconds += count.toDouble() / SAMPLE_RATE
                    write(bytes, bytes.size)
                } else {
                    preroll.addLast(bytes)
                    prerollBytes += bytes.size
                    while (prerollBytes > PREROLL_BYTES) prerollBytes -= preroll.removeFirst().size
                }
            }
        }
        running = false
        meterLevel = 0f
        hearsVoice = false
    }

    /** Пишет в канал (под блокировкой). Канал закрыт службой — запрос закончен. */
    private fun write(bytes: ByteArray, size: Int) {
        val fd = output ?: return
        var offset = 0
        try {
            while (offset < size) {
                val written = Os.write(fd.fileDescriptor, bytes, offset, size - offset)
                if (written <= 0) break
                offset += written
            }
        } catch (e: ErrnoException) {
            // EAGAIN — служба не успевает читать (пропускаем кусок); EPIPE — служба закрыла канал.
            if (e.errno != OsConstants.EAGAIN) closeOutput()
        } catch (e: java.io.InterruptedIOException) {
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        /** 20 мс звука. */
        const val FRAME = 320
        /** 1 секунда звука в запасе. */
        const val PREROLL_BYTES = SAMPLE_RATE * 2
    }
}
