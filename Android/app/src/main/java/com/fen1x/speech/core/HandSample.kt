package com.fen1x.speech.core

import kotlin.math.PI
import kotlin.math.hypot
import kotlin.math.max

/**
 * Рука на кадре в координатах экрана (dp): 21 точка и уверенность в каждой (0…1).
 * Точка (-1, -1) — не найдена совсем.
 * chirality — какая это рука: +1 правая, −1 левая, 0 — неизвестно.
 */
data class HandSample(
    val points: List<Pt>,
    val confidence: List<Float>,
    val chirality: Int = 0,
) {
    /** Размер ладони: от запястья до основания среднего пальца. */
    val palmSize: Float
        get() {
            if (points.size != Joint.COUNT || !points[0].isValid || !points[9].isValid) return 0f
            return dist(points[0], points[9])
        }

    /** Центр ладони. */
    val center: Pt
        get() {
            val palm = PALM_JOINTS.map { points[it] }.filter { it.isValid }
            if (palm.isEmpty()) return Pt.ZERO
            val n = palm.size.toFloat()
            return Pt(palm.sumOf { it.x.toDouble() }.toFloat() / n, palm.sumOf { it.y.toDouble() }.toFloat() / n)
        }

    /**
     * Рука пригодна для сравнения жестов: все точки есть, ладонь видна уверенно,
     * а пальцы в среднем видны хотя бы частично.
     */
    val isUsable: Boolean
        get() {
            if (points.size != Joint.COUNT || confidence.size != Joint.COUNT) return false
            if (!points.all { it.isValid } || palmSize <= 10f) return false
            val palmOK = PALM_JOINTS.all { confidence[it] >= 0.2f }
            val mean = confidence.sum() / confidence.size
            return palmOK && mean >= 0.3f
        }

    /** Точки для отрисовки и встроенных жестов: неуверенные точки заменены на (-1, -1). */
    fun thresholded(minimum: Float = 0.3f): List<Pt> =
        points.mapIndexed { i, p -> if (confidence.getOrElse(i) { 0f } >= minimum) p else Pt.MISSING }

    /** Отражение по горизонтали внутри области шириной [width]. */
    fun flipped(width: Float): HandSample =
        copy(points = points.map { if (!it.isValid) it else Pt(width - it.x, it.y) })

    companion object {
        val PALM_JOINTS = listOf(0, 5, 9, 13, 17)
    }
}

/** Коэффициент фильтра One Euro для частоты среза [cutoff] (Гц) и шага [dt] (с). */
private fun oneEuroAlpha(cutoff: Double, dt: Double): Float {
    val tau = 1.0 / (2.0 * PI * cutoff)
    return (1.0 / (1.0 + tau / dt)).toFloat()
}

/**
 * Сглаживание дрожания точек (фильтр One Euro): когда рука неподвижна — сглаживает сильно,
 * когда движется быстро — почти не сглаживает, поэтому почти не добавляет задержки.
 */
class HandSmoother(
    /** Сглаживание в покое (Гц): меньше — плавнее, но с задержкой. */
    var minCutoff: Double = 1.7,
    /** Насколько быстро фильтр «отпускает» при движении. */
    var beta: Double = 3.0,
    var derivativeCutoff: Double = 1.0,
) {
    private class Track(
        val points: List<Pt>,
        val velocity: List<Pt>,
        val time: Double,
        /** Какая это рука, усреднённо по кадрам: одиночные ошибки нейросети не мешают. */
        val chirality: Double,
    )

    private var tracks: List<Track> = emptyList()

    fun reset() {
        tracks = emptyList()
    }

    fun smooth(hands: List<HandSample>, time: Double): List<HandSample> {
        val result = ArrayList<HandSample>(hands.size)
        val newTracks = ArrayList<Track>()
        val used = HashSet<Int>()

        for (hand in hands) {
            val size = hand.palmSize
            if (hand.points.size != Joint.COUNT || !hand.points[0].isValid || size <= 0f) {
                result.add(hand)
                continue
            }
            // Та же рука на прошлом кадре — ближайшая по запястью.
            var match = -1
            var best = Float.POSITIVE_INFINITY
            tracks.forEachIndexed { i, track ->
                if (i !in used && track.points[0].isValid) {
                    val d = dist(track.points[0], hand.points[0])
                    if (d < best) {
                        best = d
                        match = i
                    }
                }
            }
            if (match < 0 || best >= max(size * 1.5f, 40f) || time - tracks[match].time >= 0.25) {
                newTracks.add(Track(hand.points, List(Joint.COUNT) { Pt.ZERO }, time, hand.chirality.toDouble()))
                result.add(hand)
                continue
            }
            used.add(match)

            val previous = tracks[match]
            val dt = max(0.001, time - previous.time)
            val points = hand.points.toMutableList()
            val velocity = previous.velocity.toMutableList()
            val ad = oneEuroAlpha(derivativeCutoff, dt)

            for (j in points.indices) {
                if (!points[j].isValid || !previous.points[j].isValid) continue
                val raw = (points[j] - previous.points[j]) / dt.toFloat()
                val v = raw * ad + velocity[j] * (1 - ad)
                velocity[j] = v
                val speed = (hypot(v.x, v.y) / size).toDouble()   // ладоней в секунду
                val a = oneEuroAlpha(minCutoff + beta * speed, dt)
                points[j] = previous.points[j] + (points[j] - previous.points[j]) * a
            }
            var chirality = previous.chirality
            if (hand.chirality != 0) {
                chirality = chirality * 0.8 + hand.chirality * 0.2
            }
            newTracks.add(Track(points, velocity, time, chirality))
            val label = when {
                chirality > 0.3 -> 1
                chirality < -0.3 -> -1
                else -> 0
            }
            result.add(HandSample(points, hand.confidence, label))
        }
        tracks = newTracks
        return result
    }
}

/** Плечи сглаживаются тем же фильтром One Euro, что и точки рук, и так же быстро следуют за человеком. */
class ShoulderSmoother(
    var minCutoff: Double = 1.7,
    var beta: Double = 3.0,
    var derivativeCutoff: Double = 1.0,
) {
    private var points: MutableList<Pt> = mutableListOf()
    private var velocity: MutableList<Pt> = mutableListOf()
    private var time: Double = 0.0

    fun reset() {
        points = mutableListOf()
        velocity = mutableListOf()
    }

    /**
     * [found] — плечи на этом кадре, слева направо; null — не найдены.
     * Возвращает сглаженные плечи или пустой список.
     */
    fun smooth(found: List<Pt>?, now: Double): List<Pt> {
        if (found == null || found.size != 2) {
            // Плечи пропали: как и руки, прежнее положение держим только долю секунды.
            if (now - time > 0.2) reset()
            return points.toList()
        }
        // Скорость считаем в «ладонях» — примерно треть расстояния между плечами.
        val size = max(dist(found[0], found[1]) / 3f, 1f)
        if (points.size != 2 || now - time >= 0.25 || dist(points[0], found[0]) >= size * 3f) {
            points = found.toMutableList()
            velocity = mutableListOf(Pt.ZERO, Pt.ZERO)
            time = now
            return points.toList()
        }
        val dt = max(0.001, now - time)
        val ad = oneEuroAlpha(derivativeCutoff, dt)
        for (j in 0 until 2) {
            val raw = (found[j] - points[j]) / dt.toFloat()
            val v = raw * ad + velocity[j] * (1 - ad)
            velocity[j] = v
            val speed = (hypot(v.x, v.y) / size).toDouble()
            val a = oneEuroAlpha(minCutoff + beta * speed, dt)
            points[j] = points[j] + (found[j] - points[j]) * a
        }
        time = now
        return points.toList()
    }
}
