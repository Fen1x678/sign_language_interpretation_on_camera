package com.fen1x.speech.core

import kotlin.math.hypot
import kotlin.random.Random

/** Синтетические руки для тестов: 21 точка в dp, пальцы вверх, как у поднятой к камере ладони. */
object TestHands {
    private val mcp = listOf(Pt(-0.35f, -0.95f), Pt(0f, -1f), Pt(0.3f, -0.95f), Pt(0.55f, -0.85f))

    /**
     * [extended] — какие пальцы выпрямлены: большой, указательный, средний, безымянный, мизинец.
     * [scale] — размер ладони в dp, [center] — где запястье на экране.
     */
    fun hand(
        extended: BooleanArray,
        wrist: Pt = Pt(200f, 500f),
        scale: Float = 60f,
        chirality: Int = 1,
        jitter: Float = 0f,
        random: Random = Random(1),
    ): HandSample {
        val pts = ArrayList<Pt>(21)
        pts.add(Pt(0f, 0f))
        // Большой палец.
        if (extended[0]) {
            pts += listOf(Pt(-0.35f, -0.3f), Pt(-0.6f, -0.55f), Pt(-0.8f, -0.75f), Pt(-0.95f, -0.95f))
        } else {
            pts += listOf(Pt(-0.35f, -0.3f), Pt(-0.45f, -0.55f), Pt(-0.3f, -0.75f), Pt(-0.1f, -0.8f))
        }
        // Остальные пальцы.
        for ((f, base) in mcp.withIndex()) {
            val len = hypot(base.x, base.y)
            val dir = Pt(base.x / len, base.y / len)
            if (extended[f + 1]) {
                val pip = base + dir * 0.45f
                val dip = pip + dir * 0.3f
                val tip = dip + dir * 0.25f
                pts += listOf(base, pip, dip, tip)
            } else {
                val pip = base + dir * 0.3f
                val dip = pip + Pt(0f, 0.25f) + dir * 0.05f
                val tip = base + Pt(0f, 0.15f)
                pts += listOf(base, pip, dip, tip)
            }
        }
        val points = pts.map { p ->
            val jx = if (jitter > 0) (random.nextFloat() * 2 - 1) * jitter else 0f
            val jy = if (jitter > 0) (random.nextFloat() * 2 - 1) * jitter else 0f
            Pt(wrist.x + (p.x + jx) * scale, wrist.y + (p.y + jy) * scale)
        }
        return HandSample(points, List(21) { 0.9f }, chirality)
    }

    val OPEN = booleanArrayOf(true, true, true, true, true)
    val FIST = booleanArrayOf(false, false, false, false, false)
    val POINT = booleanArrayOf(false, true, false, false, false)
    val VICTORY = booleanArrayOf(false, true, true, false, false)
}
