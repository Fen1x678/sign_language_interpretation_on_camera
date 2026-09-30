package com.fen1x.speech.core

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlin.math.max
import kotlin.math.min

/**
 * Словарь жестов и классификаторы:
 * • поза — k ближайших соседей (k-NN) по признакам формы кисти;
 * • жест с движением — DTW по последовательности кадров.
 * Жест левой руки сравнивается с записанным правой рукой в зеркальном виде.
 *
 * Защита от ложных срабатываний:
 * • порог сходства подбирается для каждого слова по разбросу его записей;
 * • общий множитель порогов задаёт ползунок «Чувствительность»;
 * • жест не засчитывается, если второй по сходству почти так же похож (неоднозначность);
 * • уже распознаваемый жест удерживается с чуть более мягким порогом («липкий» порог).
 *
 * Хранение (файл, настройки) — снаружи: [toJson] / [load] и [onChange].
 */
class SignLibrary {
    var signs: List<CustomSign> = emptyList()
        private set

    /** Чувствительность: больше — распознаёт увереннее, но чаще путает; меньше — строже. */
    var sensitivity: Double = 1.0

    /** Вызывается после каждого изменения словаря (сохранить файл, обновить экран). */
    var onChange: (() -> Unit)? = null

    val hasDynamicSigns: Boolean get() = signs.any { it.isDynamic }

    /** Сколько секунд последних кадров сравнивать с жестами с движением (зависит от длины записанных жестов). */
    var motionWindow: Double = 2.0
        private set

    private class Cache(
        /** Кадры поз (прорежены). */
        val poses: List<FrameFeatures>,
        val poseThreshold: Float,
        /** Записи с движением. */
        val motions: List<MotionTemplate>,
        val motionThreshold: Float,
    )

    private val cache = HashMap<String, Cache>()

    /** Самое похожее слово на последних сравнениях — для подсказки на экране. */
    data class Candidate(val word: String, val ratio: Float, val reason: String?)

    /**
     * Самое похожее слово, его расстояние относительно порога (меньше 1 — достаточно похоже)
     * и почему оно не засчитано (если отбраковано проверкой).
     */
    var lastCandidate: Candidate? = null
        private set

    private data class Scored(val sign: CustomSign, val ratio: Float)

    // MARK: Изменение словаря

    fun addPoses(word: String, frames: List<SignFrame>) {
        val i = indexOrCreate(word)
        val sign = signs[i]
        val cleaned = cleanPoses(frames)
        val counts = (sign.poseCounts ?: if (sign.poses.isEmpty()) emptyList() else listOf(sign.poses.size)) + cleaned.size
        replace(i, sign.copy(poses = sign.poses + cleaned, poseCounts = counts, recordings = sign.recordings + 1))
    }

    fun addMotion(word: String, frames: List<SignFrame>) {
        val i = indexOrCreate(word)
        val sign = signs[i]
        replace(i, sign.copy(motions = sign.motions + listOf(frames), recordings = sign.recordings + 1))
    }

    fun delete(id: String) {
        cache.remove(id)
        signs = signs.filter { it.id != id }
        updateMotionWindow()
        onChange?.invoke()
    }

    fun sign(id: String): CustomSign? = signs.firstOrNull { it.id == id }

    private fun replace(i: Int, sign: CustomSign) {
        signs = signs.toMutableList().also { it[i] = sign }
        rebuildCache(sign)
        onChange?.invoke()
    }

    private fun index(word: String): Int = signs.indexOfFirst { it.word.lowercase() == word.lowercase() }

    private fun indexOrCreate(word: String): Int {
        val i = index(word)
        if (i >= 0) return i
        signs = signs + CustomSign(word = word, recordings = 0)
        return signs.size - 1
    }

    /**
     * Чистка записанной позы: убираем кадры-выбросы (рука дёрнулась, точки найдены с ошибкой)
     * и оставляем не больше [POSES_PER_RECORDING] кадров.
     */
    private fun cleanPoses(frames: List<SignFrame>): List<SignFrame> {
        val features = frames.map { FrameFeatures.from(it) }
        if (features.size <= 2) return frames
        val medoid = medoid(features) ?: return frames
        val distances = features.map { FrameFeatures.shapeDistance(it, medoid) }
        val median = distances.sorted()[distances.size / 2]
        val maxDistance = max(median * 2.5f, 0.05f)
        val kept = frames.filterIndexed { i, _ -> distances[i] <= maxDistance }
        return SignMatching.evenlySpaced(kept, POSES_PER_RECORDING)
    }

    // MARK: Распознавание

    fun resetCandidate() {
        lastCandidate = null
    }

    private fun noteCandidate(word: String, ratio: Float, reason: String?) {
        if (!ratio.isFinite()) return
        val current = lastCandidate
        if (current != null && current.ratio <= ratio) return
        lastCandidate = Candidate(word, ratio, reason)
    }

    private fun noteCandidate(costs: List<Scored>) {
        val best = costs.minByOrNull { it.ratio } ?: return
        noteCandidate(best.sign.word, best.ratio, null)
    }

    /**
     * Поза. [variants] — поза всех рук в кадре и, если рук две, каждой руки отдельно:
     * так жест одной рукой узнаётся, даже если в кадре видна и вторая (опущенная) рука.
     * [sticky] — жест, который уже распознаётся: для него порог немного мягче,
     * чтобы распознавание не «мигало» от случайного дрожания руки.
     */
    fun classifyPose(variants: List<FrameFeatures>, sticky: String?): CustomSign? {
        val queries = variants.map { it to it.mirrored() }
        val scale = sensitivity.toFloat()
        val costs = ArrayList<Scored>()
        for (sign in signs) {
            val c = cache[sign.id] ?: continue
            if (c.poses.isEmpty()) continue
            val d = queries.minOfOrNull { poseCost(it.first, it.second, c.poses) } ?: Float.POSITIVE_INFINITY
            if (d.isFinite()) costs.add(Scored(sign, d / (c.poseThreshold * scale)))
        }
        noteCandidate(costs)
        return decide(costs, sticky)?.sign
    }

    /**
     * Лучший жест с движением, который заканчивается на последнем кадре потока.
     * [streams] — последние кадры всех рук и, если рук две, отдельно ведущей (движущейся) руки.
     * null — ни один жест не похож достаточно или выбор неоднозначен.
     */
    fun bestMotion(streams: List<MotionStream>): MotionSpotter.Match? {
        val usable = streams.filter { it.frames.size >= 4 }
        if (usable.isEmpty()) return null
        val scale = sensitivity.toFloat()
        val costs = ArrayList<Scored>()
        for (sign in signs) {
            val c = cache[sign.id] ?: continue
            if (c.motions.isEmpty()) continue
            val limit = c.motionThreshold * scale
            var best = Float.POSITIVE_INFINITY
            var rejected: Rejected? = null
            for (template in c.motions) {
                for (stream in usable) {
                    if (stream.handCount != template.handCount) continue
                    // Если жест заведомо не подходит, DTW прекращается досрочно.
                    val result = template.cost(stream, min(best, limit * 2))
                    best = min(best, result.cost)
                    val r = result.rejected
                    if (r != null && r.cost < (rejected?.cost ?: Float.POSITIVE_INFINITY)) rejected = r
                }
            }
            if (best.isFinite()) {
                costs.add(Scored(sign, best / limit))
            } else if (rejected != null) {
                noteCandidate(sign.word, rejected.cost / limit, rejected.reason.title)
            }
        }
        noteCandidate(costs)
        val best = decide(costs, null) ?: return null
        return MotionSpotter.Match(best.sign.id, best.ratio)
    }

    /**
     * Выбирает самый похожий жест, если он достаточно похож и явно лучше второго по сходству.
     * ratio — расстояние, делённое на порог слова: меньше 1 — жест подходит.
     */
    private fun decide(costs: List<Scored>, sticky: String?): Scored? {
        val sorted = costs.sortedBy { it.ratio }
        val best = sorted.firstOrNull() ?: return null
        val second = if (sorted.size > 1) sorted[1].ratio else Float.POSITIVE_INFINITY
        val ambiguity = SignMatching.AMBIGUITY_RATIO

        // «Липкий» порог: жест, который уже распознаётся, отпускаем не сразу.
        if (sticky != null) {
            val current = sorted.firstOrNull { it.sign.id == sticky }
            if (current != null && current.ratio < SignMatching.STICKY_FACTOR && current.ratio <= best.ratio * ambiguity) {
                return current
            }
        }
        if (best.ratio >= 1f) return null
        if (second < best.ratio * ambiguity) return null   // неоднозначно — не угадываем
        return best
    }

    // MARK: Проверка похожих слов при записи

    /** Другое слово словаря, с позой которого можно перепутать новую запись. */
    fun similarPose(frames: List<SignFrame>, excludingWord: String): CustomSign? {
        val features = frames.map { FrameFeatures.from(it) }
        val medoid = medoid(features) ?: return null
        val own = signs.getOrNull(index(excludingWord))?.id
        val mirrored = medoid.mirrored()
        return signs
            .filter { it.id != own }
            .mapNotNull { sign ->
                val c = cache[sign.id] ?: return@mapNotNull null
                if (c.poses.isEmpty()) return@mapNotNull null
                Scored(sign, poseCost(medoid, mirrored, c.poses) / c.poseThreshold)
            }
            .filter { it.ratio < 1f }
            .minByOrNull { it.ratio }?.sign
    }

    /** Другое слово словаря, с жестом которого можно перепутать новую запись с движением. */
    fun similarMotion(frames: List<SignFrame>, excludingWord: String): CustomSign? {
        val stream = MotionStream(frames.map { FrameFeatures.from(it) })
        val own = signs.getOrNull(index(excludingWord))?.id
        return signs
            .filter { it.id != own }
            .mapNotNull { sign ->
                val c = cache[sign.id] ?: return@mapNotNull null
                if (c.motions.isEmpty()) return@mapNotNull null
                val cost = c.motions.minOfOrNull { it.cost(stream).cost } ?: Float.POSITIVE_INFINITY
                Scored(sign, cost / c.motionThreshold)
            }
            .filter { it.ratio < 1f }
            .minByOrNull { it.ratio }?.sign
    }

    // MARK: Кэш признаков и пороги

    private fun rebuildCache(sign: CustomSign) {
        // Позы: из каждой записи берём поровну кадров, чтобы ни одна запись не «перевешивала».
        val groups = sign.poseGroups
        val perGroup = max(8, MAX_POSE_FRAMES / max(1, groups.size))
        val poseGroups = groups.map { group -> SignMatching.evenlySpaced(group, perGroup).map { FrameFeatures.from(it) } }
        val motions = sign.motions.mapNotNull { MotionTemplate.from(it) }
        cache[sign.id] = Cache(
            poses = poseGroups.flatten(),
            poseThreshold = poseThreshold(poseGroups),
            motions = motions,
            motionThreshold = motionThreshold(motions),
        )
        updateMotionWindow()
    }

    private fun updateMotionWindow() {
        val longest = cache.values.flatMap { it.motions }.maxOfOrNull { it.frames.size } ?: 0
        motionWindow = min(3.0, max(1.5, longest / SignMatching.SAMPLE_RATE + 0.8))
    }

    // MARK: Хранение

    fun toJson(): String = JSON.encodeToString(ListSerializer(CustomSign.serializer()), signs)

    /** Загрузка сохранённого словаря. Возвращает false, если файл повреждён. */
    fun load(json: String): Boolean {
        val saved = try {
            JSON.decodeFromString(ListSerializer(CustomSign.serializer()), json)
        } catch (e: Exception) {
            return false
        }
        signs = saved
        cache.clear()
        for (sign in signs) rebuildCache(sign)
        return true
    }

    companion object {
        /** Сколько кадров позы на слово брать для сравнения (остальные прореживаются). */
        private const val MAX_POSE_FRAMES = 60
        /** Сколько кадров позы сохранять из одной записи. */
        private const val POSES_PER_RECORDING = 20

        private val JSON = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        /** Самый «типичный» кадр: сумма расстояний до остальных минимальна. */
        private fun medoid(frames: List<FrameFeatures>): FrameFeatures? {
            var best: FrameFeatures? = null
            var bestSum = Float.POSITIVE_INFINITY
            for (a in frames) {
                var sum = 0f
                for (b in frames) {
                    val d = FrameFeatures.shapeDistance(a, b)
                    if (d.isFinite()) sum += d
                }
                if (sum < bestSum) {
                    bestSum = sum
                    best = a
                }
            }
            return best
        }

        /** Среднее расстояние до трёх ближайших кадров позы (в обычном или зеркальном виде). */
        private fun poseCost(live: FrameFeatures, mirrored: FrameFeatures, poses: List<FrameFeatures>): Float {
            val k = SignMatching.POSE_NEIGHBOURS
            val nearest = ArrayList<Float>(k + 1)
            for (pose in poses) {
                val d = min(FrameFeatures.shapeDistance(live, pose), FrameFeatures.shapeDistance(mirrored, pose))
                if (!d.isFinite()) continue
                if (nearest.size < k) {
                    nearest.add(d)
                    nearest.sort()
                } else if (d < nearest[k - 1]) {
                    nearest[k - 1] = d
                    nearest.sort()
                }
            }
            if (nearest.isEmpty()) return Float.POSITIVE_INFINITY
            return nearest.sum() / nearest.size
        }

        /**
         * Порог для позы. Если записей несколько, смотрим, насколько они отличаются друг от друга:
         * например, у разных людей жест выглядит по-разному, и порог нужен шире.
         */
        private fun poseThreshold(groups: List<List<FrameFeatures>>): Float {
            val base = SignMatching.BASE_POSE_THRESHOLD
            if (groups.size < 2) return base
            val gaps = ArrayList<Float>()
            groups.forEachIndexed { g, group ->
                val others = groups.filterIndexed { i, _ -> i != g }.flatten()
                for (frame in group) {
                    val mirrored = frame.mirrored()
                    val nearest = others.minOfOrNull {
                        min(FrameFeatures.shapeDistance(frame, it), FrameFeatures.shapeDistance(mirrored, it))
                    } ?: Float.POSITIVE_INFINITY
                    if (nearest.isFinite()) gaps.add(nearest)
                }
            }
            if (gaps.isEmpty()) return base
            val spread = gaps.sorted()[gaps.size / 2]
            return min(max(base, spread * 1.5f), base * SignMatching.MAX_THRESHOLD_GROWTH)
        }

        /** Порог для жеста с движением: по тому, насколько отличаются между собой записи одного слова. */
        private fun motionThreshold(templates: List<MotionTemplate>): Float {
            val base = SignMatching.BASE_MOTION_THRESHOLD
            if (templates.size < 2) return base
            val costs = ArrayList<Float>()
            templates.forEachIndexed { i, a ->
                templates.forEachIndexed { j, b ->
                    if (i != j) {
                        val c = a.cost(MotionStream(b.frames)).cost
                        if (c.isFinite()) costs.add(c)
                    }
                }
            }
            if (costs.isEmpty()) return base
            val mean = costs.sum() / costs.size
            return min(max(base, mean * 1.3f), base * SignMatching.MAX_THRESHOLD_GROWTH)
        }
    }
}
