package com.fen1x.speech.core

import kotlin.math.hypot

/**
 * Точка на экране (в dp) или вектор. Точка (-1, -1) — не найдена.
 * Все пороги распознавания заданы в dp, как в версии для iPhone — в точках экрана.
 */
data class Pt(val x: Float, val y: Float) {
    val isValid: Boolean get() = x >= 0f

    operator fun minus(o: Pt) = Pt(x - o.x, y - o.y)
    operator fun plus(o: Pt) = Pt(x + o.x, y + o.y)
    operator fun times(k: Float) = Pt(x * k, y * k)
    operator fun div(k: Float) = Pt(x / k, y / k)

    val length: Float get() = hypot(x, y)

    companion object {
        val MISSING = Pt(-1f, -1f)
        val ZERO = Pt(0f, 0f)
    }
}

fun dist(a: Pt, b: Pt): Float = hypot(a.x - b.x, a.y - b.y)

/** Значение с отметкой времени (секунды). */
data class Timed<T>(val time: Double, val item: T)

/** Индексы 21 ключевой точки кисти (порядок MediaPipe совпадает с порядком Apple Vision в версии для iPhone). */
object Joint {
    const val WRIST = 0
    const val THUMB_CMC = 1
    const val THUMB_MP = 2
    const val THUMB_IP = 3
    const val THUMB_TIP = 4
    const val INDEX_MCP = 5
    const val INDEX_PIP = 6
    const val INDEX_DIP = 7
    const val INDEX_TIP = 8
    const val MIDDLE_MCP = 9
    const val MIDDLE_PIP = 10
    const val MIDDLE_DIP = 11
    const val MIDDLE_TIP = 12
    const val RING_MCP = 13
    const val RING_PIP = 14
    const val RING_DIP = 15
    const val RING_TIP = 16
    const val LITTLE_MCP = 17
    const val LITTLE_PIP = 18
    const val LITTLE_DIP = 19
    const val LITTLE_TIP = 20
    const val COUNT = 21
}
