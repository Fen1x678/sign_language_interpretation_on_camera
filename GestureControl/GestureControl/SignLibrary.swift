import SwiftUI
import Combine

// MARK: - Рука на кадре (для распознавания)

/// Рука в координатах экрана: 21 точка и уверенность в каждой (0…1).
/// Точка (-1, -1) — не найдена совсем.
struct HandSample {
    var points: [CGPoint]
    var confidence: [Float]

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
                   confidence: confidence)
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
                                       time: time))
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
            newTracks.append(Track(points: points, velocity: velocity, time: time))
            result.append(HandSample(points: points, confidence: hand.confidence))
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

    func weight(_ i: Int) -> Float {
        guard let confidence, i < confidence.count else { return 1 }
        // 0.1 и ниже — почти не учитываем, 0.6 и выше — учитываем полностью.
        return max(0.05, min(1, (confidence[i] - 0.1) / 0.5))
    }
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

    /// Кадр из найденных рук. Учитываются только пригодные руки (см. `HandSample.isUsable`).
    static func make(from samples: [HandSample], velocity: CGVector? = nil) -> SignFrame? {
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
            return HandPose(points: pts, confidence: hand.confidence)
        }

        var relative: [Float] = []
        if chosen.count == 2 {
            let scale = (chosen[0].palmSize + chosen[1].palmSize) / 2
            relative = [Float((chosen[1].center.x - chosen[0].center.x) / scale),
                        Float((chosen[1].center.y - chosen[0].center.y) / scale)]
        }
        let v: [Float] = velocity.map { [Float($0.dx), Float($0.dy)] } ?? []
        return SignFrame(hands: hands, relative: relative, velocity: v)
    }

    /// Зеркальное отражение по горизонтали: жест левой руки ↔ тот же жест правой рукой.
    func mirrored() -> SignFrame {
        let flipped = hands.map { hand in
            HandPose(points: hand.points.enumerated().map { $0.offset % 2 == 0 ? -$0.element : $0.element },
                     confidence: hand.confidence)
        }
        return SignFrame(
            hands: Array(flipped.reversed()),
            relative: relative.count == 2 ? [relative[0], -relative[1]] : relative,
            velocity: velocity.count == 2 ? [-velocity[0], velocity[1]] : velocity
        )
    }

    /// Как выглядел бы этот кадр, если бы камера смотрела под другим углом.
    /// yaw — камера сбоку (поворот вокруг вертикальной оси), pitch — сверху или снизу; в градусах.
    /// При взгляде под углом изображение сжимается по соответствующей оси (ракурсное сокращение).
    func viewed(yaw: Float, pitch: Float) -> SignFrame {
        let cx = cos(yaw * Float.pi / 180)
        let cy = cos(pitch * Float.pi / 180)
        var scales: [Float] = []
        let newHands = hands.map { hand -> HandPose in
            var pts = hand.points
            for i in stride(from: 0, to: pts.count - 1, by: 2) {
                pts[i] *= cx
                pts[i + 1] *= cy
            }
            // Заново нормируем на видимый размер ладони — так же, как для живого кадра.
            let palm = max(1e-3, (pts[18] * pts[18] + pts[19] * pts[19]).squareRoot())
            scales.append(palm)
            return HandPose(points: pts.map { $0 / palm }, confidence: hand.confidence)
        }
        var newRelative = relative
        if relative.count == 2, !scales.isEmpty {
            let s = scales.reduce(0, +) / Float(scales.count)
            newRelative = [relative[0] * cx / s, relative[1] * cy / s]
        }
        let newVelocity = velocity.count == 2 ? [velocity[0] * cx, velocity[1] * cy] : velocity
        return SignFrame(hands: newHands, relative: newRelative, velocity: newVelocity)
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
/// У каждого признака есть вес: если точки плохо видны (палец скрыт), признак учитывается слабее.
/// Отдельно — направление кисти (куда «смотрят» пальцы).
struct FrameFeatures {
    var shapes: [[Float]]
    var weights: [[Float]]
    var orients: [[Float]]
    var relative: [Float]
    var velocity: [Float]

    init(_ frame: SignFrame) {
        var shapes: [[Float]] = []
        var weights: [[Float]] = []
        for hand in frame.hands {
            let (s, w) = FrameFeatures.shape(of: hand)
            shapes.append(s)
            weights.append(w)
        }
        self.shapes = shapes
        self.weights = weights
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

    static func shape(of pose: HandPose) -> ([Float], [Float]) {
        func pt(_ i: Int) -> SIMD2<Float> { point(pose, i) }
        func w(_ joints: Int...) -> Float { joints.map { pose.weight($0) }.min() ?? 1 }

        var f: [Float] = []
        var wt: [Float] = []
        f.reserveCapacity(24)
        wt.reserveCapacity(24)

        // Сгиб суставов: угол между соседними костями пальца.
        for chain in chains {
            for k in 1...3 {
                f.append(angle(pt(chain[k]) - pt(chain[k - 1]), pt(chain[k + 1]) - pt(chain[k])))
                wt.append(w(chain[k - 1], chain[k], chain[k + 1]))
            }
        }
        // Разведение пальцев.
        let directions = chains.map { pt($0[4]) - pt($0[1]) }
        for i in 0..<4 {
            f.append(angle(directions[i], directions[i + 1]))
            wt.append(w(chains[i][1], chains[i][4], chains[i + 1][1], chains[i + 1][4]))
        }
        // Расстояния от кончика большого пальца до остальных кончиков.
        for tip in [8, 12, 16, 20] {
            f.append(min(1, length(pt(4) - pt(tip)) / 2))
            wt.append(w(4, tip))
        }
        // Ладонь или тыльная сторона (знак векторного произведения).
        let a = pt(5) - pt(0), b = pt(17) - pt(0)
        let cross = a.x * b.y - a.y * b.x
        f.append(cross / max(1e-4, length(a) * length(b)) / 2)
        wt.append(w(0, 5, 17))
        return (f, wt)
    }

    static func orientation(of pose: HandPose) -> [Float] {
        let d = point(pose, 9) - point(pose, 0)
        let l = max(1e-4, length(d))
        return [d.x / l, d.y / l]
    }

    private static func handDistance(_ a: [Float], _ wa: [Float], _ oa: [Float],
                                     _ b: [Float], _ wb: [Float], _ ob: [Float]) -> Float {
        /// Взвешенное среднее отличие группы признаков. Если группа почти не видна
        /// ни на одном кадре — считаем её «средне непохожей», а не одинаковой.
        func group(_ range: Range<Int>) -> Float {
            var sum: Float = 0
            var total: Float = 0
            for i in range {
                let weight = min(wa[i], wb[i])
                sum += weight * abs(a[i] - b[i])
                total += weight
            }
            return total > 0.15 ? sum / total : 0.25
        }
        let flex = group(0..<15)
        let spread = group(15..<19)
        let tips = group(19..<23)
        let palm = group(23..<24)
        let dx = oa[0] - ob[0], dy = oa[1] - ob[1]
        let orient = (dx * dx + dy * dy).squareRoot() / 2
        return (1.0 * flex + 0.6 * spread + 0.8 * tips + 0.2 * palm + 0.4 * orient) / 3.0
    }

    /// Насколько два кадра непохожи: 0 — одинаковые, 1 — совсем разные.
    static func distance(_ a: FrameFeatures, _ b: FrameFeatures) -> Float {
        guard a.shapes.count == b.shapes.count, !a.shapes.isEmpty else { return 1 }
        var d: Float = 0
        for i in a.shapes.indices {
            d += handDistance(a.shapes[i], a.weights[i], a.orients[i],
                              b.shapes[i], b.weights[i], b.orients[i])
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

    /// Виртуальные ракурсы для поз (yaw, pitch в градусах): прямо, сбоку, сильно сбоку, сверху/снизу и наискосок.
    static let poseViews: [(Float, Float)] = [(0, 0), (30, 0), (50, 0), (0, 30), (30, 30), (50, 30)]
    /// Для жестов с движением ракурсов меньше — сравнение последовательностей дороже.
    static let motionViews: [(Float, Float)] = [(0, 0), (35, 0), (0, 30)]

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
    /// `abandonAbove` — если результат заведомо хуже этого значения, расчёт прекращается досрочно (ускорение).
    static func subsequenceDTW(template t: [FrameFeatures], stream s: [FrameFeatures],
                               abandonAbove: Float = .infinity) -> Float {
        let n = t.count, m = s.count
        guard n > 1, m > 1 else { return .infinity }
        let limit = abandonAbove * Float(n)
        var prev = [Float](repeating: .infinity, count: m)
        var cur = [Float](repeating: .infinity, count: m)
        for j in 0..<m { prev[j] = FrameFeatures.distance(t[0], s[j]) }   // жест может начаться где угодно
        for i in 1..<n {
            cur[0] = prev[0] + FrameFeatures.distance(t[i], s[0])
            var rowMin = cur[0]
            for j in 1..<m {
                cur[j] = FrameFeatures.distance(t[i], s[j]) + min(prev[j], prev[j - 1], cur[j - 1])
                if cur[j] < rowMin { rowMin = cur[j] }
            }
            if rowMin > limit { return .infinity }   // дальше будет только хуже
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
/// Каждый жест сравнивается в обычном и зеркальном виде (правая ↔ левая рука)
/// и в нескольких виртуальных ракурсах (камера сбоку, сверху, снизу).
@MainActor
final class SignLibrary: ObservableObject {
    @Published private(set) var signs: [CustomSign] = []

    /// Чувствительность: больше — распознаёт увереннее, но чаще путает; меньше — строже.
    @Published var sensitivity: Double = 1.0 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: Self.sensitivityKey) }
    }

    var hasDynamicSigns: Bool { signs.contains { $0.isDynamic } }

    private struct Cache {
        /// Все варианты позы: исходные, зеркальные и в виртуальных ракурсах.
        var poses: [FrameFeatures] = []
        /// Все варианты каждой записи с движением.
        var motions: [[FrameFeatures]] = []
        var poseThreshold: Float = 0.12
        var motionThreshold: Float = 0.16
    }
    private var cache: [UUID: Cache] = [:]

    /// Сколько кадров позы на слово брать для сравнения (остальные прореживаются).
    private let maxPoseFrames = 48

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
        pickBest(sticky: sticky) { cache, _ in
            guard !cache.poses.isEmpty else { return (.infinity, 1) }
            var best = Float.infinity
            for f in cache.poses {
                let d = FrameFeatures.distance(live, f)
                if d < best { best = d }
            }
            return (best, cache.poseThreshold)
        }
    }

    /// Жест с движением по последним кадрам.
    func classifyMotion(_ stream: [FrameFeatures]) -> CustomSign? {
        pickBest(sticky: nil) { cache, limit in
            guard !cache.motions.isEmpty else { return (.infinity, 1) }
            var best = Float.infinity
            for template in cache.motions {
                let d = SignMatching.subsequenceDTW(template: template, stream: stream,
                                                    abandonAbove: min(best, limit * 1.2))
                if d < best { best = d }
            }
            return (best, cache.motionThreshold)
        }
    }

    /// Выбирает самый похожий жест, если он достаточно похож и явно лучше второго по сходству.
    /// `cost` получает кэш жеста и предел, после которого жест точно не подходит (для ускорения).
    private func pickBest(sticky: UUID?, cost: (Cache, Float) -> (Float, Float)) -> CustomSign? {
        let scale = Float(sensitivity)
        var best: CustomSign?
        var bestRatio = Float.infinity
        var secondRatio = Float.infinity

        for sign in signs {
            guard let c = cache[sign.id] else { continue }
            let roughLimit = max(c.poseThreshold, c.motionThreshold) * scale * 1.3
            let (d, threshold) = cost(c, roughLimit)
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

    // MARK: Кэш признаков и пороги

    private func rebuildCache(for sign: CustomSign) {
        var c = Cache()

        // Позы: прореживаем, затем добавляем зеркальные варианты и виртуальные ракурсы.
        var poses = sign.poses
        if poses.count > maxPoseFrames {
            let step = Float(poses.count - 1) / Float(maxPoseFrames - 1)
            poses = (0..<maxPoseFrames).map { poses[Int((Float($0) * step).rounded())] }
        }
        for frame in poses {
            for (yaw, pitch) in SignMatching.poseViews {
                let view = frame.viewed(yaw: yaw, pitch: pitch)
                c.poses.append(FrameFeatures(view))
                c.poses.append(FrameFeatures(view.mirrored()))
            }
        }

        // Движения: каждая запись в нескольких ракурсах и зеркально.
        for motion in sign.motions {
            for (yaw, pitch) in SignMatching.motionViews {
                let view = motion.map { $0.viewed(yaw: yaw, pitch: pitch) }
                c.motions.append(view.map(FrameFeatures.init))
                c.motions.append(view.map { FrameFeatures($0.mirrored()) })
            }
        }

        c.poseThreshold = Self.poseThreshold(for: poses.map(FrameFeatures.init))
        c.motionThreshold = Self.motionThreshold(for: sign.motions.map { $0.map(FrameFeatures.init) })
        cache[sign.id] = c
    }

    /// Порог для позы подбирается по разбросу записанных примеров:
    /// если жест записали несколько разных людей или с разных ракурсов, порог мягче.
    private static func poseThreshold(for frames: [FrameFeatures]) -> Float {
        guard frames.count > 12 else { return 0.12 }
        var distances: [Float] = []
        for i in stride(from: 0, to: frames.count, by: 4) {
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
