import Foundation

// MARK: - Признаки, одинаковые для разных людей

/// Признаки кадра, почти не зависящие от размера руки, длины пальцев и расстояния до камеры.
///
/// На каждую руку 31 число:
/// • 15 углов сгиба суставов (по 3 на палец);
/// • 4 угла между соседними пальцами (насколько пальцы разведены);
/// • 4 расстояния от кончика большого пальца до кончиков остальных (кольца, щепоти);
/// • 5 «вытянутостей» пальцев — расстояние от запястья до кончика: сжатый палец ближе к запястью,
///   даже если направлен прямо в камеру и углы сгиба не видны;
/// • сторона ладони (к камере ладонью или тыльной стороной) — с учётом того, правая это рука или левая:
///   в 2D ладонь правой руки выглядит так же, как тыльная сторона левой;
/// • направление кисти (куда «смотрят» пальцы), 2 числа.
/// Для двух рук добавляется положение правой руки относительно левой.
///
/// У каждого признака есть вес. Углы сгиба в 2D шумные (палец может смотреть в камеру), поэтому
/// их вес меньше. Если точки видны плохо (палец скрыт при повороте), признак учитывается слабее;
/// если кость направлена в камеру и угол измерить нельзя — не учитывается совсем.
struct FrameFeatures {
    static let handLength = 31
    static let orientX = 29

    static let handWeights: [Float] = {
        var w: [Float] = [0.18, 0.3, 0.15]                 // большой палец: CMC, MP, IP
        for _ in 0..<4 { w += [0.3, 0.3, 0.15] }           // остальные: MCP, PIP, DIP
        w += [1.05, 1.5, 1.5, 1.5]                         // разведение пальцев
        w += [1.5, 1.5, 1.5, 1.5]                          // большой палец → кончики
        w += [1.5, 1.5, 1.5, 1.5, 1.5]                     // вытянутость пальцев
        w += [0.4]                                         // сторона ладони
        w += [0.6, 0.6]                                    // направление кисти
        return w
    }()

    /// Признаки рук (слева направо) и, для двух рук, их взаимное положение.
    private(set) var values: [Float]
    /// Вес каждого признака с учётом того, насколько уверенно видны точки (0 — не учитывать).
    private(set) var weights: [Float]
    private(set) var handCount: Int
    /// Какая это рука (для каждой руки): +1 правая, −1 левая, 0 — неизвестно.
    private(set) var chirality: [Int]
    /// Направление движения ведущей руки (2 числа, от −1 до 1). Пусто для позы.
    private(set) var motion: [Float]

    init(_ frame: SignFrame) {
        var values: [Float] = []
        var weights: [Float] = []
        for hand in frame.hands {
            let (v, r) = Self.handFeatures(hand)
            values += v
            weights += zip(Self.handWeights, r).map { $0 * $1 }
        }
        if frame.hands.count == 2, frame.relative.count == 2 {
            values += frame.relative.map { min(max($0 / 4, -1.5), 1.5) }
            weights += [1, 1]
        }
        self.values = values
        self.weights = weights
        handCount = frame.hands.count
        chirality = frame.hands.map { $0.chirality ?? 0 }
        motion = Self.motionFeatures(frame)
    }

    /// Зеркальное отражение: жест левой руки ↔ тот же жест правой рукой.
    func mirrored() -> FrameFeatures {
        var m = self
        let n = Self.handLength
        if handCount == 2 && values.count >= 2 * n {
            // Левая и правая руки меняются местами.
            let first = 0..<n, second = n..<(2 * n)
            m.values.replaceSubrange(first, with: values[second])
            m.values.replaceSubrange(second, with: values[first])
            m.weights.replaceSubrange(first, with: weights[second])
            m.weights.replaceSubrange(second, with: weights[first])
            if values.count == 2 * n + 2 { m.values[2 * n + 1] = -values[2 * n + 1] }
        }
        for h in 0..<handCount where (h + 1) * n <= m.values.count {
            m.values[h * n + Self.orientX] = -m.values[h * n + Self.orientX]
        }
        m.chirality = chirality.reversed().map { -$0 }
        if motion.count == 2 { m.motion = [-motion[0], motion[1]] }
        return m
    }

    /// Какая рука показывает жест: +1 правая, −1 левая, 0 — неизвестно или две руки.
    var mainChirality: Int { handCount == 1 ? chirality[0] : 0 }

    /// Скорость ведущей руки, ладоней в секунду.
    var speed: Float {
        guard motion.count == 2 else { return 0 }
        let r = min(0.999, (motion[0] * motion[0] + motion[1] * motion[1]).squareRoot())
        return SignMatching.referenceSpeed * r / (1 - r * r).squareRoot()
    }

    // MARK: Расстояния

    /// Насколько непохожи позы рук: взвешенное среднеквадратичное отличие признаков (0 — одинаковые).
    /// Позы с разным числом рук не сравниваются — расстояние бесконечно.
    static func shapeDistance(_ a: FrameFeatures, _ b: FrameFeatures) -> Float {
        let n = a.values.count
        guard a.handCount == b.handCount, n == b.values.count, n > 0 else { return .infinity }
        var num: Float = 0
        var den: Float = 0
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                a.weights.withUnsafeBufferPointer { aw in
                    b.weights.withUnsafeBufferPointer { bw in
                        for i in 0..<n {
                            let w = min(aw[i], bw[i])
                            guard w > 0 else { continue }
                            let d = av[i] - bv[i]
                            num += w * d * d
                            den += w
                        }
                    }
                }
            }
        }
        return den > 0 ? (num / den).squareRoot() : .infinity
    }

    /// Расстояние между кадрами жеста с движением: форма рук и направление движения.
    static func distance(_ a: FrameFeatures, _ b: FrameFeatures) -> Float {
        guard a.handCount == b.handCount, a.motion.count == 2, b.motion.count == 2 else {
            return SignMatching.mismatchPenalty
        }
        let shape = shapeDistance(a, b)
        let dx = a.motion[0] - b.motion[0], dy = a.motion[1] - b.motion[1]
        let motion = ((dx * dx + dy * dy) / 2).squareRoot()
        let share = SignMatching.motionShare
        return (1 - share) * (shape.isFinite ? shape : SignMatching.mismatchPenalty) + share * motion
    }

    // MARK: Вычисление признаков

    private static let chains: [[Int]] = [
        [0, 1, 2, 3, 4],       // большой
        [0, 5, 6, 7, 8],       // указательный
        [0, 9, 10, 11, 12],    // средний
        [0, 13, 14, 15, 16],   // безымянный
        [0, 17, 18, 19, 20]    // мизинец
    ]
    /// Кость короче этой доли ладони смотрит в камеру: угол при ней не измеряем.
    private static let minBone: Float = 0.12

    private static func length(_ v: SIMD2<Float>) -> Float {
        (v.x * v.x + v.y * v.y).squareRoot()
    }

    /// Угол между векторами, 0…1 (0 — одно направление, 1 — противоположные).
    private static func angle(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        atan2(abs(a.x * b.y - a.y * b.x), a.x * b.x + a.y * b.y) / Float.pi
    }

    /// Признаки одной кисти и их надёжность (0…1).
    private static func handFeatures(_ pose: HandPose) -> ([Float], [Float]) {
        func pt(_ i: Int) -> SIMD2<Float> { SIMD2(pose.points[2 * i], pose.points[2 * i + 1]) }
        func seen(_ joints: [Int]) -> Float { joints.map { pose.weight($0) }.min() ?? 1 }

        var v: [Float] = []
        var r: [Float] = []
        v.reserveCapacity(handLength)
        r.reserveCapacity(handLength)
        let size = max(1e-4, length(pt(9) - pt(0)))

        // 1. Сгиб суставов: угол между соседними костями пальца.
        for chain in chains {
            for k in 1...3 {
                let a = pt(chain[k]) - pt(chain[k - 1])
                let b = pt(chain[k + 1]) - pt(chain[k])
                if length(a) < minBone * size || length(b) < minBone * size {
                    v.append(0)
                    r.append(0)
                } else {
                    v.append(angle(a, b))
                    r.append(seen([chain[k - 1], chain[k], chain[k + 1]]))
                }
            }
        }

        // 2. Разведение пальцев: угол между направлениями соседних пальцев.
        //    У согнутого пальца направление не определено — признак не учитываем.
        let axes: [SIMD2<Float>?] = chains.map { chain in
            let d = pt(chain[4]) - pt(chain[1])
            return length(d) >= 0.3 * size ? d : nil
        }
        for i in 0..<4 {
            if let a = axes[i], let b = axes[i + 1] {
                v.append(angle(a, b))
                r.append(seen([chains[i][1], chains[i][4], chains[i + 1][1], chains[i + 1][4]]))
            } else {
                v.append(0)
                r.append(0)
            }
        }

        // 3. Расстояния от кончика большого пальца до остальных кончиков.
        for tip in [8, 12, 16, 20] {
            v.append(min(length(pt(4) - pt(tip)) / size, 1.5) / 1.5)
            r.append(seen([4, tip]))
        }

        // 4. Вытянутость пальцев: расстояние от запястья до кончика.
        for tip in [4, 8, 12, 16, 20] {
            v.append(min(length(pt(tip) - pt(0)) / size, 2.5) / 2.5)
            r.append(seen([0, tip]))
        }

        // 5. Ладонь или тыльная сторона. Без знания, какая это рука, признак бессмыслен.
        let a = pt(5) - pt(0), b = pt(17) - pt(0)
        let side = min(max((a.x * b.y - a.y * b.x) / (size * size) / 0.25, -1), 1)
        if let chirality = pose.chirality, chirality != 0 {
            v.append(side * Float(chirality))
            r.append(seen([0, 5, 17]))
        } else {
            v.append(0)
            r.append(0)
        }

        // 6. Направление кисти: запястье → основание среднего пальца.
        let d = (pt(9) - pt(0)) / size
        v += [d.x, d.y]
        r += [seen([0, 9]), seen([0, 9])]
        return (v, r)
    }

    /// Направление движения: скорость v (ладоней в секунду), сжатая как v / √(|v|² + v₀²).
    /// Важнее направление, чем скорость: жест, показанный быстрее или медленнее, остаётся похожим.
    private static func motionFeatures(_ frame: SignFrame) -> [Float] {
        var v: SIMD2<Float>
        if let raw = frame.rawVelocity, raw.count == 2 {
            v = SIMD2(raw[0], raw[1])
        } else if frame.velocity.count == 2 {
            // Запись прошлой версии: скорость была поделена на max(|v|, 1,5).
            let u = SIMD2(frame.velocity[0], frame.velocity[1])
            v = length(u) < 0.999 ? u * SignMatching.referenceSpeed : u * 3
        } else {
            return []
        }
        let k = 1 / (length(v) * length(v) + SignMatching.referenceSpeed * SignMatching.referenceSpeed).squareRoot()
        v *= k
        return [v.x, v.y]
    }
}

// MARK: - Движение и DTW

enum SignMatching {
    /// Базовые пороги сходства (для слова с одной записью, при средней чувствительности).
    static let basePoseThreshold: Float = 0.10
    static let baseMotionThreshold: Float = 0.11
    /// Порог для слова не больше базового × это число, даже если записи сильно разные.
    static let maxThresholdGrowth: Float = 1.6
    /// Если второе по сходству слово похоже почти так же (в пределах этого множителя), жест не засчитывается.
    static let ambiguityRatio: Float = 1.1
    /// Во сколько раз мягче порог для жеста, который уже распознаётся.
    static let stickyFactor: Float = 1.3
    /// Сколько ближайших кадров позы усредняется (k в k-NN).
    static let poseNeighbours = 3

    /// Частота кадров последовательностей (записанных и текущих), кадров в секунду.
    static let sampleRate: Double = 15
    /// Скорость (ладоней в секунду), при которой признак движения равен ~0,7.
    static let referenceSpeed: Float = 1.5
    /// Доля движения в расстоянии между кадрами (остальное — форма рук).
    static let motionShare: Float = 0.4
    /// Расстояние между кадрами с разным числом рук.
    static let mismatchPenalty: Float = 0.6
    /// Во сколько раз дешевле кадр, когда жест показан медленнее записанного.
    static let slowStepWeight: Float = 0.5
    /// Не длиннее 2,4 с.
    static let maxTemplateLength = 36
    /// Порог «активности» кадра: рука движется или меняет форму.
    static let activeThreshold: Float = 0.6

    /// Элементы с равным шагом по времени (`sampleRate`), последний — самый свежий.
    /// Так последовательность не зависит от того, сколько кадров в секунду выдаёт камера.
    static func resample<T>(_ items: [(time: Double, item: T)]) -> [T] {
        guard let first = items.first, let last = items.last else { return [] }
        let count = Int((last.time - first.time) * sampleRate) + 1
        var result: [T] = []
        result.reserveCapacity(count)
        var j = items.count - 1
        for k in 0..<count {
            let t = last.time - Double(k) / sampleRate
            while j > 0 && abs(items[j - 1].time - t) <= abs(items[j].time - t) {
                j -= 1
            }
            result.append(items[j].item)
        }
        return Array(result.reversed())
    }

    /// `count` элементов, равномерно выбранных из массива.
    static func evenlySpaced<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 1 else { return items }
        let step = Double(items.count - 1) / Double(count - 1)
        return (0..<count).map { items[Int((Double($0) * step).rounded())] }
    }

    /// «Активность» каждого кадра: скорость руки и скорость изменения формы кисти.
    /// Нужна, чтобы неподвижная рука не принималась за жест с движением.
    static func activity(of sequence: [FrameFeatures]) -> (speed: [Float], shape: [Float]) {
        var speed: [Float] = []
        var shape: [Float] = []
        speed.reserveCapacity(sequence.count)
        shape.reserveCapacity(sequence.count)
        for i in sequence.indices {
            speed.append(sequence[i].speed)
            let j = max(0, i - 2)
            var rate: Float = 0
            if i > j {
                let d = FrameFeatures.shapeDistance(sequence[i], sequence[j])
                if d.isFinite { rate = d * Float(sampleRate) / Float(i - j) }
            }
            // Меньше 0,25 в секунду — дрожание точек, а не смена формы.
            shape.append(3 * max(0, rate - 0.25))
        }
        return (speed, shape)
    }

    /// Подготовка записанного жеста: равный шаг по времени, обрезка неподвижных кадров
    /// в начале и в конце, ограничение длины.
    static func prepareTemplate(_ frames: [(time: Double, item: SignFrame)]) -> [SignFrame] {
        var sequence = resample(frames)
        let (speed, shape) = activity(of: sequence.map(FrameFeatures.init))
        let active = sequence.indices.filter { speed[$0] + shape[$0] > activeThreshold }
        if active.count >= 3, let first = active.first, let last = active.last {
            sequence = Array(sequence[max(0, first - 2)...min(sequence.count - 1, last + 1)])
        }
        return evenlySpaced(sequence, count: maxTemplateLength)
    }

    /// В записанном жесте почти не было движения и смены формы.
    static func isMostlyStill(_ frames: [SignFrame]) -> Bool {
        let (speed, shape) = activity(of: frames.map(FrameFeatures.init))
        return zip(speed, shape).filter { $0 + $1 > activeThreshold }.count < 3
    }

    /// Какая рука показывает жест: +1 правая, −1 левая, 0 — неизвестно или две руки.
    static func chirality(of frames: [FrameFeatures]) -> Int {
        let values = frames.filter { $0.handCount == 1 }.map { Float($0.mainChirality) }
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        return mean > 0.5 ? 1 : (mean < -0.5 ? -1 : 0)
    }

    /// DTW (динамическая трансформация временной шкалы) с открытым началом:
    /// насколько конец потока кадров похож на шаблон жеста, с учётом разной скорости показа.
    /// Возвращает среднюю стоимость на кадр шаблона (меньше — похоже сильнее) и номер кадра потока,
    /// с которого начинается найденный жест. `abandonAbove` — если результат заведомо хуже,
    /// расчёт прекращается досрочно (ускорение).
    static func subsequenceDTW(template t: [FrameFeatures], stream s: [FrameFeatures],
                               abandonAbove: Float = .infinity) -> (cost: Float, start: Int) {
        let n = t.count, m = s.count
        guard n > 1, m > 1 else { return (.infinity, 0) }
        let limit = abandonAbove * Float(n)
        var prev = [Float](repeating: 0, count: m)
        var cur = [Float](repeating: 0, count: m)
        var prevStart = Array(0..<m)   // жест может начаться на любом кадре потока
        var curStart = [Int](repeating: 0, count: m)
        for j in 0..<m { prev[j] = FrameFeatures.distance(t[0], s[j]) }
        for i in 1..<n {
            cur[0] = prev[0] + FrameFeatures.distance(t[i], s[0])
            curStart[0] = prevStart[0]
            var rowMin = cur[0]
            for j in 1..<m {
                let d = FrameFeatures.distance(t[i], s[j])
                let faster = prev[j] + d                      // шаблон идёт дальше, поток стоит
                let same = prev[j - 1] + d                    // оба идут дальше
                let slower = cur[j - 1] + slowStepWeight * d  // поток идёт дальше, шаблон стоит
                if faster <= same && faster <= slower {
                    cur[j] = faster
                    curStart[j] = prevStart[j]
                } else if same <= slower {
                    cur[j] = same
                    curStart[j] = prevStart[j - 1]
                } else {
                    cur[j] = slower
                    curStart[j] = curStart[j - 1]
                }
                if cur[j] < rowMin { rowMin = cur[j] }
            }
            if rowMin > limit { return (.infinity, 0) }   // дальше будет только хуже
            swap(&prev, &cur)
            swap(&prevStart, &curStart)
        }
        // Жест должен закончиться на последнем кадре потока.
        return (prev[m - 1] / Float(n), prevStart[m - 1])
    }
}

// MARK: - Шаблон и поток для жестов с движением

/// Записанный жест с движением, подготовленный для сравнения.
struct MotionTemplate {
    let frames: [FrameFeatures]
    let handCount: Int
    /// Средняя скорость руки (ладоней в секунду).
    let speedActivity: Float
    /// Средняя скорость изменения формы кисти.
    let shapeActivity: Float
    /// Какой рукой записан: +1 правая, −1 левая, 0 — неизвестно или две руки.
    let chirality: Int

    init?(_ frames: [SignFrame]) {
        guard frames.count >= 2 else { return nil }
        let features = frames.map(FrameFeatures.init)
        let activity = SignMatching.activity(of: features)
        self.frames = features
        handCount = features[features.count - 1].handCount
        speedActivity = activity.speed.reduce(0, +) / Float(features.count)
        shapeActivity = activity.shape.reduce(0, +) / Float(features.count)
        chirality = SignMatching.chirality(of: features)
    }

    /// Стоимость DTW шаблона на конце потока с дополнительными проверками:
    /// • жест показан не больше чем в 2 раза быстрее записанного
    ///   (иначе кусок другого жеста, например часть круга, сойдёт за короткий жест);
    /// • в найденном отрезке есть движение и/или смена формы, как в шаблоне
    ///   (неподвижная рука не должна совпадать с жестом с движением).
    func cost(on stream: MotionStream, abandonAbove: Float = .infinity) -> Float {
        guard stream.handCount == handCount else { return .infinity }
        let candidates: [[FrameFeatures]]
        if chirality != 0 && stream.chirality != 0 {
            // Известно, какой рукой записан и показан жест: сравниваем только подходящий вариант,
            // поэтому жесты «влево» и «вправо» не путаются.
            candidates = [chirality == stream.chirality ? stream.frames : stream.mirrored]
        } else {
            candidates = [stream.frames, stream.mirrored]
        }
        var best = Float.infinity
        for frames in candidates {
            let (cost, start) = SignMatching.subsequenceDTW(template: self.frames, stream: frames,
                                                            abandonAbove: min(best, abandonAbove))
            guard cost < best else { continue }
            let segment = frames.count - start
            if Float(segment) < 0.5 * Float(self.frames.count) { continue }
            let speed = stream.speed[start...].reduce(0, +) / Float(segment)
            let shape = stream.shape[start...].reduce(0, +) / Float(segment)
            if speedActivity > 0.5 && speed < 0.4 * speedActivity { continue }
            if shapeActivity > 0.3 && shape < 0.4 * shapeActivity { continue }
            best = cost
        }
        return best
    }
}

/// Последние кадры, подготовленные для сравнения со всеми шаблонами.
struct MotionStream {
    let frames: [FrameFeatures]
    let mirrored: [FrameFeatures]
    let speed: [Float]
    let shape: [Float]
    let chirality: Int
    let handCount: Int

    init(_ frames: [FrameFeatures]) {
        self.frames = frames
        mirrored = frames.map { $0.mirrored() }
        let activity = SignMatching.activity(of: frames)
        speed = activity.speed
        shape = activity.shape
        chirality = SignMatching.chirality(of: frames)
        handCount = frames.last?.handCount ?? 0
    }
}

/// Выбор момента, когда засчитать жест с движением.
///
/// Когда жест только заканчивается, сходство с шаблоном ещё растёт несколько кадров.
/// Поэтому жест засчитывается не сразу, а когда сходство перестало расти
/// (или жест закончился, или прошло `maxWait` секунд). Так точнее выбирается слово.
struct MotionSpotter {
    struct Match: Equatable {
        let id: UUID
        /// Стоимость относительно порога слова: меньше 1 — жест подходит.
        let cost: Float
    }

    var maxWait: Double = 0.3
    private var pending: (id: UUID, cost: Float, since: Double)?

    mutating func reset() {
        pending = nil
    }

    /// - Parameter best: лучший подходящий жест на этом кадре (nil — ни один не подходит).
    /// - Returns: жест, который нужно засчитать сейчас.
    mutating func update(best: Match?, time: Double) -> UUID? {
        guard let current = pending else {
            if let best { pending = (best.id, best.cost, time) }
            return nil
        }
        guard let best else {
            pending = nil
            return current.id   // жест закончился
        }
        if best.id == current.id {
            if best.cost > current.cost {
                pending = nil
                return current.id   // сходство перестало расти
            }
            pending = (current.id, best.cost, current.since)
        } else if best.cost < current.cost {
            pending = (best.id, best.cost, time)   // другое слово подходит лучше
        }
        if let waiting = pending, time - waiting.since >= maxWait {
            pending = nil
            return waiting.id
        }
        return nil
    }
}
