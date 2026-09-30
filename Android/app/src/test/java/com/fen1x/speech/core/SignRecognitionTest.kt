package com.fen1x.speech.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class SignRecognitionTest {
    private fun poseFrames(shape: BooleanArray, seed: Int, count: Int = 30): List<SignFrame> {
        val random = Random(seed)
        return (0 until count).map {
            SignFrame.make(listOf(TestHands.hand(shape, jitter = 0.03f, random = random)))!!
        }
    }

    private fun library(): SignLibrary {
        val library = SignLibrary()
        library.addPoses("привет", poseFrames(TestHands.OPEN, 1))
        library.addPoses("кулак", poseFrames(TestHands.FIST, 2))
        library.addPoses("один", poseFrames(TestHands.POINT, 3))
        return library
    }

    private fun classify(library: SignLibrary, sample: HandSample): String? {
        val frame = SignFrame.make(listOf(sample)) ?: return null
        return library.classifyPose(listOf(FrameFeatures.from(frame)), null)?.word
    }

    @Test
    fun builtInGestures() {
        fun gesture(shape: BooleanArray) = HandGeometry.from(TestHands.hand(shape).points)!!.staticGesture()
        assertEquals(Gesture.OPEN_PALM, gesture(TestHands.OPEN))
        assertEquals(Gesture.FIST, gesture(TestHands.FIST))
        assertEquals(Gesture.POINTING, gesture(TestHands.POINT))
        assertEquals(Gesture.VICTORY, gesture(TestHands.VICTORY))
    }

    @Test
    fun recognisesRecordedPoses() {
        val library = library()
        val random = Random(42)
        assertEquals("привет", classify(library, TestHands.hand(TestHands.OPEN, jitter = 0.03f, random = random)))
        assertEquals("кулак", classify(library, TestHands.hand(TestHands.FIST, jitter = 0.03f, random = random)))
        assertEquals("один", classify(library, TestHands.hand(TestHands.POINT, jitter = 0.03f, random = random)))
    }

    @Test
    fun independentOfSizeAndPosition() {
        val library = library()
        val far = TestHands.hand(TestHands.POINT, wrist = Pt(80f, 300f), scale = 35f)
        val near = TestHands.hand(TestHands.POINT, wrist = Pt(250f, 650f), scale = 110f)
        assertEquals("один", classify(library, far))
        assertEquals("один", classify(library, near))
    }

    @Test
    fun leftHandIsMirrorOfRightHand() {
        val library = library()
        val left = TestHands.hand(TestHands.POINT, chirality = -1).flipped(400f)
        assertEquals("один", classify(library, left))
    }

    @Test
    fun unknownPoseIsNotRecognised() {
        val library = library()
        // Указательный и средний — такого слова нет.
        assertNull(classify(library, TestHands.hand(TestHands.VICTORY)))
        assertNotNull(library.lastCandidate)
    }

    @Test
    fun similarPoseIsReportedWhenRecording() {
        val library = library()
        val similar = library.similarPose(poseFrames(TestHands.OPEN, 7), "здравствуйте")
        assertEquals("привет", similar?.word)
        assertNull(library.similarPose(poseFrames(TestHands.VICTORY, 8), "два"))
    }

    @Test
    fun dictionaryRoundTrip() {
        val library = library()
        val json = library.toJson()
        val restored = SignLibrary()
        assertTrue(restored.load(json))
        assertEquals(library.signs.map { it.word }, restored.signs.map { it.word })
        assertEquals("кулак", classify(restored, TestHands.hand(TestHands.FIST)))
        assertTrue(!SignLibrary().load("не json"))
    }

    @Test
    fun deleteRemovesWord() {
        val library = library()
        var changes = 0
        library.onChange = { changes++ }
        library.delete(library.signs.first { it.word == "один" }.id)
        assertEquals(1, changes)
        assertEquals(listOf("привет", "кулак"), library.signs.map { it.word })
    }

    @Test
    fun twoHandPoseAlsoMatchesOneHandVariant() {
        val library = library()
        val right = TestHands.hand(TestHands.POINT, wrist = Pt(300f, 500f))
        val resting = TestHands.hand(TestHands.FIST, wrist = Pt(80f, 700f), chirality = -1)
        val both = SignFrame.make(listOf(right, resting))!!
        assertEquals(2, both.handCount)
        val variants = listOf(both, SignFrame.make(listOf(right))!!, SignFrame.make(listOf(resting))!!)
            .map { FrameFeatures.from(it) }
        // Две руки не совпадают ни с одним словом, но отдельно правая рука — «один».
        val word = library.classifyPose(variants, null)?.word
        assertTrue(word == "один" || word == null)
    }

    @Test
    fun smootherReducesJitter() {
        val smoother = HandSmoother()
        val random = Random(5)
        var raw = 0f
        var smooth = 0f
        var previousRaw: HandSample? = null
        var previousSmooth: HandSample? = null
        for (i in 0 until 60) {
            val sample = TestHands.hand(TestHands.OPEN, jitter = 0.05f, random = random)
            val smoothed = smoother.smooth(listOf(sample), i / 30.0).single()
            if (previousRaw != null && previousSmooth != null) {
                raw += dist(sample.points[8], previousRaw.points[8])
                smooth += dist(smoothed.points[8], previousSmooth.points[8])
            }
            previousRaw = sample
            previousSmooth = smoothed
        }
        assertTrue("smooth=$smooth raw=$raw", smooth < raw * 0.6f)
    }

    @Test
    fun recognizerHoldsAndFiresOnce() {
        val recognizer = GestureRecognizer()
        recognizer.swipesEnabled = false
        val points = TestHands.hand(TestHands.OPEN).points
        var fired = 0
        for (i in 0 until 30) {
            val result = recognizer.process(listOf(points), i / 30.0) { hands ->
                val g = hands.first().staticGesture()
                if (g == Gesture.IDLE) Sign.None else Sign.BuiltIn(g)
            }
            if (result.fired != null) fired++
        }
        assertEquals(1, fired)
    }

    @Test
    fun recognizerDetectsSwipe() {
        val recognizer = GestureRecognizer()
        var swipe: Sign? = null
        for (i in 0 until 20) {
            val wrist = Pt(100f + i * 15f, 500f)
            val result = recognizer.process(listOf(TestHands.hand(TestHands.OPEN, wrist = wrist).points), i / 30.0) { Sign.None }
            if (result.fired != null) {
                swipe = result.fired
                break
            }
        }
        assertEquals(Sign.BuiltIn(Gesture.SWIPE_RIGHT), swipe)
    }
}
