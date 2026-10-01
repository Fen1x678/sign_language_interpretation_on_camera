package com.fen1x.speech.core

import kotlin.math.max

/**
 * Опущенная вторая рука не участвует в распознавании.
 *
 * Жест часто показывают одной рукой, а вторая лежит на столе или на коленях и всё равно видна
 * в кадре. Если её учитывать, жест одной рукой превращается в «жест двумя руками» и не узнаётся
 * (а при записи позы может записаться как жест двумя руками).
 *
 * Рука считается опущенной, если одновременно:
 * • в кадре две руки, и эта рука заметно ниже другой (больше чем на [LOWER_BY] ладони);
 * • она внизу: ниже уровня груди (дальше [BELOW_SHOULDERS] расстояний между плечами от линии плеч),
 *   в нижней части изображения или касается его нижнего края;
 * • она почти не двигается дольше [REST_TIME] секунд.
 * Как только рука поднимается или начинает двигаться, она сразу снова учитывается —
 * жесты двумя руками работают как обычно. Одна рука в кадре учитывается всегда.
 */
class RestingHandFilter {
    private class Track(
        var center: Pt,
        var time: Double,
        /** Скорость центра ладони, ладоней в секунду (сглажена). */
        var speed: Float,
        var restingSince: Double?,
        var resting: Boolean,
    )

    private var tracks: List<Track> = emptyList()

    fun reset() {
        tracks = emptyList()
    }

    /**
     * [hands] — руки на кадре (в координатах экрана, dp), [body] — плечи (если найдены),
     * [viewHeight] — высота изображения. Возвращает для каждой руки: true — учитывать.
     */
    fun update(hands: List<HandSample>, body: BodyReference?, viewHeight: Float, time: Double): BooleanArray {
        val active = BooleanArray(hands.size) { true }
        val newTracks = ArrayList<Track>(hands.size)
        val used = HashSet<Int>()

        for ((i, hand) in hands.withIndex()) {
            val size = hand.palmSize
            if (size <= 0f) continue
            val center = hand.center

            // Та же рука на прошлом кадре — ближайшая по центру ладони.
            var match = -1
            var best = Float.POSITIVE_INFINITY
            tracks.forEachIndexed { j, track ->
                if (j !in used) {
                    val d = dist(track.center, center)
                    if (d < best) {
                        best = d
                        match = j
                    }
                }
            }
            val track = if (match >= 0 && best < max(size * 2f, 60f) && time - tracks[match].time < 0.5) {
                used.add(match)
                tracks[match]
            } else {
                Track(center, time, 0f, null, false)
            }
            val dt = time - track.time
            if (dt > 0) {
                val raw = dist(track.center, center) / size / dt.toFloat()
                track.speed = track.speed * 0.6f + raw * 0.4f
            }
            track.center = center
            track.time = time

            val other = hands.withIndex().firstOrNull { it.index != i && it.value.palmSize > 0f }?.value
            val lower = other != null && center.y - other.center.y > LOWER_BY * size
            val low = lower && isLow(hand, body, viewHeight)
            if (!low || track.speed > ACTIVE_SPEED) {
                track.restingSince = null
                track.resting = false
            } else if (track.speed < STILL_SPEED) {
                val since = track.restingSince ?: time.also { track.restingSince = it }
                if (time - since >= REST_TIME) track.resting = true
            }
            newTracks.add(track)
            active[i] = !track.resting
        }
        tracks = newTracks
        // Одна рука в кадре учитывается всегда.
        if (hands.size < 2) active.fill(true)
        return active
    }

    private fun isLow(hand: HandSample, body: BodyReference?, viewHeight: Float): Boolean {
        val c = hand.center
        if (body != null && (c.y - body.center.y) / body.width > BELOW_SHOULDERS) return true
        if (viewHeight <= 0f) return false
        if (c.y > viewHeight * LOW_PART) return true
        // Рука лежит у нижнего края изображения (часть кисти за краем).
        return hand.points.any { it.isValid && it.y > viewHeight * 0.97f }
    }

    companion object {
        /** Насколько ниже другой руки (в ладонях) должна быть опущенная рука. */
        const val LOWER_BY = 1.5f
        /** Ниже линии плеч больше чем на столько расстояний между плечами — уровень стола или колен. */
        const val BELOW_SHOULDERS = 1.0f
        /** Нижняя часть изображения (доля высоты). */
        const val LOW_PART = 0.8f
        /** Медленнее этого (ладоней в секунду) рука считается неподвижной… */
        const val STILL_SPEED = 0.5f
        /** …а быстрее этого — снова учитывается сразу. */
        const val ACTIVE_SPEED = 1.2f
        /** Сколько секунд рука должна лежать неподвижно внизу, чтобы перестать учитываться. */
        const val REST_TIME = 0.4
    }
}
