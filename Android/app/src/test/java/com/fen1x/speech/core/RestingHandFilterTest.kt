package com.fen1x.speech.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RestingHandFilterTest {
    private val height = 800f
    private val shoulders = BodyReference.from(listOf(Pt(130f, 330f), Pt(270f, 330f)))

    /** Правая рука показывает жест у груди, левая лежит на столе у нижнего края. */
    private fun frame(t: Double, restingMoves: Boolean = false): List<HandSample> {
        val signing = TestHands.hand(TestHands.POINT, wrist = Pt(250f + (t * 40).toFloat(), 420f), scale = 50f)
        val restX = if (restingMoves) 100f + (t * 300).toFloat() else 100f
        val resting = TestHands.hand(TestHands.FIST, wrist = Pt(restX, 790f), scale = 50f, chirality = -1)
        return listOf(signing, resting)
    }

    private fun run(filter: RestingHandFilter, from: Double, to: Double, restingMoves: Boolean = false): BooleanArray {
        var t = from
        var result = BooleanArray(0)
        while (t <= to) {
            result = filter.update(frame(t, restingMoves), shoulders, height, t)
            t += 1 / 30.0
        }
        return result
    }

    @Test
    fun restingHandIsIgnoredAfterAMoment() {
        val filter = RestingHandFilter()
        // Сразу обе руки учитываются…
        assertArrayEquals(booleanArrayOf(true, true), filter.update(frame(0.0), shoulders, height, 0.0))
        // …а через полсекунды неподвижная опущенная рука — нет.
        assertArrayEquals(booleanArrayOf(true, false), run(filter, 0.0, 0.6))
    }

    @Test
    fun movingSecondHandIsUsedAgain() {
        val filter = RestingHandFilter()
        run(filter, 0.0, 0.6)
        assertArrayEquals(booleanArrayOf(true, true), run(filter, 0.63, 0.9, restingMoves = true))
    }

    @Test
    fun raisedSecondHandIsAlwaysUsed() {
        val filter = RestingHandFilter()
        var result = BooleanArray(0)
        for (k in 0 until 30) {
            val t = k / 30.0
            val right = TestHands.hand(TestHands.POINT, wrist = Pt(260f, 450f), scale = 50f)
            val left = TestHands.hand(TestHands.OPEN, wrist = Pt(140f, 470f), scale = 50f, chirality = -1)
            result = filter.update(listOf(right, left), shoulders, height, t)
        }
        // Две руки у груди неподвижны (жест двумя руками) — обе учитываются.
        assertArrayEquals(booleanArrayOf(true, true), result)
    }

    @Test
    fun singleHandIsAlwaysUsed() {
        val filter = RestingHandFilter()
        var result = BooleanArray(0)
        for (k in 0 until 30) {
            result = filter.update(listOf(TestHands.hand(TestHands.FIST, wrist = Pt(100f, 790f), scale = 50f)), shoulders, height, k / 30.0)
        }
        assertEquals(1, result.size)
        assertTrue(result[0])
    }

    @Test
    fun worksWithoutShoulders() {
        val filter = RestingHandFilter()
        var result = BooleanArray(0)
        var t = 0.0
        while (t <= 0.6) {
            result = filter.update(frame(t), null, height, t)
            t += 1 / 30.0
        }
        assertArrayEquals(booleanArrayOf(true, false), result)
    }
}
