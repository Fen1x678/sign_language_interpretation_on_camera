import SwiftUI
import Combine

// MARK: - Сырые данные жеста (хранятся в словаре)

/// Поза одной руки: 21 точка относительно запястья, в размерах ладони (x0, y0, x1, y1, … — 42 числа).
/// Хранятся именно точки, а не готовые признаки: если алгоритм сравнения улучшится,
/// записанный словарь останется рабочим.
struct HandPose: Codable, Equatable {
    var points: [Float]
}

/// Один кадр жеста: одна или две руки, их взаимное положение и движение.
struct SignFrame: Codable, Equatable {
    /// Руки слева направо (как на экране).
    var hands: [HandPose]
    /// Положение второй руки относительно первой [dx, dy] в размерах ладони. Пусто для одной руки.
    var relative: [Float]
    /// Скорость ведущей руки [vx, vy], приведённая к диапазону −1…1. Пусто для позы.
    var velocity: [Float]

    var handCount: Int { hands.count }

    /// Кадр из найденных рук. Рука учитывается, только если видны все 21 точка.
    static func make(from geometries: [HandGeometry], velocity: CGVector? = nil) -> SignFrame? {
        let complete = geometries.filter { g in g.p.allSatisfy { $0.x >= 0 } }
        guard !complete.isEmpty else { return nil }
        // Две самые крупные (ближние) руки, слева направо.
        let chosen = Array(complete.sorted { $0.size > $1.size }.prefix(2))
            .sorted { $0.center.x < $1.center.x }

        let hands = chosen.map { g -> HandPose in
            let origin = g.p[Joint.wrist]
            var pts: [Float] = []
            pts.reserveCapacity(Joint.count * 2)
            for point in g.p {
                pts.append(Float((point.x - origin.x) / g.size))
                pts.append(Float((point.y - origin.y) / g.size))
            }
            return HandPose(points: pts)
        }

        var relative: [Float] = []
        if chosen.count == 2 {
            let scale = (chosen[0].size + chosen[1].size) / 2
            relative = [Float((chosen[1].center.x - chosen[0].center.x) / scale),
                        Float((chosen[1].center.y - chosen[0].center.y) / scale)]
        }
        let v: [Float] = velocity.map { [Float($0.dx), Float($0.dy)] } ?? []
        return SignFrame(hands: hands, relative: relative, velocity: v)
    }

    /// Зеркальное отражение по горизонтали: жест левой руки ↔ тот же жест правой рукой.
    func mirrored() -> SignFrame {
        let flipped = hands.map { hand in
            HandPose(points: hand.points.enumerated().map { $0.offset % 2 == 0 ? -$0.element : $0.element })
        }
        return SignFrame(
            hands: Array(flipped.reversed()),
            relative: relative.count == 2 ? [relative[0], -relative[1]] : relative,
            velocity: velocity.count == 2 ? [-velocity[0], velocity[1]] : velocity
        )
    }
}

// MARK: - Признаки, одинаковые для разных людей

/// Признаки кадра, почти не зависящие от размера руки, длины пальцев и расстояния до камеры.
///
/// На каждую руку 24 числа:
/// • 15 углов сгиба суставов (по 3 на палец) — главное, чем отличаются жесты;
/// • 4 угла между соседними пальцами (насколько пальцы разведены);
/// • 4 расстояния от кончика большого пальца до кончиков остальных (кольца, щепоти);
/// • 1 признак: к камере ладонь или тыльная сторона.
/// Отдельно — направление кисти (куда «смотрят» пальцы).
struct FrameFeatures {
    var shapes: [[Float]]
    var orients: [[Float]]
    var relative: [Float]
    var velocity: [Float]

    init(_ frame: SignFrame) {
        shapes = frame.hands.map { FrameFeatures.shape(of: $0) }
        orients = frame.hands.map { FrameFeatures.orientation(of: $0) }
        relative = frame.relative
        velocity = frame.velocity
    }

    private static let chains: [[Int]] = [
        [0, 1, 2, 3, 4],       // большой
        [0, 5, 6, 7, 8],       // указательный
        [0, 9, 10, 11, 12],    // средний
        [0, 13, 14, 15, 16],   // безымянный
        [0, 17, 18, 19, 20]    // мизинец
    ]

    private static func point(_ pose: HandPose, _ i: Int) -> SIMD2<Float> {
        SIMD2(pose.points[2 * i], pose.points[2 * i + 1])
    }

    private static func length(_ v: SIMD2<Float>) -> Float {
        (v.x * v.x + v.y * v.y).squareRoot()
    }

    /// Угол между векторами, 0…1 (0 — одно направление, 1 — противоположные).
    private static func angle(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let la = length(a), lb = length(b)
        guard la > 1e-4, lb > 1e-4 else { return 0 }
        let c = max(-1, min(1, (a.x * b.x + a.y * b.y) / (la * lb)))
        return acos(c) / Float.pi
    }

    static func shape(of pose: HandPose) -> [Float] {
        func pt(_ i: Int) -> SIMD2<Float> { point(pose, i) }
        var f: [Float] = []
        f.reserveCapacity(24)

        // Сгиб суставов: угол между соседними костями пальца.
        for chain in chains {
            for k in 1...3 {
                f.append(angle(pt(chain[k]) - pt(chain[k - 1]), pt(chain[k + 1]) - pt(chain[k])))
            }
        }
        // Разведение пальцев.
        let directions = chains.map { pt($0[4]) - pt($0[1]) }
        for i in 0..<4 {
            f.append(angle(directions[i], directions[i + 1]))
        }
        // Расстояния от кончика большого пальца до остальных кончиков.
        for tip in [8, 12, 16, 20] {
            f.append(min(1, length(pt(4) - pt(tip)) / 2))
        }
        // Ладонь или тыльная сторона (знак векторного произведения).
        let a = pt(5) - pt(0), b = pt(17) - pt(0)
        let cross = a.x * b.y - a.y * b.x
        f.append(cross / max(1e-4, length(a) * length(b)) / 2)
        return f
    }

    static func orientation(of pose: HandPose) -> [Float] {
        let d = point(pose, 9) - point(pose, 0)
        let l = max(1e-4, length(d))
        return [d.x / l, d.y / l]
    }

    private static func handDistance(_ a: [Float], _ oa: [Float], _ b: [Float], _ ob: [Float]) -> Float {
        func meanAbs(_ range: Range<Int>) -> Float {
            var s: Float = 0
            for i in range { s += abs(a[i] - b[i]) }
            return s / Float(range.count)
        }
        let flex = meanAbs(0..<15)
        let spread = meanAbs(15..<19)
        let tips = meanAbs(19..<23)
        let palm = abs(a[23] - b[23])
        let dx = oa[0] - ob[0], dy = oa[1] - ob[1]
        let orient = (dx * dx + dy * dy).squareRoot() / 2
        return (1.0 * flex + 0.6 * spread + 0.8 * tips + 0.3 * palm + 0.5 * orient) / 3.2
    }

    /// Насколько два кадра непохожи: 0 — одинаковые, 1 — совсем разные.
    static func distance(_ a: FrameFeatures, _ b: FrameFeatures) -> Float {
        guard a.shapes.count == b.shapes.count, !a.shapes.isEmpty else { return 1 }
        var d: Float = 0
        for i in a.shapes.indices {
            d += handDistance(a.shapes[i], a.orients[i], b.shapes[i], b.orients[i])
        }
        d /= Float(a.shapes.count)

        if a.relative.count == 2, b.relative.count == 2 {
            let rx = a.relative[0] - b.relative[0], ry = a.relative[1] - b.relative[1]
            d += 0.15 * min(1, (rx * rx + ry * ry).squareRoot() / 3)
        }
        if a.velocity.count == 2, b.velocity.count == 2 {
            let vx = a.velocity[0] - b.velocity[0], vy = a.velocity[1] - b.velocity[1]
            let motion = min(1, (vx * vx + vy * vy).squareRoot() / 2)
            d = 0.65 * d + 0.35 * motion
        }
        return d
    }
}

// MARK: - Движение и DTW

enum SignMatching {
    /// Скорость, выше которой движение считается «быстрым» (ладоней в секунду).
    /// Быстрые и очень быстрые движения приводятся к одному масштабу —
    /// так человек, который говорит быстрее, распознаётся так же, как тот, кто медленнее.
    static let fastSpeed: CGFloat = 1.5

    static func velocity(from a: CGPoint, to b: CGPoint, size: CGFloat, dt: Double) -> CGVector {
        guard dt > 0, size > 0 else { return .zero }
        let vx = (b.x - a.x) / size / CGFloat(dt)
        let vy = (b.y - a.y) / size / CGFloat(dt)
        let speed = (vx * vx + vy * vy).squareRoot()
        let scale = 1 / max(speed, fastSpeed)
        return CGVector(dx: vx * scale, dy: vy * scale)
    }

    /// Подготовка записанного жеста: убираем неподвижные кадры в начале и в конце,
    /// берём каждый второй кадр и ограничиваем длину 30 кадрами.
    static func prepareTemplate(_ frames: [SignFrame]) -> [SignFrame] {
        guard !frames.isEmpty else { return [] }
        func speed(_ f: SignFrame) -> Float {
            guard f.velocity.count == 2 else { return 0 }
            return (f.velocity[0] * f.velocity[0] + f.velocity[1] * f.velocity[1]).squareRoot()
        }
        var start = 0
        var end = frames.count - 1
        while start < end && speed(frames[start]) < 0.15 { start += 1 }
        while end > start && speed(frames[end]) < 0.15 { end -= 1 }
        start = max(0, start - 3)
        end = min(frames.count - 1, end + 3)
        var trimmed = Array(frames[start...end])
        if trimmed.count < 10 { trimmed = frames }   // движения почти не было — берём всё

        var halved = stride(from: 0, to: trimmed.count, by: 2).map { trimmed[$0] }
        if halved.count > 30 {
            let step = Float(halved.count - 1) / 29
            halved = (0..<30).map { halved[Int((Float($0) * step).rounded())] }
        }
        return halved
    }

    /// DTW (динамическая трансформация временной шкалы) с открытым началом:
    /// насколько конец потока кадров похож на шаблон жеста, с учётом разной скорости показа.
    /// Возвращает среднюю стоимость на кадр шаблона (меньше — похоже сильнее).
    static func subsequenceDTW(template t: [FrameFeatures], stream s: [FrameFeatures]) -> Float {
        let n = t.count, m = s.count
        guard n > 1, m > 1 else { return .infinity }
        var prev = [Float](repeating: .infinity, count: m)
        var cur = [Float](repeating: .infinity, count: m)
        for j in 0..<m { prev[j] = FrameFeatures.distance(t[0], s[j]) }   // жест может начаться где угодно
        for i in 1..<n {
            cur[0] = prev[0] + FrameFeatures.distance(t[i], s[0])
            for j in 1..<m {
                cur[j] = FrameFeatures.distance(t[i], s[j]) + min(prev[j], prev[j - 1], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[m - 1] / Float(n)   // жест должен закончиться на последнем кадре
    }
}

// MARK: - Жест словаря

struct CustomSign: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    /// Статичный жест: кадры позы.
    var poses: [SignFrame] = []
    /// Жест с движением: каждая запись — последовательность кадров.
    var motions: [[SignFrame]] = []
    /// Сколько раз жест записывали.
    var recordings = 0

    var isDynamic: Bool { !motions.isEmpty }
    var handCount: Int { poses.first?.handCount ?? motions.first?.first?.handCount ?? 1 }
    var exampleCount: Int { recordings }

    init(word: String) {
        self.word = word
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        poses = try c.decodeIfPresent([SignFrame].self, forKey: .poses) ?? []
        motions = try c.decodeIfPresent([[SignFrame]].self, forKey: .motions) ?? []
        recordings = try c.decodeIfPresent(Int.self, forKey: .recordings) ?? 1
    }
}

// MARK: - Словарь и распознавание

/// Словарь жестов и классификаторы:
/// • поза — ближайший сосед (k-NN) по признакам формы кисти;
/// • жест с движением — DTW по последовательности кадров.
/// Каждый жест сравнивается и в обычном, и в зеркальном виде, поэтому
/// жест, записанный правой рукой, распознаётся и левой (и наоборот).
@MainActor
final class SignLibrary: ObservableObject {
    @Published private(set) var signs: [CustomSign] = []

    /// Чувствительность: больше — распознаёт увереннее, но чаще путает; меньше — строже.
    @Published var sensitivity: Double = 1.0 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: Self.sensitivityKey) }
    }

    var hasDynamicSigns: Bool { signs.contains { $0.isDynamic } }

    private struct Cache {
        var poses: [FrameFeatures] = []
        var posesMirrored: [FrameFeatures] = []
        var motions: [[FrameFeatures]] = []
        var motionsMirrored: [[FrameFeatures]] = []
        var poseThreshold: Float = 0.12
        var motionThreshold: Float = 0.16
    }
    private var cache: [UUID: Cache] = [:]

    private static let sensitivityKey = "signSensitivity"
    private let fileURL = URL.documentsDirectory.appending(path: "sign_dictionary_v2.json")

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.sensitivityKey)
        sensitivity = saved > 0 ? saved : 1.0
        load()
    }

    // MARK: Изменение словаря

    func addPoses(word: String, frames: [SignFrame]) {
        let i = indexOrCreate(word)
        signs[i].poses += frames
        signs[i].recordings += 1
        rebuildCache(for: signs[i])
        save()
    }

    func addMotion(word: String, frames: [SignFrame]) {
        let i = indexOrCreate(word)
        signs[i].motions.append(frames)
        signs[i].recordings += 1
        rebuildCache(for: signs[i])
        save()
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { cache[signs[i].id] = nil }
        signs.remove(atOffsets: offsets)
        save()
    }

    private func indexOrCreate(_ word: String) -> Int {
        if let i = signs.firstIndex(where: { $0.word.lowercased() == word.lowercased() }) { return i }
        signs.append(CustomSign(word: word))
        return signs.count - 1
    }

    // MARK: Распознавание

    /// Поза. `sticky` — жест, который уже распознаётся: для него порог немного мягче,
    /// чтобы распознавание не «мигало» от случайного дрожания руки.
    func classifyPose(_ live: FrameFeatures, sticky: UUID?) -> CustomSign? {
        pickBest(sticky: sticky) { cache in
            guard !cache.poses.isEmpty else { return (.infinity, 1) }
            let d = min(Self.nearest(live, in: cache.poses), Self.nearest(live, in: cache.posesMirrored))
            return (d, cache.poseThreshold)
        }
    }

    /// Жест с движением по последним кадрам.
    func classifyMotion(_ stream: [FrameFeatures]) -> CustomSign? {
        pickBest(sticky: nil) { cache in
            guard !cache.motions.isEmpty else { return (.infinity, 1) }
            var d = Float.infinity
            for template in cache.motions + cache.motionsMirrored {
                d = min(d, SignMatching.subsequenceDTW(template: template, stream: stream))
            }
            return (d, cache.motionThreshold)
        }
    }

    /// Выбирает самый похожий жест, если он достаточно похож и явно лучше второго по сходству.
    private func pickBest(sticky: UUID?, cost: (Cache) -> (Float, Float)) -> CustomSign? {
        let scale = Float(sensitivity)
        var best: CustomSign?
        var bestRatio = Float.infinity
        var secondRatio = Float.infinity

        for sign in signs {
            guard let c = cache[sign.id] else { continue }
            let (d, threshold) = cost(c)
            guard d.isFinite else { continue }
            var limit = threshold * scale
            if sign.id == sticky { limit *= 1.3 }
            let ratio = d / limit
            if ratio < bestRatio {
                secondRatio = bestRatio
                bestRatio = ratio
                best = sign
            } else if ratio < secondRatio {
                secondRatio = ratio
            }
        }

        guard let best, bestRatio < 1 else { return nil }
        if secondRatio < bestRatio * 1.12 { return nil }   // неоднозначно — не угадываем
        return best
    }

    private static func nearest(_ live: FrameFeatures, in list: [FrameFeatures]) -> Float {
        var best = Float.infinity
        for f in list {
            let d = FrameFeatures.distance(live, f)
            if d < best { best = d }
        }
        return best
    }

    // MARK: Кэш признаков и пороги

    private func rebuildCache(for sign: CustomSign) {
        var c = Cache()
        c.poses = sign.poses.map(FrameFeatures.init)
        c.posesMirrored = sign.poses.map { FrameFeatures($0.mirrored()) }
        c.motions = sign.motions.map { $0.map(FrameFeatures.init) }
        c.motionsMirrored = sign.motions.map { $0.map { FrameFeatures($0.mirrored()) } }
        c.poseThreshold = Self.poseThreshold(for: c.poses)
        c.motionThreshold = Self.motionThreshold(for: c.motions)
        cache[sign.id] = c
    }

    /// Порог для позы подбирается по разбросу записанных примеров:
    /// если жест записали несколько разных людей, порог мягче.
    private static func poseThreshold(for frames: [FrameFeatures]) -> Float {
        guard frames.count > 12 else { return 0.12 }
        var distances: [Float] = []
        for i in stride(from: 0, to: frames.count, by: 5) {
            var best = Float.infinity
            for j in frames.indices where abs(i - j) > 6 {
                best = min(best, FrameFeatures.distance(frames[i], frames[j]))
            }
            if best.isFinite { distances.append(best) }
        }
        guard !distances.isEmpty else { return 0.12 }
        distances.sort()
        let p90 = distances[Int(Float(distances.count - 1) * 0.9)]
        return min(0.18, max(0.10, p90 * 3))
    }

    /// Порог для жеста с движением: по тому, насколько отличаются между собой записи одного слова.
    private static func motionThreshold(for motions: [[FrameFeatures]]) -> Float {
        guard motions.count >= 2 else { return 0.16 }
        var worst: Float = 0
        for i in motions.indices {
            for j in motions.indices where i != j {
                let d = SignMatching.subsequenceDTW(template: motions[i], stream: motions[j])
                if d.isFinite { worst = max(worst, d) }
            }
        }
        return min(0.26, max(0.13, worst * 1.3))
    }

    // MARK: Хранение

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([CustomSign].self, from: data) else { return }
        signs = saved
        for sign in signs { rebuildCache(for: sign) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(signs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
