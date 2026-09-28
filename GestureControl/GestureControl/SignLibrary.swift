import SwiftUI
import Combine

/// Жест, которому пользователь обучил приложение.
/// Может быть статичным (поза кисти) и/или с движением (последовательность кадров).
struct CustomSign: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    /// Статичный жест: примеры позы, каждый — вектор признаков одного кадра.
    var samples: [[Float]] = []
    /// Жест с движением: записанные примеры, каждый — последовательность кадров.
    var sequences: [[[Float]]] = []

    var isDynamic: Bool { !sequences.isEmpty }

    /// Сколько рук в жесте (определяется по длине вектора признаков).
    var handCount: Int {
        let length = samples.first?.count ?? sequences.first?.first?.count ?? HandFeatures.oneHandLength
        return length > MotionFeatures.oneHandFrameLength ? 2 : 1
    }

    var exampleCount: Int { isDynamic ? sequences.count : samples.count }

    init(word: String, samples: [[Float]] = [], sequences: [[[Float]]] = []) {
        self.word = word
        self.samples = samples
        self.sequences = sequences
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        samples = try c.decodeIfPresent([[Float]].self, forKey: .samples) ?? []
        sequences = try c.decodeIfPresent([[[Float]]].self, forKey: .sequences) ?? []
    }
}

// MARK: - Признаки позы

enum HandFeatures {
    static let oneHandLength = (Joint.count - 1) * 2   // 40

    /// Признаки позы одной или двух рук.
    /// Две руки: признаки левой (на экране) руки + правой + положение правой относительно левой → 82 числа.
    static func signVector(from hands: [HandGeometry]) -> [Float]? {
        let sorted = hands.sorted { $0.center.x < $1.center.x }
        if sorted.count >= 2 {
            let a = sorted[0], b = sorted[1]
            guard let va = handVector(from: a), let vb = handVector(from: b) else { return nil }
            let scale = (a.size + b.size) / 2
            let relative: [Float] = [Float((b.center.x - a.center.x) / scale),
                                     Float((b.center.y - a.center.y) / scale)]
            return va + vb + relative
        }
        guard let one = sorted.first else { return nil }
        return handVector(from: one)
    }

    /// 20 точек кисти относительно запястья, в размерах ладони → 40 чисел.
    /// Нормировка делает признаки независимыми от положения руки в кадре и расстояния до камеры.
    static func handVector(from hand: HandGeometry) -> [Float]? {
        guard hand.p.allSatisfy({ $0.x >= 0 }) else { return nil }
        let origin = hand.p[Joint.wrist]
        var v: [Float] = []
        v.reserveCapacity(oneHandLength)
        for i in 1..<Joint.count {
            v.append(Float((hand.p[i].x - origin.x) / hand.size))
            v.append(Float((hand.p[i].y - origin.y) / hand.size))
        }
        return v
    }

    /// Среднее расстояние между соответствующими точками двух векторов (в размерах ладони).
    /// Векторы разной длины (разное число рук) не сравниваются — расстояние бесконечно.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Float = 0
        var i = 0
        while i + 1 < a.count {
            let dx = a[i] - b[i]
            let dy = a[i + 1] - b[i + 1]
            sum += (dx * dx + dy * dy).squareRoot()
            i += 2
        }
        return sum / Float(a.count / 2)
    }
}

// MARK: - Признаки движения и DTW

enum MotionFeatures {
    /// Во сколько раз движение руки важнее формы кисти при сравнении.
    static let motionWeight: Float = 3
    static let oneHandFrameLength = HandFeatures.oneHandLength + 2   // 42

    /// Кадр жеста с движением: поза рук + смещение ведущей руки с прошлого кадра (в размерах ладони).
    static func frame(shape: [Float], dx: CGFloat, dy: CGFloat) -> [Float] {
        shape + [Float(dx) * motionWeight, Float(dy) * motionWeight]
    }

    static func frameDistance(_ a: [Float], _ b: [Float]) -> Float {
        a.count == b.count ? HandFeatures.distance(a, b) : 1.5
    }

    /// Подготовка записанного жеста: убираем неподвижные кадры в начале и в конце,
    /// берём каждый второй кадр и ограничиваем длину.
    static func prepareTemplate(_ frames: [[Float]]) -> [[Float]] {
        func motion(_ f: [Float]) -> Float {
            guard f.count >= 2 else { return 0 }
            let dx = f[f.count - 2], dy = f[f.count - 1]
            return (dx * dx + dy * dy).squareRoot()
        }
        let threshold: Float = 0.03 * motionWeight
        var start = 0
        var end = frames.count - 1
        while start < end && motion(frames[start]) < threshold { start += 1 }
        while end > start && motion(frames[end]) < threshold { end -= 1 }
        // Оставляем немного кадров до и после движения.
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
    /// ищет, насколько конец потока кадров похож на шаблон жеста, допуская разную скорость показа.
    /// Возвращает среднюю стоимость на кадр шаблона (меньше — похоже сильнее).
    static func subsequenceDTW(template t: [[Float]], stream s: [[Float]]) -> Float {
        let n = t.count, m = s.count
        guard n > 1, m > 1 else { return .infinity }
        var prev = [Float](repeating: .infinity, count: m)
        var cur = [Float](repeating: .infinity, count: m)
        for j in 0..<m { prev[j] = frameDistance(t[0], s[j]) }   // жест может начаться где угодно
        for i in 1..<n {
            cur[0] = prev[0] + frameDistance(t[i], s[0])
            for j in 1..<m {
                cur[j] = frameDistance(t[i], s[j]) + min(prev[j], prev[j - 1], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[m - 1] / Float(n)   // жест должен закончиться на последнем кадре
    }
}

// MARK: - Словарь

/// Словарь пользовательских жестов и классификаторы:
/// • статичные жесты — метод ближайшего соседа (k-NN) по позе;
/// • жесты с движением — сравнение последовательностей методом DTW.
/// Словарь сохраняется на телефоне.
@MainActor
final class SignLibrary: ObservableObject {
    @Published private(set) var signs: [CustomSign] = []

    /// Порог совпадения позы (среднее отклонение точек в размерах ладони).
    var poseThreshold: Float = 0.22
    /// Порог совпадения жеста с движением (средняя стоимость DTW на кадр).
    var motionThreshold: Float = 0.33

    var hasDynamicSigns: Bool { signs.contains { $0.isDynamic } }

    private let fileURL = URL.documentsDirectory.appending(path: "custom_signs.json")

    init() {
        load()
    }

    /// Добавляет пример позы. Если слово уже есть, пример добавляется к нему.
    func add(word: String, samples: [[Float]]) {
        if let i = index(of: word) {
            signs[i].samples += samples
        } else {
            signs.append(CustomSign(word: word, samples: samples))
        }
        save()
    }

    /// Добавляет пример жеста с движением.
    func addSequence(word: String, sequence: [[Float]]) {
        if let i = index(of: word) {
            signs[i].sequences.append(sequence)
        } else {
            signs.append(CustomSign(word: word, sequences: [sequence]))
        }
        save()
    }

    func delete(at offsets: IndexSet) {
        signs.remove(atOffsets: offsets)
        save()
    }

    private func index(of word: String) -> Int? {
        signs.firstIndex { $0.word.lowercased() == word.lowercased() }
    }

    /// Статичный жест по позе рук.
    func classifyPose(_ vector: [Float]) -> CustomSign? {
        pickBest(threshold: poseThreshold) { sign in
            sign.samples.map { HandFeatures.distance(vector, $0) }.min() ?? .infinity
        }
    }

    /// Жест с движением по последним кадрам.
    func classifyMotion(_ stream: [[Float]]) -> CustomSign? {
        pickBest(threshold: motionThreshold) { sign in
            sign.sequences.map { MotionFeatures.subsequenceDTW(template: $0, stream: stream) }.min() ?? .infinity
        }
    }

    /// Выбирает самый похожий жест, если он достаточно похож и явно лучше второго по сходству.
    private func pickBest(threshold: Float, cost: (CustomSign) -> Float) -> CustomSign? {
        var best: CustomSign?
        var bestCost = Float.infinity
        var secondCost = Float.infinity

        for sign in signs {
            let c = cost(sign)
            if c < bestCost {
                secondCost = bestCost
                bestCost = c
                best = sign
            } else if c < secondCost {
                secondCost = c
            }
        }

        guard let best, bestCost < threshold else { return nil }
        if secondCost < bestCost * 1.15 { return nil }   // неоднозначно — не угадываем
        return best
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([CustomSign].self, from: data) else { return }
        signs = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(signs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
