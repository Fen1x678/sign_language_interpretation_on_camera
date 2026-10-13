package com.fen1x.speech.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Ускорения распознавания дают тот же результат, что и прямой расчёт. */
class PerformanceTest {
    /** Кадры жеста с движением, 30 в секунду: рука идёт по направлению [dir], форма [shape]. */
    private fun frames(shape: BooleanArray, dir: Pt, seed: Int, count: Int = 90): List<Timed<FrameFeatures>> {
        val random = Random(seed)
        var previous: Pt? = null
        return (0 until count).map { k ->
            val t = k / 30.0
            val progress = ((t - 0.4) / 1.2).coerceIn(0.0, 1.0).toFloat()
            val wrist = Pt(400f, 500f) + dir * (60f * progress)
            val velocity = previous?.let { (wrist - it) / 60f / (1 / 30f) } ?: Pt.ZERO
            previous = wrist
            val hand = TestHands.hand(shape, wrist = wrist, jitter = 0.03f, random = random)
            Timed(t, FrameFeatures.from(SignFrame.make(listOf(hand), velocity)!!))
        }
    }

    @Test
    fun cachedDtwIsIdenticalOnSlidingStream() {
        val template = SignMatching.resample(frames(TestHands.POINT, Pt(4f, 0f), 1))
        val live = frames(TestHands.POINT, Pt(4f, 1f), 2, count = 150)
        val cache = DistanceCache(template.size)
        val mirroredCache = DistanceCache(template.size)
        var compared = 0
        // Как в приложении: каждый второй кадр камеры — последние 2 секунды, приведённые к 15 кадрам в секунду.
        for (end in 20 until live.size step 2) {
            val window = live.subList(0, end + 1).filter { live[end].time - it.time <= 2.0 }
            val stream = SignMatching.resample(window)
            val mirrored = stream.map { it.mirrored() }
            cache.nextGeneration()
            mirroredCache.nextGeneration()
            for (abandon in listOf(Float.POSITIVE_INFINITY, 0.2f, 0.05f)) {
                val plain = SignMatching.subsequenceDTW(template, stream, abandon)
                val cached = SignMatching.subsequenceDTW(template, stream, abandon, cache)
                assertEquals(plain.cost.toRawBits(), cached.cost.toRawBits())
                assertEquals(plain.start, cached.start)
                val plainMirror = SignMatching.subsequenceDTW(template, mirrored, abandon)
                val cachedMirror = SignMatching.subsequenceDTW(template, mirrored, abandon, mirroredCache)
                assertEquals(plainMirror.cost.toRawBits(), cachedMirror.cost.toRawBits())
                assertEquals(plainMirror.start, cachedMirror.start)
                compared += 1
            }
            // Кадры, ушедшие из потока, забываются: кэш не растёт бесконечно.
            assertTrue("cache=${cache.size}", cache.size <= 240 + stream.size)
        }
        assertTrue(compared > 100)
    }

    @Test
    fun mirroredFrameIsComputedOnce() {
        val frame = frames(TestHands.OPEN, Pt(2f, 0f), 3, count = 5).last().item
        val mirrored = frame.mirrored()
        assertSame(mirrored, frame.mirrored())
        assertSame(frame, mirrored.mirrored())
        assertEquals(frame.key xor FrameFeatures.MIRROR_BIT, mirrored.key)
    }

    @Test
    fun recordingDoesNotRecomputeWholeDictionary() {
        // После записи нового слова пороги остальных слов те же, что при полном пересчёте (загрузке).
        val library = SignLibrary()
        val dirs = listOf(Pt(4f, 0f), Pt(-4f, 0f), Pt(0f, 4f), Pt(4f, 1f))
        for ((i, dir) in dirs.withIndex()) {
            library.addMotion("слово$i", SignMatching.prepareTemplate(gestureFrames(TestHands.POINT, dir, 20 + i)))
        }
        val reloaded = SignLibrary()
        assertTrue(reloaded.load(library.toJson()))
        for (sign in library.signs) {
            assertEquals(
                reloaded.effectiveMotionThreshold(sign.id)!!.toRawBits(),
                library.effectiveMotionThreshold(sign.id)!!.toRawBits(),
            )
        }
        // Удаление слова тоже пересчитывает только его пары.
        library.delete(library.signs.first().id)
        val again = SignLibrary()
        assertTrue(again.load(library.toJson()))
        for (sign in library.signs) {
            assertEquals(again.effectiveMotionThreshold(sign.id), library.effectiveMotionThreshold(sign.id))
        }
    }

    private fun gestureFrames(shape: BooleanArray, dir: Pt, seed: Int): List<Timed<SignFrame>> {
        val random = Random(seed)
        var previous: Pt? = null
        return (0 until 60).map { k ->
            val t = k / 30.0
            val progress = ((t - 0.3) / 1.0).coerceIn(0.0, 1.0).toFloat()
            val wrist = Pt(400f, 500f) + dir * (60f * progress)
            val velocity = previous?.let { (wrist - it) / 60f / (1 / 30f) } ?: Pt.ZERO
            previous = wrist
            Timed(t, SignFrame.make(listOf(TestHands.hand(shape, wrist = wrist, jitter = 0.02f, random = random)), velocity)!!)
        }
    }
}
