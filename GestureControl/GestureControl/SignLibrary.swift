import SwiftUI
import Combine

// MARK: - Рука на кадре (для распознавания)

/// Рука в координатах экрана: 21 точка и уверенность в каждой (0…1).
/// Точка (-1, -1) — не найдена совсем.
struct HandSample {
    var points: [CGPoint]
    var confidence: [Float]
    /// Какая это рука по оценке Vision: +1 правая, −1 левая, 0 — неизвестно.
    var chirality: Int = 0

    private static let palmJoints = [0, 5, 9, 13, 17]

    /// Размер ладони: от запястья до основания среднего пальца.
    var palmSize: CGFloat {
        guard points.count == Joint.count, points[0].x >= 0, points[9].x >= 0 else { return 0 }
        return dist(points[0], points[9])
    }

    /// Центр ладони.
    var center: CGPoint {
        let palm = Self.palmJoints.map { points[$0] }.filter { $0.x >= 0 }
        guard !palm.isEmpty else { return .zero }
        let n = CGFloat(palm.count)
        return CGPoint(x: palm.map(\.x).reduce(0, +) / n, y: palm.map(\.y).reduce(0, +) / n)
    }

    /// Рука пригодна для сравнения жестов: все точки есть, ладонь видна уверенно,
    /// а пальцы в среднем видны хотя бы частично (при повороте боком часть пальцев скрыта — это допустимо).
    var isUsable: Bool {
        guard points.count == Joint.count, confidence.count == Joint.count,
              points.allSatisfy({ $0.x >= 0 }), palmSize > 10 else { return false }
        let palmOK = Self.palmJoints.allSatisfy { confidence[$0] >= 0.2 }
        let mean = confidence.reduce(0, +) / Float(confidence.count)
        return palmOK && mean >= 0.3
    }

    /// Точки для отрисовки и встроенных жестов: неуверенные точки заменены на (-1, -1).
    func thresholded(_ minimum: Float = 0.3) -> [CGPoint] {
        zip(points, confidence).map { $1 >= minimum ? $0 : CGPoint(x: -1, y: -1) }
    }

    /// Отражение по горизонтали внутри области шириной `width`.
    func flipped(width: CGFloat) -> HandSample {
        HandSample(points: points.map { $0.x < 0 ? $0 : CGPoint(x: width - $0.x, y: $0.y) },
                   confidence: confidence,
                   chirality: chirality)
    }
}

// MARK: - Сглаживание дрожания (фильтр One Euro)

/// Убирает мелкое дрожание точек, почти не добавляя задержки при быстрых движениях:
/// когда рука неподвижна — сглаживает сильно, когда движется быстро — почти не сглаживает.
struct HandSmoother {
    /// Сглаживание в покое (Гц): меньше — плавнее, но с задержкой.
    var minCutoff: Double = 1.7
    /// Насколько быстро фильтр «отпускает» при движении.
    var beta: Double = 3.0
    var derivativeCutoff: Double = 1.0

    private struct Track {
        var points: [CGPoint]
        var velocity: [CGVector]
        var time: Double
        /// Какая это рука, усреднённо по кадрам: одиночные ошибки Vision не мешают.
        var chirality: Double
    }
    private var tracks: [Track] = []

    mutating func reset() {
        tracks = []
    }

    private static func alpha(cutoff: Double, dt: Double) -> CGFloat {
        let tau = 1 / (2 * Double.pi * cutoff)
        return CGFloat(1 / (1 + tau / dt))
    }

    mutating func smooth(_ hands: [HandSample], time: Double) -> [HandSample] {
        var result: [HandSample] = []
        var newTracks: [Track] = []
        var used = Set<Int>()

        for hand in hands {
            let size = hand.palmSize
            guard hand.points.count == Joint.count, hand.points[0].x >= 0, size > 0 else {
                result.append(hand)
                continue
            }
            // Та же рука на прошлом кадре — ближайшая по запястью.
            var match: Int?
            var best = CGFloat.infinity
            for (i, track) in tracks.enumerated() where !used.contains(i) && track.points[0].x >= 0 {
                let d = dist(track.points[0], hand.points[0])
                if d < best {
                    best = d
                    match = i
                }
            }
            guard let i = match, best < max(size * 1.5, 40), time - tracks[i].time < 0.25 else {
                newTracks.append(Track(points: hand.points,
                                       velocity: Array(repeating: .zero, count: Joint.count),
                                       time: time,
                                       chirality: Double(hand.chirality)))
                result.append(hand)
                continue
            }
            used.insert(i)

            let previous = tracks[i]
            let dt = max(0.001, time - previous.time)
            var points = hand.points
            var velocity = previous.velocity
            let ad = Self.alpha(cutoff: derivativeCutoff, dt: dt)

            for j in points.indices {
                guard points[j].x >= 0, previous.points[j].x >= 0 else { continue }
                let raw = CGVector(dx: (points[j].x - previous.points[j].x) / CGFloat(dt),
                                   dy: (points[j].y - previous.points[j].y) / CGFloat(dt))
                let v = CGVector(dx: ad * raw.dx + (1 - ad) * velocity[j].dx,
                                 dy: ad * raw.dy + (1 - ad) * velocity[j].dy)
                velocity[j] = v
                let speed = Double((v.dx * v.dx + v.dy * v.dy).squareRoot() / size)   // ладоней в секунду
                let a = Self.alpha(cutoff: minCutoff + beta * speed, dt: dt)
                points[j] = CGPoint(x: previous.points[j].x + a * (points[j].x - previous.points[j].x),
                                    y: previous.points[j].y + a * (points[j].y - previous.points[j].y))
            }
            var chirality = previous.chirality
            if hand.chirality != 0 {
                chirality = chirality * 0.8 + Double(hand.chirality) * 0.2
            }
            newTracks.append(Track(points: points, velocity: velocity, time: time, chirality: chirality))
            result.append(HandSample(points: points, confidence: hand.confidence,
                                     chirality: chirality > 0.3 ? 1 : (chirality < -0.3 ? -1 : 0)))
        }
        tracks = newTracks
        return result
    }
}

// MARK: - Сырые данные жеста (хранятся в словаре)

/// Поза одной руки: 21 точка относительно запястья, в размерах ладони (x0, y0, x1, y1, … — 42 числа),
/// и уверенность в каждой точке. Хранятся именно точки, а не готовые признаки:
/// если алгоритм сравнения улучшится, записанный словарь останется рабочим.
struct HandPose: Codable, Equatable {
    var points: [Float]
    /// Уверенность в каждой из 21 точки. nil — старая запись, считаем все точки надёжными.
    var confidence: [Float]?
    /// Какая это рука: +1 правая, −1 левая, 0 или nil — неизвестно (записи прошлых версий).
    var chirality: Int?

    func weight(_ i: Int) -> Float {
        guard let confidence, i < confidence.count else { return 1 }
        // 0.1 и ниже — почти не учитываем, 0.6 и выше — учитываем полностью.
        return max(0.05, min(1, (confidence[i] - 0.1) / 0.5))
    }
}

/// Плечи на кадре (в тех же координатах экрана, что и руки): середина между плечами
/// и расстояние между ними. Относительно плеч считается, где находятся руки.
struct BodyReference {
    var center: CGPoint
    var width: CGFloat

    init?(shoulders: [CGPoint]) {
        guard shoulders.count == 2 else { return nil }
        let a = shoulders[0], b = shoulders[1]
        width = dist(a, b)
        guard width > 10 else { return nil }
        center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// Один кадр жеста: одна или две руки, их взаимное положение и движение.
struct SignFrame: Codable, Equatable {
    /// Руки слева направо (как на экране).
    var hands: [HandPose]
    /// Положение второй руки относительно первой [dx, dy] в размерах ладони. Пусто для одной руки.
    var relative: [Float]
    /// Скорость ведущей руки [vx, vy], поделённая на max(|v|, 1,5) — формат прошлых версий. Пусто для позы.
    var velocity: [Float]
    /// Скорость ведущей руки [vx, vy] в ладонях в секунду. nil — запись прошлой версии.
    var rawVelocity: [Float]?
    /// Где находится каждая рука относительно плеч [x0, y0, x1, y1]: центр ладони относительно
    /// середины между плечами, в расстояниях между плечами. nil — плечи не были видны.
    var locations: [Float]?

    var handCount: Int { hands.count }

    /// Кадр из найденных рук. Учитываются только пригодные руки (см. `HandSample.isUsable`).
    /// `velocity` — скорость ведущей руки в ладонях в секунду (для жестов с движением).
    /// `body` — плечи, если они видны: тогда запоминается и положение рук относительно тела.
    static func make(from samples: [HandSample], velocity: CGVector? = nil, body: BodyReference? = nil) -> SignFrame? {
        let usable = samples.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }
        // Две самые крупные (ближние) руки, слева направо.
        let chosen = Array(usable.sorted { $0.palmSize > $1.palmSize }.prefix(2))
            .sorted { $0.center.x < $1.center.x }

        let hands = chosen.map { hand -> HandPose in
            let origin = hand.points[Joint.wrist]
            let size = hand.palmSize
            var pts: [Float] = []
            pts.reserveCapacity(Joint.count * 2)
            for point in hand.points {
                pts.append(Float((point.x - origin.x) / size))
                pts.append(Float((point.y - origin.y) / size))
            }
            return HandPose(points: pts, confidence: hand.confidence, chirality: hand.chirality)
        }

        var relative: [Float] = []
        if chosen.count == 2 {
            let scale = (chosen[0].palmSize + chosen[1].palmSize) / 2
            relative = [Float((chosen[1].center.x - chosen[0].center.x) / scale),
                        Float((chosen[1].center.y - chosen[0].center.y) / scale)]
        }
        var frame = SignFrame(hands: hands, relative: relative, velocity: [])
        if let velocity {
            let scale = max((velocity.dx * velocity.dx + velocity.dy * velocity.dy).squareRoot(), 1.5)
            frame.velocity = [Float(velocity.dx / scale), Float(velocity.dy / scale)]
            frame.rawVelocity = [Float(velocity.dx), Float(velocity.dy)]
        }
        if let body {
            let locations: [Float] = chosen.flatMap { hand -> [Float] in
                [Float((hand.center.x - body.center.x) / body.width),
                 Float((hand.center.y - body.center.y) / body.width)]
            }
            frame.locations = locations
        }
        return frame
    }
}

// MARK: - Жест словаря

struct CustomSign: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    /// Статичный жест: кадры позы.
    var poses: [SignFrame] = []
    /// Сколько кадров позы в каждой записи, по порядку. nil — словарь прошлой версии (одна общая запись).
    var poseCounts: [Int]?
    /// Жест с движением: каждая запись — последовательность кадров.
    var motions: [[SignFrame]] = []
    /// Сколько раз жест записывали.
    var recordings = 0

    var isDynamic: Bool { !motions.isEmpty }
    var handCount: Int { poses.first?.handCount ?? motions.first?.first?.handCount ?? 1 }
    var exampleCount: Int { recordings }

    /// Кадры позы, разбитые по записям.
    var poseGroups: [[SignFrame]] {
        guard let counts = poseCounts, counts.reduce(0, +) == poses.count else {
            return poses.isEmpty ? [] : [poses]
        }
        var groups: [[SignFrame]] = []
        var start = 0
        for count in counts where count > 0 {
            groups.append(Array(poses[start..<(start + count)]))
            start += count
        }
        return groups
    }

    init(word: String) {
        self.word = word
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        poses = try c.decodeIfPresent([SignFrame].self, forKey: .poses) ?? []
        poseCounts = try c.decodeIfPresent([Int].self, forKey: .poseCounts)
        motions = try c.decodeIfPresent([[SignFrame]].self, forKey: .motions) ?? []
        recordings = try c.decodeIfPresent(Int.self, forKey: .recordings) ?? 1
    }
}

// MARK: - Словарь и распознавание

/// Словарь жестов и классификаторы:
/// • поза — k ближайших соседей (k-NN) по признакам формы кисти;
/// • жест с движением — DTW по последовательности кадров.
/// Жест левой руки сравнивается с записанным правой рукой в зеркальном виде.
///
/// Защита от ложных срабатываний:
/// • порог сходства подбирается для каждого слова по разбросу его записей;
/// • общий множитель порогов задаёт ползунок «Чувствительность»;
/// • жест не засчитывается, если второй по сходству почти так же похож (неоднозначность);
/// • уже распознаваемый жест удерживается с чуть более мягким порогом («липкий» порог).
@MainActor
final class SignLibrary: ObservableObject {
    @Published private(set) var signs: [CustomSign] = []

    /// Чувствительность: больше — распознаёт увереннее, но чаще путает; меньше — строже.
    @Published var sensitivity: Double = 1.0 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: Self.sensitivityKey) }
    }

    /// Искать плечи и учитывать, где находятся руки относительно тела
    /// (у подбородка, у груди, у плеча — это разные жесты).
    @Published var useShoulders: Bool = true {
        didSet { UserDefaults.standard.set(useShoulders, forKey: Self.shouldersKey) }
    }

    var hasDynamicSigns: Bool { signs.contains { $0.isDynamic } }
    /// Сколько секунд последних кадров сравнивать с жестами с движением
    /// (зависит от длины записанных жестов).
    private(set) var motionWindow: Double = 2.0

    private struct Cache {
        /// Кадры поз (прорежены).
        var poses: [FrameFeatures]
        var poseThreshold: Float
        /// Записи с движением.
        var motions: [MotionTemplate]
        var motionThreshold: Float
    }
    private var cache: [UUID: Cache] = [:]

    /// Сколько кадров позы на слово брать для сравнения (остальные прореживаются).
    private let maxPoseFrames = 60
    /// Сколько кадров позы сохранять из одной записи.
    private let posesPerRecording = 20

    private static let sensitivityKey = "signSensitivity"
    private static let shouldersKey = "useShoulders"
    private let fileURL = URL.documentsDirectory.appending(path: "sign_dictionary_v2.json")

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.sensitivityKey)
        sensitivity = saved > 0 ? saved : 1.0
        useShoulders = UserDefaults.standard.object(forKey: Self.shouldersKey) as? Bool ?? true
        load()
    }

    // MARK: Изменение словаря

    func addPoses(word: String, frames: [SignFrame]) {
        let i = indexOrCreate(word)
        let cleaned = cleanPoses(frames)
        var counts = signs[i].poseCounts ?? (signs[i].poses.isEmpty ? [] : [signs[i].poses.count])
        counts.append(cleaned.count)
        signs[i].poses += cleaned
        signs[i].poseCounts = counts
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
        updateMotionWindow()
        save()
    }

    func sign(id: UUID) -> CustomSign? {
        signs.first { $0.id == id }
    }

    private func index(of word: String) -> Int? {
        signs.firstIndex { $0.word.lowercased() == word.lowercased() }
    }

    private func indexOrCreate(_ word: String) -> Int {
        if let i = index(of: word) { return i }
        signs.append(CustomSign(word: word))
        return signs.count - 1
    }

    /// Чистка записанной позы: убираем кадры-выбросы (рука дёрнулась, точки найдены с ошибкой)
    /// и оставляем не больше `posesPerRecording` кадров.
    private func cleanPoses(_ frames: [SignFrame]) -> [SignFrame] {
        let features = frames.map(FrameFeatures.init)
        guard features.count > 2, let medoid = Self.medoid(of: features) else { return frames }
        let distances = features.map { FrameFeatures.shapeDistance($0, medoid) }
        let median = distances.sorted()[distances.count / 2]
        let maxDistance = max(median * 2.5, 0.05)
        let kept = zip(frames, distances).filter { $0.1 <= maxDistance }.map { $0.0 }
        return SignMatching.evenlySpaced(kept, count: posesPerRecording)
    }

    /// Самый «типичный» кадр: сумма расстояний до остальных минимальна.
    private static func medoid(of frames: [FrameFeatures]) -> FrameFeatures? {
        var best: FrameFeatures?
        var bestSum = Float.infinity
        for a in frames {
            var sum: Float = 0
            for b in frames {
                let d = FrameFeatures.shapeDistance(a, b)
                if d.isFinite { sum += d }
            }
            if sum < bestSum {
                bestSum = sum
                best = a
            }
        }
        return best
    }

    // MARK: Распознавание

    /// Поза. `sticky` — жест, который уже распознаётся: для него порог немного мягче,
    /// чтобы распознавание не «мигало» от случайного дрожания руки.
    func classifyPose(_ live: FrameFeatures, sticky: UUID?) -> CustomSign? {
        let mirrored = live.mirrored()
        let scale = Float(sensitivity)
        var costs: [(sign: CustomSign, ratio: Float)] = []
        for sign in signs {
            guard let c = cache[sign.id], !c.poses.isEmpty else { continue }
            let d = Self.poseCost(live, mirrored, c.poses)
            if d.isFinite { costs.append((sign, d / (c.poseThreshold * scale))) }
        }
        return decide(costs, sticky: sticky)?.sign
    }

    /// Лучший жест с движением, который заканчивается на последнем кадре потока.
    /// nil — ни один жест не похож достаточно или выбор неоднозначен.
    func bestMotion(_ stream: MotionStream) -> MotionSpotter.Match? {
        guard stream.frames.count >= 4 else { return nil }
        let scale = Float(sensitivity)
        var costs: [(sign: CustomSign, ratio: Float)] = []
        for sign in signs {
            guard let c = cache[sign.id], !c.motions.isEmpty else { continue }
            let limit = c.motionThreshold * scale
            var best = Float.infinity
            for template in c.motions {
                // Если жест заведомо не подходит, DTW прекращается досрочно.
                best = min(best, template.cost(on: stream, abandonAbove: min(best, limit * 1.3)))
            }
            if best.isFinite { costs.append((sign, best / limit)) }
        }
        guard let best = decide(costs, sticky: nil) else { return nil }
        return MotionSpotter.Match(id: best.sign.id, cost: best.ratio)
    }

    /// Среднее расстояние до трёх ближайших кадров позы (в обычном или зеркальном виде).
    private static func poseCost(_ live: FrameFeatures, _ mirrored: FrameFeatures,
                                 _ poses: [FrameFeatures]) -> Float {
        let k = SignMatching.poseNeighbours
        var nearest: [Float] = []
        for pose in poses {
            let d = min(FrameFeatures.shapeDistance(live, pose), FrameFeatures.shapeDistance(mirrored, pose))
            guard d.isFinite else { continue }
            if nearest.count < k {
                nearest.append(d)
                nearest.sort()
            } else if d < nearest[k - 1] {
                nearest[k - 1] = d
                nearest.sort()
            }
        }
        guard !nearest.isEmpty else { return .infinity }
        return nearest.reduce(0, +) / Float(nearest.count)
    }

    /// Выбирает самый похожий жест, если он достаточно похож и явно лучше второго по сходству.
    /// `ratio` — расстояние, делённое на порог слова: меньше 1 — жест подходит.
    private func decide(_ costs: [(sign: CustomSign, ratio: Float)],
                        sticky: UUID?) -> (sign: CustomSign, ratio: Float)? {
        let sorted = costs.sorted { $0.ratio < $1.ratio }
        guard let best = sorted.first else { return nil }
        let second = sorted.count > 1 ? sorted[1].ratio : .infinity
        let ambiguity = SignMatching.ambiguityRatio

        // «Липкий» порог: жест, который уже распознаётся, отпускаем не сразу.
        if let sticky, let current = sorted.first(where: { $0.sign.id == sticky }),
           current.ratio < SignMatching.stickyFactor, current.ratio <= best.ratio * ambiguity {
            return current
        }

        guard best.ratio < 1 else { return nil }
        if second < best.ratio * ambiguity { return nil }   // неоднозначно — не угадываем
        return best
    }

    // MARK: Проверка похожих слов при записи

    /// Другое слово словаря, с позой которого можно перепутать новую запись.
    func similarPose(to frames: [SignFrame], excludingWord word: String) -> CustomSign? {
        let features = frames.map(FrameFeatures.init)
        guard let medoid = Self.medoid(of: features) else { return nil }
        let own = index(of: word).map { signs[$0].id }
        let mirrored = medoid.mirrored()
        return signs
            .filter { $0.id != own }
            .compactMap { sign -> (sign: CustomSign, ratio: Float)? in
                guard let c = cache[sign.id], !c.poses.isEmpty else { return nil }
                return (sign, Self.poseCost(medoid, mirrored, c.poses) / c.poseThreshold)
            }
            .filter { $0.ratio < 1 }
            .min { $0.ratio < $1.ratio }?.sign
    }

    /// Другое слово словаря, с жестом которого можно перепутать новую запись с движением.
    func similarMotion(to frames: [SignFrame], excludingWord word: String) -> CustomSign? {
        let stream = MotionStream(frames.map(FrameFeatures.init))
        let own = index(of: word).map { signs[$0].id }
        return signs
            .filter { $0.id != own }
            .compactMap { sign -> (sign: CustomSign, ratio: Float)? in
                guard let c = cache[sign.id], !c.motions.isEmpty else { return nil }
                let cost = c.motions.map { $0.cost(on: stream) }.min() ?? .infinity
                return (sign, cost / c.motionThreshold)
            }
            .filter { $0.ratio < 1 }
            .min { $0.ratio < $1.ratio }?.sign
    }

    // MARK: Кэш признаков и пороги

    private func rebuildCache(for sign: CustomSign) {
        // Позы: из каждой записи берём поровну кадров, чтобы ни одна запись не «перевешивала».
        let groups = sign.poseGroups
        let perGroup = max(8, maxPoseFrames / max(1, groups.count))
        let poseGroups = groups.map { SignMatching.evenlySpaced($0, count: perGroup).map(FrameFeatures.init) }
        let motions = sign.motions.compactMap(MotionTemplate.init)
        cache[sign.id] = Cache(poses: poseGroups.flatMap { $0 },
                               poseThreshold: Self.poseThreshold(poseGroups),
                               motions: motions,
                               motionThreshold: Self.motionThreshold(motions))
        updateMotionWindow()
    }

    private func updateMotionWindow() {
        let longest = cache.values.flatMap(\.motions).map(\.frames.count).max() ?? 0
        motionWindow = min(3.0, max(1.5, Double(longest) / SignMatching.sampleRate + 0.8))
    }

    /// Порог для позы. Если записей несколько, смотрим, насколько они отличаются друг от друга:
    /// например, у разных людей жест выглядит по-разному, и порог нужен шире.
    private static func poseThreshold(_ groups: [[FrameFeatures]]) -> Float {
        let base = SignMatching.basePoseThreshold
        guard groups.count >= 2 else { return base }
        var gaps: [Float] = []
        for (g, group) in groups.enumerated() {
            let others = groups.enumerated().filter { $0.offset != g }.flatMap { $0.element }
            for frame in group {
                let mirrored = frame.mirrored()
                let nearest = others
                    .map { min(FrameFeatures.shapeDistance(frame, $0), FrameFeatures.shapeDistance(mirrored, $0)) }
                    .min() ?? .infinity
                if nearest.isFinite { gaps.append(nearest) }
            }
        }
        guard !gaps.isEmpty else { return base }
        let spread = gaps.sorted()[gaps.count / 2]
        return min(max(base, spread * 1.5), base * SignMatching.maxThresholdGrowth)
    }

    /// Порог для жеста с движением: по тому, насколько отличаются между собой записи одного слова.
    private static func motionThreshold(_ templates: [MotionTemplate]) -> Float {
        let base = SignMatching.baseMotionThreshold
        guard templates.count >= 2 else { return base }
        var costs: [Float] = []
        for (i, a) in templates.enumerated() {
            for (j, b) in templates.enumerated() where i != j {
                let c = a.cost(on: MotionStream(b.frames))
                if c.isFinite { costs.append(c) }
            }
        }
        guard !costs.isEmpty else { return base }
        let mean = costs.reduce(0, +) / Float(costs.count)
        return min(max(base, mean * 1.3), base * SignMatching.maxThresholdGrowth)
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
