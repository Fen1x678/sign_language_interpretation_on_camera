package com.fen1x.speech.core

import kotlin.math.abs
import kotlin.math.min

// MARK: - Анализ положения кисти (статические жесты)

/** Геометрия кисти в координатах экрана (dp, ось Y направлена вниз). */
class HandGeometry private constructor(
    val p: List<Pt>,
    /**
     * Размер ладони: расстояние от запястья до основания среднего пальца.
     * Все пороги задаются относительно него, поэтому распознавание не зависит от расстояния до камеры.
     */
    val size: Float,
    /** Центр ладони: используется для отслеживания движения. */
    val center: Pt,
) {
    private fun isValid(i: Int) = p[i].isValid

    /** Палец выпрямлен, если его кончик заметно дальше от запястья, чем средний сустав. null — точки не найдены. */
    private fun isFingerExtended(tip: Int, pip: Int): Boolean? {
        if (!isValid(tip) || !isValid(pip)) return null
        val wrist = p[Joint.WRIST]
        return dist(wrist, p[tip]) > dist(wrist, p[pip]) * 1.2f
    }

    /** Большой палец отведён, если его кончик далеко от основания указательного. */
    private val isThumbExtended: Boolean
        get() = isValid(Joint.THUMB_TIP) && dist(p[Joint.THUMB_TIP], p[Joint.INDEX_MCP]) > size * 0.65f

    /** Кончики большого и указательного пальцев соединены в кольцо. */
    private val isThumbIndexRing: Boolean
        get() = isValid(Joint.THUMB_TIP) && isValid(Joint.INDEX_TIP) &&
            dist(p[Joint.THUMB_TIP], p[Joint.INDEX_TIP]) < size * 0.35f

    fun staticGesture(): Gesture {
        val index = isFingerExtended(Joint.INDEX_TIP, Joint.INDEX_PIP) ?: return Gesture.IDLE
        val middle = isFingerExtended(Joint.MIDDLE_TIP, Joint.MIDDLE_PIP) ?: return Gesture.IDLE
        val ring = isFingerExtended(Joint.RING_TIP, Joint.RING_PIP) ?: return Gesture.IDLE
        val little = isFingerExtended(Joint.LITTLE_TIP, Joint.LITTLE_PIP) ?: return Gesture.IDLE

        if (isThumbIndexRing && middle && ring && little) return Gesture.OK
        if (index && middle && ring && little) return Gesture.OPEN_PALM
        if (index && middle && !ring && !little) return Gesture.VICTORY
        if (index && !middle && !ring && !little) return Gesture.POINTING
        if (!index && !middle && !ring && little && isThumbExtended) return Gesture.CALL_ME
        if (!index && !middle && !ring && !little) {
            if (isThumbExtended) {
                // Кончик большого пальца должен быть выше кулака и запястья.
                val top = min(p[Joint.INDEX_MCP].y, p[Joint.WRIST].y)
                if (p[Joint.THUMB_TIP].y < top - size * 0.3f) return Gesture.THUMBS_UP
            } else {
                return Gesture.FIST
            }
        }
        return Gesture.IDLE
    }

    companion object {
        private val PALM = listOf(Joint.WRIST, Joint.INDEX_MCP, Joint.MIDDLE_MCP, Joint.RING_MCP, Joint.LITTLE_MCP)

        fun from(points: List<Pt>): HandGeometry? {
            if (points.size != Joint.COUNT) return null
            if (!PALM.all { points[it].isValid }) return null
            val size = dist(points[Joint.WRIST], points[Joint.MIDDLE_MCP])
            if (size <= 10f) return null
            val palm = PALM.map { points[it] }
            val center = Pt(palm.map { it.x }.average().toFloat(), palm.map { it.y }.average().toFloat())
            return HandGeometry(points, size, center)
        }
    }
}

// MARK: - Классификация жестов

data class RecognitionResult(
    /** Жест, который сейчас видит система. */
    val sign: Sign = Sign.None,
    /** Жест, который только что сработал (срабатывает один раз). */
    val fired: Sign? = null,
    /** Прогресс удержания статического жеста, 0…1. */
    val holdProgress: Double = 0.0,
)

/**
 * Блоки схемы «Анализ положения и движения → Классификация жеста».
 *
 * Защита от случайных срабатываний:
 * • статический жест нужно удерживать неподвижно [holdDuration] секунд;
 * • удерживаемый жест срабатывает один раз, повтор — только после смены жеста;
 * • после движения (свайпа) действует пауза [cooldown], чтобы обратное движение руки не дало лишнюю команду;
 * • кратковременная потеря руки (до [lostHandTimeout]) не сбрасывает состояние.
 */
class GestureRecognizer {
    var holdDuration = 0.4        // сек удержания статического жеста
    var swipeWindow = 0.5         // за какое время должно произойти движение
    var swipeDistance = 1.5f      // длина движения в размерах ладони
    var cooldown = 0.9            // пауза после свайпа
    var lostHandTimeout = 0.3     // допустимое исчезновение руки из кадра
    var swipesEnabled = true      // в режиме «Перевод» свайпы выключены

    private val track = ArrayList<Timed<Pt>>()
    private var handAppearedAt: Double? = null
    private var lastHandTime = 0.0
    private var candidate: Sign = Sign.None
    private var candidateSince = 0.0
    private var candidateLastSeen = 0.0
    private var latched: Sign = Sign.None
    private var latchedLastSeen = 0.0
    private var latchNextUntil: Double? = null
    private var cooldownUntil = 0.0
    private var lastHandCount = 0

    fun reset() {
        track.clear()
        lastHandCount = 0
        handAppearedAt = null
        candidate = Sign.None
        latched = Sign.None
        latchNextUntil = null
    }

    /**
     * После жеста с движением рука ещё какое-то время стоит в конечной позе.
     * Эта поза не должна засчитываться как отдельное слово, поэтому первая распознанная
     * поза (в течение 0,4 с) считается уже сработавшей.
     */
    fun latchNextSign(time: Double) {
        latchNextUntil = time + 0.4
    }

    /**
     * [hands] — точки найденных рук (одна или две) в координатах экрана.
     * [classify] определяет статический жест по положению кистей
     * (встроенные правила и/или словарь пользовательских жестов).
     */
    fun process(hands: List<List<Pt>>, time: Double, classify: (List<HandGeometry>) -> Sign): RecognitionResult {
        val geometries = hands.mapNotNull { HandGeometry.from(it) }
        if (geometries.isEmpty()) {
            if (time - lastHandTime > lostHandTimeout) reset()
            return RecognitionResult()
        }
        lastHandTime = time
        if (handAppearedAt == null) handAppearedAt = time

        // Если число рук изменилось, траекторию начинаем заново, чтобы не было ложных свайпов.
        if (geometries.size != lastHandCount) {
            track.clear()
            lastHandCount = geometries.size
        }

        // Движение отслеживаем по «ведущей» руке: той, что ближе к прошлому положению,
        // а в начале — по самой крупной (ближней к камере).
        val previous = track.lastOrNull()?.item
        val hand = if (previous != null) {
            geometries.minByOrNull { dist(it.center, previous) }!!
        } else {
            geometries.maxByOrNull { it.size }!!
        }

        // Пауза после динамического жеста.
        if (time < cooldownUntil) {
            track.clear()
            return RecognitionResult()
        }

        // Отслеживание положения руки во времени.
        track.add(Timed(time, hand.center))
        track.removeAll { time - it.time > swipeWindow }

        // 1. Динамические жесты.
        val appeared = handAppearedAt
        if (swipesEnabled && appeared != null && time - appeared > 0.2) {
            val swipe = detectSwipe(hand.size)
            if (swipe != null) {
                track.clear()
                candidate = Sign.None
                latched = Sign.None
                cooldownUntil = time + cooldown
                val sign = Sign.BuiltIn(swipe)
                return RecognitionResult(sign, sign, 1.0)
            }
        }

        // Пока рука движется, статические жесты не распознаём.
        if (isMoving(time, hand.size)) {
            candidate = Sign.None
            return RecognitionResult()
        }

        // 2. Статические жесты.
        val current = classify(geometries)

        val until = latchNextUntil
        if (until != null) {
            if (time > until) {
                latchNextUntil = null
            } else if (current != Sign.None) {
                latchNextUntil = null
                latched = current
                latchedLastSeen = time
            }
        }

        if (latched != Sign.None) {
            if (current == latched) {
                latchedLastSeen = time
                return RecognitionResult(current, null, 1.0)
            } else if (time - latchedLastSeen > 0.3) {
                latched = Sign.None
            }
        }

        if (current == Sign.None) {
            // Жест «потерялся» на долю секунды (моргнула рука, дрогнул палец) — не начинаем заново.
            if (candidate != Sign.None && time - candidateLastSeen < 0.15) {
                val progress = min(1.0, (time - candidateSince) / holdDuration)
                return RecognitionResult(candidate, null, min(progress, 0.99))
            }
            candidate = Sign.None
            return RecognitionResult()
        }

        if (candidate != current) {
            candidate = current
            candidateSince = time
        }
        candidateLastSeen = time

        val progress = min(1.0, (time - candidateSince) / holdDuration)
        if (progress >= 1.0) {
            latched = current
            latchedLastSeen = time
            candidate = Sign.None
            return RecognitionResult(current, current, 1.0)
        }
        return RecognitionResult(current, null, progress)
    }

    private fun detectSwipe(handSize: Float): Gesture? {
        val first = track.firstOrNull() ?: return null
        val last = track.lastOrNull() ?: return null
        if (last.time - first.time <= 0.08) return null

        val dx = last.item.x - first.item.x
        val dy = last.item.y - first.item.y
        val threshold = handSize * swipeDistance

        if (abs(dx) > threshold && abs(dx) > abs(dy) * 1.8f) {
            return if (dx > 0) Gesture.SWIPE_RIGHT else Gesture.SWIPE_LEFT
        }
        if (abs(dy) > threshold && abs(dy) > abs(dx) * 1.8f) {
            return if (dy > 0) Gesture.SWIPE_DOWN else Gesture.SWIPE_UP
        }
        return null
    }

    private fun isMoving(time: Double, handSize: Float): Boolean {
        val last = track.lastOrNull() ?: return false
        val reference = track.lastOrNull { time - it.time >= 0.15 } ?: return false
        return dist(reference.item, last.item) > handSize * 0.3f
    }
}
