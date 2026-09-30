package com.fen1x.speech.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class MotionRecognitionTest {
    /**
     * Жест с движением: пауза, движение руки по направлению [dir] (в ладонях) за [duration] секунд, пауза.
     * Кадры 30 в секунду, скорость — как в приложении: смещение центра ладони в ладонях в секунду.
     */
    private fun gesture(
        shape: BooleanArray,
        dir: Pt,
        duration: Double,
        seed: Int,
        chirality: Int = 1,
        mirror: Boolean = false,
    ): List<Timed<SignFrame>> {
        val random = Random(seed)
        val fps = 30.0
        val scale = 60f
        val start = Pt(200f, 500f)
        val result = ArrayList<Timed<SignFrame>>()
        val still = 0.3
        val total = still * 2 + duration
        var previous: Pt? = null
        var t = 0.0
        while (t <= total) {
            val progress = ((t - still) / duration).coerceIn(0.0, 1.0).toFloat()
            var wrist = start + dir * (scale * progress)
            var sample = TestHands.hand(shape, wrist = wrist, scale = scale, chirality = chirality, jitter = 0.02f, random = random)
            if (mirror) {
                sample = sample.flipped(800f)
                wrist = Pt(800f - wrist.x, wrist.y)
            }
            val velocity = previous?.let { (wrist - it) / scale / (1 / fps).toFloat() } ?: Pt.ZERO
            previous = wrist
            result.add(Timed(t, SignFrame.make(listOf(sample), velocity)!!))
            t += 1 / fps
        }
        return result
    }

    private fun stream(frames: List<Timed<SignFrame>>): MotionStream {
        val features = frames.map { Timed(it.time, FrameFeatures.from(it.item)) }
        return MotionStream(SignMatching.resample(features))
    }

    private fun library(): SignLibrary {
        val library = SignLibrary()
        library.addMotion("вправо", SignMatching.prepareTemplate(gesture(TestHands.POINT, Pt(4f, 0f), 0.8, 1)))
        library.addMotion("вниз", SignMatching.prepareTemplate(gesture(TestHands.POINT, Pt(0f, 4f), 0.8, 2)))
        library.addMotion("кулак вверх", SignMatching.prepareTemplate(gesture(TestHands.FIST, Pt(0f, -4f), 0.8, 3)))
        return library
    }

    private fun best(library: SignLibrary, frames: List<Timed<SignFrame>>): String? =
        library.bestMotion(listOf(stream(frames)))?.let { library.sign(it.id)?.word }

    @Test
    fun templateTrimsStillFrames() {
        val template = SignMatching.prepareTemplate(gesture(TestHands.POINT, Pt(4f, 0f), 0.8, 1))
        // 0,8 с движения при 15 кадрах в секунду и небольшом запасе, а не все 1,4 с.
        assertTrue("size=${template.size}", template.size in 10..20)
        assertTrue(!SignMatching.isMostlyStill(template))
    }

    @Test
    fun identicalSequenceCostsNothing() {
        val frames = SignMatching.prepareTemplate(gesture(TestHands.POINT, Pt(4f, 0f), 0.8, 1)).map { FrameFeatures.from(it) }
        val dtw = SignMatching.subsequenceDTW(frames, frames)
        assertEquals(0f, dtw.cost, 1e-5f)
        assertEquals(0, dtw.start)
    }

    @Test
    fun recognisesDirection() {
        val library = library()
        assertEquals("вправо", best(library, gesture(TestHands.POINT, Pt(4f, 0f), 0.8, 11)))
        assertEquals("вниз", best(library, gesture(TestHands.POINT, Pt(0f, 4f), 0.8, 12)))
        assertEquals("кулак вверх", best(library, gesture(TestHands.FIST, Pt(0f, -4f), 0.8, 13)))
    }

    @Test
    fun toleratesDifferentSpeed() {
        val library = library()
        assertEquals("вправо", best(library, gesture(TestHands.POINT, Pt(4f, 0f), 1.2, 21)))
        assertEquals("вправо", best(library, gesture(TestHands.POINT, Pt(4f, 0f), 0.6, 22)))
    }

    @Test
    fun leftHandMirrorsDirection() {
        val library = library()
        // Левая рука, движение влево — зеркало правой руки, движущейся вправо.
        val frames = gesture(TestHands.POINT, Pt(4f, 0f), 0.8, 31, chirality = -1, mirror = true)
        assertEquals("вправо", best(library, frames))
    }

    @Test
    fun stillHandIsNotAMotionSign() {
        val library = library()
        assertNull(best(library, gesture(TestHands.POINT, Pt(0f, 0f), 0.8, 41)))
    }

    @Test
    fun spotterWaitsUntilSimilarityStopsGrowing() {
        val spotter = MotionSpotter()
        assertNull(spotter.update(MotionSpotter.Match("a", 0.8f), 0.0))
        assertNull(spotter.update(MotionSpotter.Match("a", 0.6f), 0.1))
        assertEquals("a", spotter.update(MotionSpotter.Match("a", 0.7f), 0.2))
        assertNull(spotter.update(MotionSpotter.Match("b", 0.5f), 1.0))
        assertEquals("b", spotter.update(null, 1.1))
    }

    @Test
    fun resampleUsesFixedRate() {
        val items = (0 until 31).map { Timed(it / 30.0, it) }
        val resampled = SignMatching.resample(items)
        assertEquals(16, resampled.size)
        assertEquals(30, resampled.last())
        assertEquals(0, resampled.first())
    }
}
