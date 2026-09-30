package com.fen1x.speech.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

// MARK: - Признаки, одинаковые для разных людей

/**
 * Признаки кадра, почти не зависящие от размера руки, длины пальцев и расстояния до камеры.
 *
 * На каждую руку 33 числа:
 * • 15 углов сгиба суставов (по 3 на палец);
 * • 4 угла между соседними пальцами (насколько пальцы разведены);
 * • 4 расстояния от кончика большого пальца до кончиков остальных (кольца, щепоти);
 * • 5 «вытянутостей» пальцев — расстояние от запястья до кончика;
 * • сторона ладони (к камере ладонью или тыльной стороной) — с учётом того, правая это рука или левая;
 * • направление кисти (куда «смотрят» пальцы), 2 числа;
 * • где рука относительно плеч, 2 числа: у подбородка, у груди, у плеча — это разные жесты.
 *   Если плечи не видны на одном из сравниваемых кадров, этот признак не учитывается.
 * Для двух рук добавляется положение правой руки относительно левой.
 *
 * У каждого признака есть вес. Если точки видны плохо, признак учитывается слабее;
 * если кость направлена в камеру и угол измерить нельзя — не учитывается совсем.
 */
class FrameFeatures private constructor(
    /** Признаки рук (слева направо) и, для двух рук, их взаимное положение. */
    val values: FloatArray,
    /** Вес каждого признака с учётом того, насколько уверенно видны точки (0 — не учитывать). */
    val weights: FloatArray,
    val handCount: Int,
    /** Какая это рука (для каждой руки): +1 правая, −1 левая, 0 — неизвестно. */
    val chirality: IntArray,
    /** Направление движения ведущей руки (2 числа, от −1 до 1). Пусто для позы. */
    val motion: FloatArray,
) {
    /** Зеркальное отражение: жест левой руки ↔ тот же жест правой рукой. */
    fun mirrored(): FrameFeatures {
        val v = values.copyOf()
        val w = weights.copyOf()
        val n = HAND_LENGTH
        if (handCount == 2 && values.size >= 2 * n) {
            // Левая и правая руки меняются местами.
            values.copyInto(v, destinationOffset = 0, startIndex = n, endIndex = 2 * n)
            values.copyInto(v, destinationOffset = n, startIndex = 0, endIndex = n)
            weights.copyInto(w, destinationOffset = 0, startIndex = n, endIndex = 2 * n)
            weights.copyInto(w, destinationOffset = n, startIndex = 0, endIndex = n)
            if (values.size == 2 * n + 2) v[2 * n + 1] = -values[2 * n + 1]
        }
        for (h in 0 until handCount) {
            if ((h + 1) * n > v.size) continue
            v[h * n + ORIENT_X] = -v[h * n + ORIENT_X]
            v[h * n + LOCATION_X] = -v[h * n + LOCATION_X]
        }
        val c = IntArray(chirality.size) { -chirality[chirality.size - 1 - it] }
        val m = if (motion.size == 2) floatArrayOf(-motion[0], motion[1]) else motion
        return FrameFeatures(v, w, handCount, c, m)
    }

    /** Какая рука показывает жест: +1 правая, −1 левая, 0 — неизвестно или две руки. */
    val mainChirality: Int get() = if (handCount == 1) chirality[0] else 0

    /** Скорость ведущей руки, ладоней в секунду. */
    val speed: Float
        get() {
            if (motion.size != 2) return 0f
            val r = min(0.999f, sqrt(motion[0] * motion[0] + motion[1] * motion[1]))
            return SignMatching.REFERENCE_SPEED * r / sqrt(1 - r * r)
        }

    companion object {
        const val HAND_LENGTH = 33
        const val ORIENT_X = 29
        const val LOCATION_X = 31

        val handWeights: FloatArray = run {
            val w = ArrayList<Float>()
            w += listOf(0.18f, 0.3f, 0.15f)                      // большой палец: CMC, MP, IP
            repeat(4) { w += listOf(0.3f, 0.3f, 0.15f) }         // остальные: MCP, PIP, DIP
            w += listOf(1.05f, 1.5f, 1.5f, 1.5f)                 // разведение пальцев
            w += listOf(1.5f, 1.5f, 1.5f, 1.5f)                  // большой палец → кончики
            w += listOf(1.5f, 1.5f, 1.5f, 1.5f, 1.5f)            // вытянутость пальцев
            // Сторона ладони — с маленьким весом: одна ошибка нейросети с тем, какая это рука,
            // не должна ломать распознавание.
            w += listOf(0.03f)                                   // сторона ладони
            w += listOf(0.6f, 0.6f)                              // направление кисти
            w += listOf(1.5f, 1.5f)                              // положение относительно плеч
            w.toFloatArray()
        }

        fun from(frame: SignFrame): FrameFeatures {
            val values = ArrayList<Float>(HAND_LENGTH * 2 + 2)
            val weights = ArrayList<Float>(HAND_LENGTH * 2 + 2)
            val locations = frame.locations?.takeIf { it.size == 2 * frame.hands.size }
            frame.hands.forEachIndexed { h, hand ->
                val (v, r) = handFeatures(hand)
                if (locations != null) {
                    v += min(max(locations[2 * h] / 1.5f, -1f), 1f)
                    v += min(max(locations[2 * h + 1] / 1.5f, -1f), 1f)
                    r += 1f
                    r += 1f
                } else {
                    v += 0f
                    v += 0f
                    r += 0f
                    r += 0f
                }
                values += v
                for (i in r.indices) weights += handWeights[i] * r[i]
            }
            if (frame.hands.size == 2 && frame.relative.size == 2) {
                for (x in frame.relative) values += min(max(x / 4f, -1.5f), 1.5f)
                weights += 1f
                weights += 1f
            }
            return FrameFeatures(
                values.toFloatArray(),
                weights.toFloatArray(),
                frame.hands.size,
                frame.hands.map { it.chirality ?: 0 }.toIntArray(),
                motionFeatures(frame),
            )
        }

        // MARK: Расстояния

        /**
         * Насколько непохожи позы рук: взвешенное среднеквадратичное отличие признаков (0 — одинаковые).
         * Позы с разным числом рук не сравниваются — расстояние бесконечно.
         */
        fun shapeDistance(a: FrameFeatures, b: FrameFeatures): Float {
            val n = a.values.size
            if (a.handCount != b.handCount || n != b.values.size || n == 0) return Float.POSITIVE_INFINITY
            var num = 0f
            var den = 0f
            val av = a.values
            val bv = b.values
            val aw = a.weights
            val bw = b.weights
            for (i in 0 until n) {
                val w = min(aw[i], bw[i])
                if (w <= 0f) continue
                val d = av[i] - bv[i]
                num += w * d * d
                den += w
            }
            return if (den > 0f) sqrt(num / den) else Float.POSITIVE_INFINITY
        }

        /**
         * Отличие только формы кистей — без положения относительно плеч и между руками.
         * Для «активности»: перемещение руки — это движение, а не смена формы.
         */
        fun handShapeDistance(a: FrameFeatures, b: FrameFeatures): Float {
            val n = min(a.values.size, a.handCount * HAND_LENGTH)
            if (a.handCount != b.handCount || a.values.size != b.values.size || n <= 0) return Float.POSITIVE_INFINITY
            var num = 0f
            var den = 0f
            for (i in 0 until n) {
                if (i % HAND_LENGTH >= LOCATION_X) continue
                val w = min(a.weights[i], b.weights[i])
                if (w <= 0f) continue
                val d = a.values[i] - b.values[i]
                num += w * d * d
                den += w
            }
            return if (den > 0f) sqrt(num / den) else Float.POSITIVE_INFINITY
        }

        /** Расстояние между кадрами жеста с движением: форма рук и направление движения. */
        fun distance(a: FrameFeatures, b: FrameFeatures): Float {
            if (a.handCount != b.handCount || a.motion.size != 2 || b.motion.size != 2) {
                return SignMatching.MISMATCH_PENALTY
            }
            val shape = shapeDistance(a, b)
            val dx = a.motion[0] - b.motion[0]
            val dy = a.motion[1] - b.motion[1]
            val motion = sqrt((dx * dx + dy * dy) / 2)
            val share = SignMatching.MOTION_SHARE
            return (1 - share) * (if (shape.isFinite()) shape else SignMatching.MISMATCH_PENALTY) + share * motion
        }

        // MARK: Вычисление признаков

        private val CHAINS = arrayOf(
            intArrayOf(0, 1, 2, 3, 4),       // большой
            intArrayOf(0, 5, 6, 7, 8),       // указательный
            intArrayOf(0, 9, 10, 11, 12),    // средний
            intArrayOf(0, 13, 14, 15, 16),   // безымянный
            intArrayOf(0, 17, 18, 19, 20),   // мизинец
        )

        /** Кость короче этой доли ладони смотрит в камеру: угол при ней не измеряем. */
        private const val MIN_BONE = 0.12f

        /** Угол между векторами, 0…1 (0 — одно направление, 1 — противоположные). */
        private fun angle(a: Pt, b: Pt): Float =
            (atan2(abs(a.x * b.y - a.y * b.x).toDouble(), (a.x * b.x + a.y * b.y).toDouble()) / PI).toFloat()

        /** Признаки одной кисти и их надёжность (0…1). */
        private fun handFeatures(pose: HandPose): Pair<ArrayList<Float>, ArrayList<Float>> {
            fun pt(i: Int) = Pt(pose.points[2 * i], pose.points[2 * i + 1])
            fun seen(vararg joints: Int): Float = joints.minOf { pose.weight(it) }

            val v = ArrayList<Float>(HAND_LENGTH)
            val r = ArrayList<Float>(HAND_LENGTH)
            val size = max(1e-4f, (pt(9) - pt(0)).length)

            // 1. Сгиб суставов: угол между соседними костями пальца.
            for (chain in CHAINS) {
                for (k in 1..3) {
                    val a = pt(chain[k]) - pt(chain[k - 1])
                    val b = pt(chain[k + 1]) - pt(chain[k])
                    if (a.length < MIN_BONE * size || b.length < MIN_BONE * size) {
                        v += 0f
                        r += 0f
                    } else {
                        v += angle(a, b)
                        r += seen(chain[k - 1], chain[k], chain[k + 1])
                    }
                }
            }

            // 2. Разведение пальцев: угол между направлениями соседних пальцев.
            //    У согнутого пальца направление не определено — признак не учитываем.
            val axes: List<Pt?> = CHAINS.map { chain ->
                val d = pt(chain[4]) - pt(chain[1])
                if (d.length >= 0.3f * size) d else null
            }
            for (i in 0 until 4) {
                val a = axes[i]
                val b = axes[i + 1]
                if (a != null && b != null) {
                    v += angle(a, b)
                    r += seen(CHAINS[i][1], CHAINS[i][4], CHAINS[i + 1][1], CHAINS[i + 1][4])
                } else {
                    v += 0f
                    r += 0f
                }
            }

            // 3. Расстояния от кончика большого пальца до остальных кончиков.
            for (tip in intArrayOf(8, 12, 16, 20)) {
                v += min((pt(4) - pt(tip)).length / size, 1.5f) / 1.5f
                r += seen(4, tip)
            }

            // 4. Вытянутость пальцев: расстояние от запястья до кончика.
            for (tip in intArrayOf(4, 8, 12, 16, 20)) {
                v += min((pt(tip) - pt(0)).length / size, 2.5f) / 2.5f
                r += seen(0, tip)
            }

            // 5. Ладонь или тыльная сторона. Без знания, какая это рука, признак бессмыслен.
            val a = pt(5) - pt(0)
            val b = pt(17) - pt(0)
            val side = min(max((a.x * b.y - a.y * b.x) / (size * size) / 0.25f, -1f), 1f)
            val chirality = pose.chirality ?: 0
            if (chirality != 0) {
                v += side * chirality
                r += seen(0, 5, 17)
            } else {
                v += 0f
                r += 0f
            }

            // 6. Направление кисти: запястье → основание среднего пальца.
            val d = (pt(9) - pt(0)) / size
            v += d.x
            v += d.y
            r += seen(0, 9)
            r += seen(0, 9)
            return Pair(v, r)
        }

        /**
         * Направление движения: скорость v (ладоней в секунду), сжатая как v / √(|v|² + v₀²).
         * Важнее направление, чем скорость: жест, показанный быстрее или медленнее, остаётся похожим.
         */
        private fun motionFeatures(frame: SignFrame): FloatArray {
            val raw = frame.rawVelocity
            var v: Pt = when {
                raw != null && raw.size == 2 -> Pt(raw[0], raw[1])
                frame.velocity.size == 2 -> {
                    val u = Pt(frame.velocity[0], frame.velocity[1])
                    if (u.length < 0.999f) u * SignMatching.REFERENCE_SPEED else u * 3f
                }
                else -> return FloatArray(0)
            }
            val ref = SignMatching.REFERENCE_SPEED
            val k = 1f / sqrt(v.length * v.length + ref * ref)
            v *= k
            return floatArrayOf(v.x, v.y)
        }
    }
}

// MARK: - Движение и DTW

data class Activity(val speed: FloatArray, val shape: FloatArray)

data class DtwResult(val cost: Float, val start: Int)

object SignMatching {
    /** Базовые пороги сходства (для слова с одной записью, при средней чувствительности). */
    const val BASE_POSE_THRESHOLD = 0.12f
    const val BASE_MOTION_THRESHOLD = 0.13f
    /**
     * Во сколько раз дороже зеркальный вариант, если известно, что жест показан той же рукой, что записан
     * (и наоборот). Не запрет, а штраф: если нейросеть ошиблась с рукой, жест всё равно узнаётся.
     */
    const val WRONG_HAND_PENALTY = 1.25f
    /** Порог для слова не больше базового × это число, даже если записи сильно разные. */
    const val MAX_THRESHOLD_GROWTH = 1.6f
    /** Если второе по сходству слово похоже почти так же (в пределах этого множителя), жест не засчитывается. */
    const val AMBIGUITY_RATIO = 1.1f
    /** Во сколько раз мягче порог для жеста, который уже распознаётся. */
    const val STICKY_FACTOR = 1.3f
    /** Сколько ближайших кадров позы усредняется (k в k-NN). */
    const val POSE_NEIGHBOURS = 3

    /** Частота кадров последовательностей (записанных и текущих), кадров в секунду. */
    const val SAMPLE_RATE = 15.0
    /** Скорость (ладоней в секунду), при которой признак движения равен ~0,7. */
    const val REFERENCE_SPEED = 1.5f
    /** Доля движения в расстоянии между кадрами (остальное — форма рук). */
    const val MOTION_SHARE = 0.4f
    /** Расстояние между кадрами с разным числом рук. */
    const val MISMATCH_PENALTY = 0.6f
    /** Во сколько раз дешевле кадр, когда жест показан медленнее записанного. */
    const val SLOW_STEP_WEIGHT = 0.5f
    /** Не длиннее 2,4 с. */
    const val MAX_TEMPLATE_LENGTH = 36
    /** Порог «активности» кадра: рука движется или меняет форму. */
    const val ACTIVE_THRESHOLD = 0.6f

    /**
     * Элементы с равным шагом по времени ([SAMPLE_RATE]), последний — самый свежий.
     * Так последовательность не зависит от того, сколько кадров в секунду выдаёт камера.
     */
    fun <T> resample(items: List<Timed<T>>): List<T> {
        if (items.isEmpty()) return emptyList()
        val first = items.first()
        val last = items.last()
        val count = ((last.time - first.time) * SAMPLE_RATE).toInt() + 1
        val result = ArrayList<T>(count)
        var j = items.size - 1
        for (k in 0 until count) {
            val t = last.time - k / SAMPLE_RATE
            while (j > 0 && abs(items[j - 1].time - t) <= abs(items[j].time - t)) {
                j -= 1
            }
            result.add(items[j].item)
        }
        result.reverse()
        return result
    }

    /** [count] элементов, равномерно выбранных из списка. */
    fun <T> evenlySpaced(items: List<T>, count: Int): List<T> {
        if (items.size <= count || count <= 1) return items
        val step = (items.size - 1).toDouble() / (count - 1)
        return (0 until count).map { items[(it * step).roundToInt()] }
    }

    /**
     * «Активность» каждого кадра: скорость руки и скорость изменения формы кисти.
     * Нужна, чтобы неподвижная рука не принималась за жест с движением.
     */
    fun activity(sequence: List<FrameFeatures>): Activity {
        val speed = FloatArray(sequence.size)
        val shape = FloatArray(sequence.size)
        for (i in sequence.indices) {
            speed[i] = sequence[i].speed
            val j = max(0, i - 2)
            var rate = 0f
            if (i > j) {
                val d = FrameFeatures.handShapeDistance(sequence[i], sequence[j])
                if (d.isFinite()) rate = d * SAMPLE_RATE.toFloat() / (i - j)
            }
            // Меньше 0,25 в секунду — дрожание точек, а не смена формы.
            shape[i] = 3 * max(0f, rate - 0.25f)
        }
        return Activity(speed, shape)
    }

    /**
     * Подготовка записанного жеста: равный шаг по времени, обрезка неподвижных кадров
     * в начале и в конце, ограничение длины.
     */
    fun prepareTemplate(frames: List<Timed<SignFrame>>): List<SignFrame> {
        var sequence = resample(frames)
        val act = activity(sequence.map { FrameFeatures.from(it) })
        val active = sequence.indices.filter { act.speed[it] + act.shape[it] > ACTIVE_THRESHOLD }
        if (active.size >= 3) {
            val first = active.first()
            val last = active.last()
            sequence = sequence.subList(max(0, first - 2), min(sequence.size - 1, last + 1) + 1)
        }
        return evenlySpaced(sequence, MAX_TEMPLATE_LENGTH)
    }

    /** В записанном жесте почти не было движения и смены формы. */
    fun isMostlyStill(frames: List<SignFrame>): Boolean {
        val act = activity(frames.map { FrameFeatures.from(it) })
        return act.speed.indices.count { act.speed[it] + act.shape[it] > ACTIVE_THRESHOLD } < 3
    }

    /** Какая рука показывает жест: +1 правая, −1 левая, 0 — неизвестно или две руки. */
    fun chirality(frames: List<FrameFeatures>): Int {
        val values = frames.filter { it.handCount == 1 }.map { it.mainChirality.toFloat() }
        if (values.isEmpty()) return 0
        val mean = values.sum() / values.size
        return when {
            mean > 0.5f -> 1
            mean < -0.5f -> -1
            else -> 0
        }
    }

    /**
     * DTW (динамическая трансформация временной шкалы) с открытым началом:
     * насколько конец потока кадров похож на шаблон жеста, с учётом разной скорости показа.
     * Возвращает среднюю стоимость на кадр шаблона (меньше — похоже сильнее) и номер кадра потока,
     * с которого начинается найденный жест. [abandonAbove] — если результат заведомо хуже,
     * расчёт прекращается досрочно (ускорение).
     */
    fun subsequenceDTW(
        t: List<FrameFeatures>,
        s: List<FrameFeatures>,
        abandonAbove: Float = Float.POSITIVE_INFINITY,
    ): DtwResult {
        val n = t.size
        val m = s.size
        if (n <= 1 || m <= 1) return DtwResult(Float.POSITIVE_INFINITY, 0)
        val limit = abandonAbove * n
        var prev = FloatArray(m)
        var cur = FloatArray(m)
        var prevStart = IntArray(m) { it }   // жест может начаться на любом кадре потока
        var curStart = IntArray(m)
        for (j in 0 until m) prev[j] = FrameFeatures.distance(t[0], s[j])
        for (i in 1 until n) {
            cur[0] = prev[0] + FrameFeatures.distance(t[i], s[0])
            curStart[0] = prevStart[0]
            var rowMin = cur[0]
            for (j in 1 until m) {
                val d = FrameFeatures.distance(t[i], s[j])
                val faster = prev[j] + d                          // шаблон идёт дальше, поток стоит
                val same = prev[j - 1] + d                        // оба идут дальше
                val slower = cur[j - 1] + SLOW_STEP_WEIGHT * d    // поток идёт дальше, шаблон стоит
                if (faster <= same && faster <= slower) {
                    cur[j] = faster
                    curStart[j] = prevStart[j]
                } else if (same <= slower) {
                    cur[j] = same
                    curStart[j] = prevStart[j - 1]
                } else {
                    cur[j] = slower
                    curStart[j] = curStart[j - 1]
                }
                if (cur[j] < rowMin) rowMin = cur[j]
            }
            if (rowMin > limit) return DtwResult(Float.POSITIVE_INFINITY, 0)   // дальше будет только хуже
            val tmp = prev
            prev = cur
            cur = tmp
            val tmpStart = prevStart
            prevStart = curStart
            curStart = tmpStart
        }
        // Жест должен закончиться на последнем кадре потока.
        return DtwResult(prev[m - 1] / n, prevStart[m - 1])
    }
}

// MARK: - Шаблон и поток для жестов с движением

/** Почему похожий жест с движением не засчитан (для подсказки на экране). */
enum class MotionRejection(val title: String) {
    /** Показан больше чем в 2 раза быстрее записанного — скорее всего, это кусок другого жеста. */
    TOO_FAST("слишком быстро"),
    /** Рука почти не двигалась, а в записанном жесте двигалась. */
    TOO_STILL("мало движения"),
    /** Форма кисти не менялась, а в записанном жесте менялась. */
    NO_SHAPE_CHANGE("кисть не меняет форму"),
}

data class Rejected(val cost: Float, val reason: MotionRejection)

/** Результат сравнения шаблона с потоком кадров. */
data class MotionCost(
    /** Стоимость DTW (меньше — похоже сильнее); бесконечность — не подходит. */
    val cost: Float = Float.POSITIVE_INFINITY,
    /** Самый похожий вариант, отбракованный проверками, и причина — для подсказки. */
    val rejected: Rejected? = null,
)

/** Последние кадры, подготовленные для сравнения со всеми шаблонами. */
class MotionStream(val frames: List<FrameFeatures>) {
    val mirrored: List<FrameFeatures> = frames.map { it.mirrored() }
    val speed: FloatArray
    val shape: FloatArray
    val chirality: Int = SignMatching.chirality(frames)
    val handCount: Int = frames.lastOrNull()?.handCount ?: 0

    init {
        val act = SignMatching.activity(frames)
        speed = act.speed
        shape = act.shape
    }
}

/** Записанный жест с движением, подготовленный для сравнения. */
class MotionTemplate private constructor(val frames: List<FrameFeatures>) {
    val handCount: Int = frames[frames.size - 1].handCount
    /** Средняя скорость руки (ладоней в секунду). */
    val speedActivity: Float
    /** Средняя скорость изменения формы кисти. */
    val shapeActivity: Float
    /** Какой рукой записан: +1 правая, −1 левая, 0 — неизвестно или две руки. */
    val chirality: Int = SignMatching.chirality(frames)

    init {
        val act = SignMatching.activity(frames)
        speedActivity = act.speed.sum() / frames.size
        shapeActivity = act.shape.sum() / frames.size
    }

    /**
     * Стоимость DTW шаблона на конце потока с дополнительными проверками:
     * • жест показан не больше чем в 2 раза быстрее записанного;
     * • в найденном отрезке есть движение (или смена формы — для жестов почти без перемещения руки),
     *   как в шаблоне: неподвижная рука не должна совпадать с жестом с движением.
     */
    fun cost(stream: MotionStream, abandonAbove: Float = Float.POSITIVE_INFINITY): MotionCost {
        var cost = Float.POSITIVE_INFINITY
        var rejected: Rejected? = null
        if (stream.handCount != handCount) return MotionCost()
        // Если известно, какой рукой записан и показан жест, «неподходящий» вариант (обычный или зеркальный)
        // дороже: так жесты «влево» и «вправо» не путаются, а ошибка нейросети с рукой не ломает распознавание.
        val known = chirality != 0 && stream.chirality != 0
        val same = chirality == stream.chirality
        val penalty = SignMatching.WRONG_HAND_PENALTY
        val candidates: List<Pair<List<FrameFeatures>, Float>> = when {
            !known -> listOf(stream.frames to 1f, stream.mirrored to 1f)
            same -> listOf(stream.frames to 1f, stream.mirrored to penalty)
            else -> listOf(stream.mirrored to 1f, stream.frames to penalty)
        }
        for ((candidate, extra) in candidates) {
            val dtw = SignMatching.subsequenceDTW(frames, candidate, min(cost, abandonAbove) / extra)
            val c = dtw.cost * extra
            if (!c.isFinite() || c >= cost) continue
            val reason = rejection(dtw.start, candidate.size, stream)
            if (reason != null) {
                if (c < (rejected?.cost ?: Float.POSITIVE_INFINITY)) rejected = Rejected(c, reason)
                continue
            }
            cost = c
        }
        return MotionCost(cost, rejected)
    }

    private fun rejection(start: Int, streamCount: Int, stream: MotionStream): MotionRejection? {
        val segment = streamCount - start
        if (segment < 0.5f * frames.size) return MotionRejection.TOO_FAST
        var speed = 0f
        var shape = 0f
        for (i in start until streamCount) {
            speed += stream.speed[i]
            shape += stream.shape[i]
        }
        speed /= segment
        shape /= segment
        if (speedActivity > 0.5f && speed < 0.3f * speedActivity) return MotionRejection.TOO_STILL
        // Смену формы проверяем только у жестов, где рука почти не перемещается
        // (у быстрых жестов «форма» дрожит от смазанного кадра и сравнивать её ненадёжно).
        if (speedActivity < 1.0f && shapeActivity > 0.3f && shape < 0.4f * shapeActivity) {
            return MotionRejection.NO_SHAPE_CHANGE
        }
        return null
    }

    companion object {
        fun from(frames: List<SignFrame>): MotionTemplate? {
            if (frames.size < 2) return null
            return MotionTemplate(frames.map { FrameFeatures.from(it) })
        }
    }
}

/**
 * Выбор момента, когда засчитать жест с движением.
 *
 * Когда жест только заканчивается, сходство с шаблоном ещё растёт несколько кадров.
 * Поэтому жест засчитывается не сразу, а когда сходство перестало расти
 * (или жест закончился, или прошло [maxWait] секунд). Так точнее выбирается слово.
 */
class MotionSpotter(var maxWait: Double = 0.3) {
    data class Match(
        val id: String,
        /** Стоимость относительно порога слова: меньше 1 — жест подходит. */
        val cost: Float,
    )

    private data class Pending(val id: String, val cost: Float, val since: Double)

    private var pending: Pending? = null

    fun reset() {
        pending = null
    }

    /**
     * [best] — лучший подходящий жест на этом кадре (null — ни один не подходит).
     * Возвращает жест, который нужно засчитать сейчас.
     */
    fun update(best: Match?, time: Double): String? {
        val current = pending
        if (current == null) {
            if (best != null) pending = Pending(best.id, best.cost, time)
            return null
        }
        if (best == null) {
            pending = null
            return current.id   // жест закончился
        }
        if (best.id == current.id) {
            if (best.cost > current.cost) {
                pending = null
                return current.id   // сходство перестало расти
            }
            pending = Pending(current.id, best.cost, current.since)
        } else if (best.cost < current.cost) {
            pending = Pending(best.id, best.cost, time)   // другое слово подходит лучше
        }
        val waiting = pending
        if (waiting != null && time - waiting.since >= maxWait) {
            pending = null
            return waiting.id
        }
        return null
    }
}
