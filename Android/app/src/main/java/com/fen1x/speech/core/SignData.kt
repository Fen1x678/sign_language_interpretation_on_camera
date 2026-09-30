package com.fen1x.speech.core

import kotlinx.serialization.Serializable
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Поза одной руки: 21 точка относительно запястья, в размерах ладони (x0, y0, x1, y1, … — 42 числа),
 * и уверенность в каждой точке. Хранятся именно точки, а не готовые признаки:
 * если алгоритм сравнения улучшится, записанный словарь останется рабочим.
 */
@Serializable
data class HandPose(
    val points: List<Float>,
    /** Уверенность в каждой из 21 точки. null — считаем все точки надёжными. */
    val confidence: List<Float>? = null,
    /** Какая это рука: +1 правая, −1 левая, 0 или null — неизвестно. */
    val chirality: Int? = null,
) {
    fun weight(i: Int): Float {
        val c = confidence ?: return 1f
        if (i >= c.size) return 1f
        // 0,1 и ниже — почти не учитываем, 0,6 и выше — учитываем полностью.
        return max(0.05f, min(1f, (c[i] - 0.1f) / 0.5f))
    }
}

/**
 * Плечи на кадре (в тех же координатах экрана, что и руки): середина между плечами
 * и расстояние между ними. Относительно плеч считается, где находятся руки.
 */
class BodyReference private constructor(val center: Pt, val width: Float) {
    companion object {
        fun from(shoulders: List<Pt>): BodyReference? {
            if (shoulders.size != 2) return null
            val a = shoulders[0]
            val b = shoulders[1]
            val width = dist(a, b)
            if (width <= 10f) return null
            return BodyReference(Pt((a.x + b.x) / 2, (a.y + b.y) / 2), width)
        }
    }
}

/** Один кадр жеста: одна или две руки, их взаимное положение и движение. */
@Serializable
data class SignFrame(
    /** Руки слева направо (как на экране). */
    val hands: List<HandPose>,
    /** Положение второй руки относительно первой [dx, dy] в размерах ладони. Пусто для одной руки. */
    val relative: List<Float> = emptyList(),
    /** Скорость ведущей руки [vx, vy], поделённая на max(|v|, 1,5). Пусто для позы. */
    val velocity: List<Float> = emptyList(),
    /** Скорость ведущей руки [vx, vy] в ладонях в секунду. null — нет. */
    val rawVelocity: List<Float>? = null,
    /**
     * Где находится каждая рука относительно плеч [x0, y0, x1, y1]: центр ладони относительно
     * середины между плечами, в расстояниях между плечами. null — плечи не были видны.
     */
    val locations: List<Float>? = null,
) {
    val handCount: Int get() = hands.size

    companion object {
        /**
         * Кадр из найденных рук. Учитываются только пригодные руки (см. [HandSample.isUsable]).
         * [velocity] — скорость ведущей руки в ладонях в секунду (для жестов с движением).
         * [body] — плечи, если они видны: тогда запоминается и положение рук относительно тела.
         */
        fun make(samples: List<HandSample>, velocity: Pt? = null, body: BodyReference? = null): SignFrame? {
            val usable = samples.filter { it.isUsable }
            if (usable.isEmpty()) return null
            // Две самые крупные (ближние) руки, слева направо.
            val chosen = usable.sortedByDescending { it.palmSize }.take(2).sortedBy { it.center.x }

            val hands = chosen.map { hand ->
                val origin = hand.points[Joint.WRIST]
                val size = hand.palmSize
                val pts = ArrayList<Float>(Joint.COUNT * 2)
                for (point in hand.points) {
                    pts.add((point.x - origin.x) / size)
                    pts.add((point.y - origin.y) / size)
                }
                HandPose(pts, hand.confidence, hand.chirality)
            }

            var relative: List<Float> = emptyList()
            if (chosen.size == 2) {
                val scale = (chosen[0].palmSize + chosen[1].palmSize) / 2
                relative = listOf(
                    (chosen[1].center.x - chosen[0].center.x) / scale,
                    (chosen[1].center.y - chosen[0].center.y) / scale,
                )
            }
            var scaled: List<Float> = emptyList()
            var raw: List<Float>? = null
            if (velocity != null) {
                val scale = max(sqrt(velocity.x * velocity.x + velocity.y * velocity.y), 1.5f)
                scaled = listOf(velocity.x / scale, velocity.y / scale)
                raw = listOf(velocity.x, velocity.y)
            }
            val locations = body?.let { b ->
                chosen.flatMap { hand ->
                    listOf((hand.center.x - b.center.x) / b.width, (hand.center.y - b.center.y) / b.width)
                }
            }
            return SignFrame(hands, relative, scaled, raw, locations)
        }
    }
}

/** Жест словаря. */
@Serializable
data class CustomSign(
    val id: String = UUID.randomUUID().toString(),
    val word: String,
    /** Статичный жест: кадры позы. */
    val poses: List<SignFrame> = emptyList(),
    /** Сколько кадров позы в каждой записи, по порядку. */
    val poseCounts: List<Int>? = null,
    /** Жест с движением: каждая запись — последовательность кадров. */
    val motions: List<List<SignFrame>> = emptyList(),
    /** Сколько раз жест записывали. */
    val recordings: Int = 1,
) {
    val isDynamic: Boolean get() = motions.isNotEmpty()
    val handCount: Int get() = poses.firstOrNull()?.handCount ?: motions.firstOrNull()?.firstOrNull()?.handCount ?: 1

    /** Кадры позы, разбитые по записям. */
    val poseGroups: List<List<SignFrame>>
        get() {
            val counts = poseCounts
            if (counts == null || counts.sum() != poses.size) {
                return if (poses.isEmpty()) emptyList() else listOf(poses)
            }
            val groups = ArrayList<List<SignFrame>>()
            var start = 0
            for (count in counts) {
                if (count <= 0) continue
                groups.add(poses.subList(start, start + count))
                start += count
            }
            return groups
        }
}
