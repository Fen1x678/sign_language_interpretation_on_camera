package com.fen1x.speech.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/** Усиление тихой и дальней речи: тихий голос громче, шум и гул — нет. */
class SpeechEnhancerTest {
    private val rate = 16_000
    private val frame = 320   // 20 мс

    /**
     * «Речь»: тон 300 Гц со слогами (0,4 с звук, 0,15 с пауза) громкостью [speechDb]
     * и белый шум громкостью [noiseDb]. Возвращает громкость результата: в слогах и в паузах.
     */
    private fun run(
        enhancer: SpeechEnhancer,
        seconds: Double,
        speechDb: Float?,
        noiseDb: Float,
        humDb: Float? = null,
        seed: Int = 1,
    ): Pair<Float, Float> {
        val random = Random(seed)
        val speechAmp = speechDb?.let { sqrt(2f) * 10f.pow(it / 20f) } ?: 0f
        val noiseAmp = sqrt(3f) * 10f.pow(noiseDb / 20f)
        val humAmp = humDb?.let { sqrt(2f) * 10f.pow(it / 20f) } ?: 0f
        var n = 0
        var speechSum = 0.0
        var speechCount = 0
        var pauseSum = 0.0
        var pauseCount = 0
        val total = (seconds * rate).toInt()
        val buffer = FloatArray(frame)
        while (n < total) {
            val t0 = n.toDouble() / rate
            val syllable = (t0 % 0.55) < 0.4
            for (i in 0 until frame) {
                val t = (n + i).toDouble() / rate
                var x = noiseAmp * (random.nextFloat() * 2 - 1)
                if (syllable) x += speechAmp * sin(2 * PI * 300 * t).toFloat()
                x += humAmp * sin(2 * PI * 50 * t).toFloat()
                buffer[i] = x
            }
            enhancer.process(buffer, frame, rate)
            // Последние 2 секунды — когда усиление уже установилось.
            if (t0 >= seconds - 2) {
                val energy = buffer.sumOf { (it * it).toDouble() }
                if (syllable) { speechSum += energy; speechCount += frame } else { pauseSum += energy; pauseCount += frame }
            }
            n += frame
        }
        fun db(sum: Double, count: Int) = (20 * log10(max(sqrt(sum / max(count, 1)), 1e-7))).toFloat()
        return db(speechSum, speechCount) to db(pauseSum, pauseCount)
    }

    @Test
    fun quietDistantSpeechIsBoosted() {
        val enhancer = SpeechEnhancer()
        // Человек в 10 метрах: речь около −44 дБ, тихая комната — шум −68 дБ.
        val (speech, _) = run(enhancer, 12.0, speechDb = -44f, noiseDb = -68f)
        assertTrue("gain=${enhancer.gain}", enhancer.gain >= 15f)
        assertTrue("speech=$speech", speech >= -30f)
        assertTrue(enhancer.hearsVoice || enhancer.meterLevel > 0.5f)
    }

    @Test
    fun loudNearSpeechIsUntouched() {
        val enhancer = SpeechEnhancer()
        run(enhancer, 8.0, speechDb = -16f, noiseDb = -60f)
        assertTrue("gain=${enhancer.gain}", enhancer.gain < 1f)
    }

    @Test
    fun noiseIsNotRaisedAboveCeiling() {
        val enhancer = SpeechEnhancer()
        // Только шум −50 дБ: его можно поднять не больше чем до −38 дБ.
        val (_, pause) = run(enhancer, 10.0, speechDb = null, noiseDb = -50f)
        assertTrue("gain=${enhancer.gain}", enhancer.gain <= 12.5f)
        assertTrue("noise after=$pause", pause <= -36.5f)
        assertFalse(enhancer.hearsVoice)
    }

    @Test
    fun humIsRemoved() {
        val enhancer = SpeechEnhancer()
        // Гул 50 Гц громкостью −20 дБ: фильтр ослабляет его больше чем на 10 дБ, и он не усиливается.
        val (_, pause) = run(enhancer, 6.0, speechDb = null, noiseDb = -80f, humDb = -20f)
        assertTrue("hum after=$pause", pause <= -30f)
    }

    @Test
    fun suddenLoudSoundIsLimited() {
        val enhancer = SpeechEnhancer()
        run(enhancer, 8.0, speechDb = -44f, noiseDb = -68f)
        assertTrue(enhancer.gain > 10f)
        // Вдруг громкий звук на полную шкалу — не выходит за ограничитель, и усиление сразу падает.
        val loud = FloatArray(frame) { 0.99f * sin(2 * PI * 300 * it / rate).toFloat() }
        enhancer.process(loud, frame, rate)
        assertTrue(loud.all { abs(it) <= SpeechEnhancer.LIMIT + 1e-6f })
        repeat(5) {
            val more = FloatArray(frame) { 0.99f * sin(2 * PI * 300 * it / rate).toFloat() }
            enhancer.process(more, frame, rate)
        }
        assertTrue("gain=${enhancer.gain}", enhancer.gain < 1f)
    }
}
