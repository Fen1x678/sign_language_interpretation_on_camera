package com.fen1x.speech.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Проверки, которые уменьшают ошибки: похожие слова, переходы между жестами. */
class AccuracyTest {
    private fun poseFrames(shape: BooleanArray, seed: Int, count: Int = 30, jitter: Float = 0.03f): List<SignFrame> {
        val random = Random(seed)
        return (0 until count).map {
            SignFrame.make(listOf(TestHands.hand(shape, jitter = jitter, random = random)))!!
        }
    }

    private val body = BodyReference.from(listOf(Pt(130f, 400f), Pt(290f, 400f)))

    /** Одна и та же форма кисти на разной высоте (у подбородка, у груди) — разные слова. */
    private fun at(y: Float, seed: Int, count: Int = 30): List<SignFrame> {
        val random = Random(seed)
        return (0 until count).map {
            SignFrame.make(listOf(TestHands.hand(TestHands.POINT, wrist = Pt(220f, y), jitter = 0.03f, random = random)), body = body)!!
        }
    }

    private fun classifyAt(library: SignLibrary, y: Float, random: Random): String? {
        val frame = SignFrame.make(listOf(TestHands.hand(TestHands.POINT, wrist = Pt(220f, y), jitter = 0.04f, random = random)), body = body)!!
        return library.classifyPose(listOf(FrameFeatures.from(frame)), null)?.word
    }

    @Test
    fun similarWordsGetStricterThresholds() {
        val library = SignLibrary()
        library.addPoses("подбородок", at(380f, 1))
        val alone = library.effectivePoseThreshold(library.signs.single().id)!!
        assertEquals(SignMatching.BASE_POSE_THRESHOLD, alone, 1e-6f)

        // Та же форма кисти, но у груди — похожее слово: оба порога строже.
        library.addPoses("грудь", at(470f, 2))
        for (sign in library.signs) {
            val strict = library.effectivePoseThreshold(sign.id)!!
            assertTrue("${sign.word}: $strict", strict < SignMatching.BASE_POSE_THRESHOLD)
            assertTrue(strict >= SignMatching.BASE_POSE_THRESHOLD * SignMatching.MIN_THRESHOLD_SHARE - 1e-6f)
        }

        // Далёкое слово порог не меняет.
        library.addPoses("ладонь", poseFrames(TestHands.OPEN, 3))
        val palm = library.signs.first { it.word == "ладонь" }
        assertEquals(SignMatching.BASE_POSE_THRESHOLD, library.effectivePoseThreshold(palm.id)!!, 1e-6f)
    }

    @Test
    fun similarWordsAreNotConfused() {
        val library = SignLibrary()
        library.addPoses("подбородок", at(380f, 1))
        library.addPoses("грудь", at(470f, 2))
        val random = Random(9)
        var wrong = 0
        var right = 0
        for (k in 0 until 40) {
            val chin = k % 2 == 0
            val word = classifyAt(library, if (chin) 380f else 470f, random)
            if (word == (if (chin) "подбородок" else "грудь")) right++ else if (word != null) wrong++
            // Посередине между ними — ни то ни другое не должно засчитываться наугад.
        }
        assertEquals(0, wrong)
        assertTrue("right=$right", right >= 30)
        var between = 0
        for (k in 0 until 20) if (classifyAt(library, 425f, random) != null) between++
        assertTrue("between=$between", between <= 4)
    }

    @Test
    fun motionNeighboursAreStricter() {
        val library = SignLibrary()
        fun motion(dx: Float, dy: Float, seed: Int): List<SignFrame> {
            val random = Random(seed)
            val frames = ArrayList<Timed<SignFrame>>()
            var t = 0.0
            var previous: Pt? = null
            while (t <= 1.4) {
                val p = ((t - 0.3) / 0.8).coerceIn(0.0, 1.0).toFloat()
                val wrist = Pt(200f + dx * 60f * p, 500f + dy * 60f * p)
                val v = previous?.let { (wrist - it) / 60f / (1 / 30f) } ?: Pt.ZERO
                previous = wrist
                frames.add(Timed(t, SignFrame.make(listOf(TestHands.hand(TestHands.POINT, wrist = wrist, scale = 60f, jitter = 0.02f, random = random)), v)!!))
                t += 1 / 30.0
            }
            return SignMatching.prepareTemplate(frames)
        }
        library.addMotion("вправо", motion(4f, 0f, 1))
        val alone = library.effectiveMotionThreshold(library.signs.single().id)!!
        library.addMotion("вправо-вниз", motion(4f, 1.5f, 2))
        val right = library.signs.first { it.word == "вправо" }
        assertTrue("motion=${library.effectiveMotionThreshold(right.id)} alone=$alone", library.effectiveMotionThreshold(right.id)!! < alone)
        library.addMotion("вверх", motion(0f, -4f, 3))
        val up = library.signs.first { it.word == "вверх" }
        assertEquals(SignMatching.BASE_MOTION_THRESHOLD, library.effectiveMotionThreshold(up.id)!!, 1e-6f)
    }

    @Test
    fun steadyPoseIsAccepted() {
        val steadiness = PoseSteadiness()
        val random = Random(4)
        var steady = true
        for (k in 0 until 20) {
            val f = FrameFeatures.from(SignFrame.make(listOf(TestHands.hand(TestHands.POINT, jitter = 0.02f, random = random)))!!)
            steady = steadiness.update(f, k / 30.0)
        }
        assertTrue(steady)
    }

    @Test
    fun changingHandIsNotAPose() {
        val steadiness = PoseSteadiness()
        val shapes = listOf(TestHands.FIST, TestHands.POINT, TestHands.VICTORY, TestHands.OPEN)
        var unsteady = 0
        for (k in 0 until 24) {
            // Каждые 0,2 с другой жест — пальцы всё время меняют положение.
            val shape = shapes[(k / 6) % shapes.size]
            val f = FrameFeatures.from(SignFrame.make(listOf(TestHands.hand(shape)))!!)
            if (!steadiness.update(f, k / 30.0)) unsteady++
        }
        assertTrue("unsteady=$unsteady", unsteady >= 8)
        assertFalse(steadiness.update(null, 1.0))
    }

    @Test
    fun stricterAmbiguityRatio() {
        assertNotEquals(1.1f, SignMatching.AMBIGUITY_RATIO)
    }
}
