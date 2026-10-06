package com.fen1x.speech.core

/**
 * Поза распознаётся, только когда форма кисти устоялась.
 *
 * Между двумя жестами пальцы меняют положение, и на долю секунды кисть может быть похожа
 * на какое-нибудь слово словаря. Пока форма кисти заметно меняется (больше [maxChange]
 * за [window] секунд — это больше обычного дрожания точек), поза не распознаётся.
 */
class PoseSteadiness(
    var window: Double = 0.15,
    var maxChange: Float = 0.09f,
) {
    private val history = ArrayDeque<Timed<FrameFeatures>>()

    fun reset() {
        history.clear()
    }

    /**
     * [features] — поза в кадре (null — рук нет). Возвращает true, если форма кисти не меняется
     * (или рука только появилась и сравнивать пока не с чем).
     */
    fun update(features: FrameFeatures?, time: Double): Boolean {
        if (features == null) {
            history.clear()
            return false
        }
        history.addLast(Timed(time, features))
        while (history.size > 1 && time - history.first().time > 0.5) history.removeFirst()
        val reference = history.lastOrNull { time - it.time >= window } ?: return true
        val change = FrameFeatures.handShapeDistance(features, reference.item)
        // Изменилось число рук — сравнивать нельзя, решает удержание жеста.
        if (!change.isFinite()) return true
        return change <= maxChange
    }
}
