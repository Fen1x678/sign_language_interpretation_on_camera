package com.fen1x.speech.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Усиление тихой и дальней речи — то же, что в версии для iPhone.
 *
 * Голос человека в 10 метрах доходит до микрофона примерно на 20 дБ тише, чем с 1 метра,
 * а низкий гул (вентиляция, транспорт) при этом почти не ослабевает. Поэтому:
 * 1. фильтр высоких частот убирает гул ниже ~100 Гц (в нём нет речи);
 * 2. автоматическая регулировка громкости поднимает тихую речь до обычной громкости
 *    (до +24 дБ), но фоновый шум не поднимает громче −38 дБ, а громкую речь вблизи не трогает;
 * 3. ограничитель не даёт звуку «захрипеть», если кто-то заговорит громко.
 *
 * Заодно считает громкость для индикатора и замечает голос (звук заметно громче фонового шума).
 * Звук — числа от −1 до 1, обрабатывается на месте, кусками по 10–100 мс.
 */
class SpeechEnhancer {
    /** Текущее усиление, дБ. */
    var gain = 0f
        private set
    /** Громкость звука после фильтра гула (до усиления), сглаженная, дБ. */
    var level = -100f
        private set
    /** Фоновый шум, дБ. */
    var noise = -90f
        private set
    /** Сейчас слышен голос. */
    val hearsVoice: Boolean
        get() = lastVoice >= 0 && time - lastVoice < VOICE_HOLD
    /** Для индикатора: 0…1, громкость с усилением (так, как её слышит распознавание) от −65 до −15 дБ. */
    val meterLevel: Float
        get() = ((level + gain + 65f) / 50f).coerceIn(0f, 1f)

    private var speechLevel = -40f
    private var time = 0.0
    private var lastVoice = -1.0
    private var loudTime = 0.0
    private var hasLevel = false
    private var blockMinimum = Float.MAX_VALUE
    private var blockStart = 0.0
    private val minima = ArrayDeque<Float>()

    private var sampleRate = 0
    private var b0 = 1f
    private var b1 = 0f
    private var b2 = 0f
    private var a1 = 0f
    private var a2 = 0f
    private var x1 = 0f
    private var x2 = 0f
    private var y1 = 0f
    private var y2 = 0f

    fun reset() {
        gain = 0f
        level = -100f
        noise = -90f
        speechLevel = -40f
        time = 0.0
        lastVoice = -1.0
        loudTime = 0.0
        hasLevel = false
        blockMinimum = Float.MAX_VALUE
        blockStart = 0.0
        minima.clear()
        sampleRate = 0
        x1 = 0f; x2 = 0f; y1 = 0f; y2 = 0f
    }

    /** Обрабатывает [count] первых чисел [samples] (один канал) на месте. */
    fun process(samples: FloatArray, count: Int = samples.size, rate: Int) {
        if (count <= 0 || rate <= 0) return
        if (rate != sampleRate) configure(rate)
        val seconds = count.toDouble() / rate
        time += seconds

        // 1. Фильтр высоких частот (биквад Баттерворта 2-го порядка).
        var sum = 0.0
        for (i in 0 until count) {
            val x = samples[i]
            val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            samples[i] = y
            sum += (y * y).toDouble()
        }
        val decibels = (20 * log10(max(sqrt(sum / count), 1e-7))).toFloat()
        analyze(decibels, seconds)

        // 2. Громкость речи: быстро растёт на словах, медленно (6 дБ/с) спадает в паузах.
        speechLevel = if (decibels > speechLevel) {
            speechLevel + (decibels - speechLevel) * 0.5f
        } else {
            max(speechLevel - (6 * seconds).toFloat(), noise + 6f)
        }
        val desired = max(0f, min(min(MAX_GAIN, TARGET - speechLevel), NOISE_CEILING - noise))
        // Усиление уменьшается сразу (чтобы не было перегрузки), а растёт плавно — 3 дБ/с.
        gain = if (desired < gain) desired else min(desired, gain + (3 * seconds).toFloat())

        // 3. Усиление и ограничитель.
        if (gain > 0.1f) {
            val factor = 10f.pow(gain / 20f)
            for (i in 0 until count) samples[i] = (samples[i] * factor).coerceIn(-LIMIT, LIMIT)
        } else {
            for (i in 0 until count) samples[i] = samples[i].coerceIn(-LIMIT, LIMIT)
        }
    }

    /** Громкость, фоновый шум и голос — так же, как на iPhone. */
    private fun analyze(decibels: Float, seconds: Double) {
        if (hasLevel) {
            // Сглаживание ~0,1 с независимо от размера куска.
            level += (decibels - level) * (1 - exp(-seconds / 0.1)).toFloat()
        } else {
            level = decibels
            hasLevel = true
            blockStart = time
        }
        // Фоновый шум — минимум громкости за 16 отрезков по 0,25 с (4 с): в речи всегда есть
        // короткие паузы между словами, поэтому речь не принимается за шум.
        blockMinimum = min(blockMinimum, level)
        if (time - blockStart >= NOISE_BLOCK) {
            minima.addLast(blockMinimum)
            if (minima.size > NOISE_BLOCKS) minima.removeFirst()
            noise = max(minima.min(), -90f)
            blockMinimum = Float.MAX_VALUE
            blockStart = time
        }
        // Голос: громче шума на 5 дБ не меньше 60 мс подряд (человек в 10 метрах громче шума ненамного).
        loudTime = if (minima.isNotEmpty() && level > noise + VOICE_MARGIN) loudTime + seconds else 0.0
        if (loudTime >= VOICE_DURATION) lastVoice = time
    }

    private fun configure(rate: Int) {
        sampleRate = rate
        val w0 = 2 * PI * CUTOFF / rate
        val alpha = sin(w0) / (2 * 0.7071)
        val cosw = cos(w0)
        val a0 = 1 + alpha
        b0 = ((1 + cosw) / 2 / a0).toFloat()
        b1 = (-(1 + cosw) / a0).toFloat()
        b2 = ((1 + cosw) / 2 / a0).toFloat()
        a1 = (-2 * cosw / a0).toFloat()
        a2 = ((1 - alpha) / a0).toFloat()
        x1 = 0f; x2 = 0f; y1 = 0f; y2 = 0f
    }

    companion object {
        /** Желаемая громкость речи, дБ. */
        const val TARGET = -20f
        /** Наибольшее усиление, дБ (в 16 раз). */
        const val MAX_GAIN = 24f
        /** Фоновый шум не поднимаем громче этого, дБ. */
        const val NOISE_CEILING = -38f
        /** Частота среза фильтра гула, Гц. */
        const val CUTOFF = 100.0
        const val LIMIT = 0.98f
        const val VOICE_MARGIN = 5f
        const val VOICE_DURATION = 0.06
        const val VOICE_HOLD = 0.3
        const val NOISE_BLOCK = 0.25
        const val NOISE_BLOCKS = 16
    }
}
