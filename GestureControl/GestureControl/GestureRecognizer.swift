import CoreGraphics
import Foundation

/// Индексы 21 ключевой точки кисти (в том порядке, в котором их отдаёт CameraManager).
enum Joint {
    static let wrist = 0
    static let thumbCMC = 1, thumbMP = 2, thumbIP = 3, thumbTip = 4
    static let indexMCP = 5, indexPIP = 6, indexDIP = 7, indexTip = 8
    static let middleMCP = 9, middlePIP = 10, middleDIP = 11, middleTip = 12
    static let ringMCP = 13, ringPIP = 14, ringDIP = 15, ringTip = 16
    static let littleMCP = 17, littlePIP = 18, littleDIP = 19, littleTip = 20
    static let count = 21
}

func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

// MARK: - Анализ положения кисти (статические жесты)

/// Геометрия кисти в экранных координатах (точки, ось Y направлена вниз).
struct HandGeometry {
    let p: [CGPoint]
    /// Размер ладони: расстояние от запястья до основания среднего пальца.
    /// Все пороги задаются относительно него, поэтому распознавание не зависит от расстояния до камеры.
    let size: CGFloat
    /// Центр ладони: используется для отслеживания движения.
    let center: CGPoint

    init?(points: [CGPoint]) {
        guard points.count == Joint.count else { return nil }
        let palm = [Joint.wrist, Joint.indexMCP, Joint.middleMCP, Joint.ringMCP, Joint.littleMCP]
        guard palm.allSatisfy({ points[$0].x >= 0 }) else { return nil }

        p = points
        size = dist(points[Joint.wrist], points[Joint.middleMCP])
        guard size > 10 else { return nil }

        let palmPoints = palm.map { points[$0] }
        let n = CGFloat(palmPoints.count)
        center = CGPoint(x: palmPoints.map(\.x).reduce(0, +) / n,
                         y: palmPoints.map(\.y).reduce(0, +) / n)
    }

    private func isValid(_ i: Int) -> Bool { p[i].x >= 0 }

    /// Палец выпрямлен, если его кончик заметно дальше от запястья, чем средний сустав.
    /// nil — точки не найдены.
    private func isFingerExtended(tip: Int, pip: Int) -> Bool? {
        guard isValid(tip), isValid(pip) else { return nil }
        let wrist = p[Joint.wrist]
        return dist(wrist, p[tip]) > dist(wrist, p[pip]) * 1.2
    }

    /// Большой палец отведён, если его кончик далеко от основания указательного.
    private var isThumbExtended: Bool {
        guard isValid(Joint.thumbTip) else { return false }
        return dist(p[Joint.thumbTip], p[Joint.indexMCP]) > size * 0.65
    }

    /// Кончики большого и указательного пальцев соединены в кольцо.
    private var isThumbIndexRing: Bool {
        guard isValid(Joint.thumbTip), isValid(Joint.indexTip) else { return false }
        return dist(p[Joint.thumbTip], p[Joint.indexTip]) < size * 0.35
    }

    func staticGesture() -> Gesture {
        guard let index = isFingerExtended(tip: Joint.indexTip, pip: Joint.indexPIP),
              let middle = isFingerExtended(tip: Joint.middleTip, pip: Joint.middlePIP),
              let ring = isFingerExtended(tip: Joint.ringTip, pip: Joint.ringPIP),
              let little = isFingerExtended(tip: Joint.littleTip, pip: Joint.littlePIP)
        else { return .idle }

        if isThumbIndexRing && middle && ring && little {
            return .ok
        }
        if index && middle && ring && little {
            return .openPalm
        }
        if index && middle && !ring && !little {
            return .victory
        }
        if index && !middle && !ring && !little {
            return .pointing
        }
        if !index && !middle && !ring && little && isThumbExtended {
            return .callMe
        }
        if !index && !middle && !ring && !little {
            if isThumbExtended {
                // Кончик большого пальца должен быть выше кулака и запястья.
                let top = min(p[Joint.indexMCP].y, p[Joint.wrist].y)
                if p[Joint.thumbTip].y < top - size * 0.3 {
                    return .thumbsUp
                }
            } else {
                return .fist
            }
        }
        return .idle
    }
}

// MARK: - Классификация жестов

struct RecognitionResult {
    /// Жест, который сейчас видит система.
    var sign: Sign = .none
    /// Жест, который только что сработал (срабатывает один раз).
    var fired: Sign? = nil
    /// Прогресс удержания статического жеста, 0…1.
    var holdProgress: Double = 0
}

/// Блоки схемы «Анализ положения и движения → Классификация жеста».
///
/// Защита от случайных срабатываний:
/// • статический жест нужно удерживать неподвижно `holdDuration` секунд;
/// • удерживаемый жест срабатывает один раз, повтор — только после смены жеста;
/// • после движения (свайпа) действует пауза `cooldown`, чтобы обратное движение руки не дало лишнюю команду;
/// • кратковременная потеря руки (до `lostHandTimeout`) не сбрасывает состояние.
struct GestureRecognizer {
    var holdDuration: Double = 0.4        // сек удержания статического жеста
    var swipeWindow: Double = 0.5         // за какое время должно произойти движение
    var swipeDistance: CGFloat = 1.5      // длина движения в размерах ладони
    var cooldown: Double = 0.9            // пауза после свайпа
    var lostHandTimeout: Double = 0.3     // допустимое исчезновение руки из кадра
    var swipesEnabled = true              // в режиме «Перевод» свайпы выключены

    private var track: [(time: Double, point: CGPoint)] = []
    private var handAppearedAt: Double?
    private var lastHandTime: Double = 0
    private var candidate: Sign = .none
    private var candidateSince: Double = 0
    private var candidateLastSeen: Double = 0
    private var latched: Sign = .none
    private var latchedLastSeen: Double = 0
    private var latchNextUntil: Double?
    private var cooldownUntil: Double = 0
    private var lastHandCount = 0

    mutating func reset() {
        track.removeAll()
        lastHandCount = 0
        handAppearedAt = nil
        candidate = .none
        latched = .none
        latchNextUntil = nil
    }

    /// После жеста с движением рука ещё какое-то время стоит в конечной позе.
    /// Эта поза не должна засчитываться как отдельное слово, поэтому первая распознанная
    /// поза (в течение 0,6 с) считается уже сработавшей.
    mutating func latchNextSign(at time: Double) {
        latchNextUntil = time + 0.6
    }

    /// - Parameters:
    ///   - hands: точки найденных рук (одна или две) в экранных координатах.
    ///   - classify: определяет статический жест по положению кистей
    ///     (встроенные правила и/или словарь пользовательских жестов).
    mutating func process(hands: [[CGPoint]],
                          time: Double,
                          classify: ([HandGeometry]) -> Sign) -> RecognitionResult {
        let geometries = hands.compactMap { HandGeometry(points: $0) }
        guard !geometries.isEmpty else {
            if time - lastHandTime > lostHandTimeout { reset() }
            return RecognitionResult()
        }
        lastHandTime = time
        if handAppearedAt == nil { handAppearedAt = time }

        // Если число рук изменилось, траекторию начинаем заново, чтобы не было ложных свайпов.
        if geometries.count != lastHandCount {
            track.removeAll()
            lastHandCount = geometries.count
        }

        // Движение отслеживаем по «ведущей» руке: той, что ближе к прошлому положению,
        // а в начале — по самой крупной (ближней к камере).
        let hand: HandGeometry
        if let previous = track.last?.point {
            hand = geometries.min { dist($0.center, previous) < dist($1.center, previous) }!
        } else {
            hand = geometries.max { $0.size < $1.size }!
        }

        // Пауза после динамического жеста.
        if time < cooldownUntil {
            track.removeAll()
            return RecognitionResult()
        }

        // Отслеживание положения руки во времени.
        let window = swipeWindow
        track.append((time: time, point: hand.center))
        track.removeAll { time - $0.time > window }

        // 1. Динамические жесты.
        if swipesEnabled, let appeared = handAppearedAt, time - appeared > 0.2,
           let swipe = detectSwipe(handSize: hand.size) {
            track.removeAll()
            candidate = .none
            latched = .none
            cooldownUntil = time + cooldown
            let sign = Sign.builtIn(swipe)
            return RecognitionResult(sign: sign, fired: sign, holdProgress: 1)
        }

        // Пока рука движется, статические жесты не распознаём.
        if isMoving(time: time, handSize: hand.size) {
            candidate = .none
            return RecognitionResult()
        }

        // 2. Статические жесты.
        let current = classify(geometries)

        if let until = latchNextUntil {
            if time > until {
                latchNextUntil = nil
            } else if current != .none {
                latchNextUntil = nil
                latched = current
                latchedLastSeen = time
            }
        }

        if latched != .none {
            if current == latched {
                latchedLastSeen = time
                return RecognitionResult(sign: current, holdProgress: 1)
            } else if time - latchedLastSeen > 0.3 {
                latched = .none
            }
        }

        if current == .none {
            // Жест «потерялся» на долю секунды (моргнула рука, дрогнул палец) — не начинаем заново.
            if candidate != .none, time - candidateLastSeen < 0.15 {
                let progress = min(1, (time - candidateSince) / holdDuration)
                return RecognitionResult(sign: candidate, holdProgress: min(progress, 0.99))
            }
            candidate = .none
            return RecognitionResult()
        }

        if candidate != current {
            candidate = current
            candidateSince = time
        }
        candidateLastSeen = time

        let progress = min(1, (time - candidateSince) / holdDuration)
        if progress >= 1 {
            latched = current
            latchedLastSeen = time
            candidate = .none
            return RecognitionResult(sign: current, fired: current, holdProgress: 1)
        }
        return RecognitionResult(sign: current, holdProgress: progress)
    }

    private func detectSwipe(handSize: CGFloat) -> Gesture? {
        guard let first = track.first, let last = track.last,
              last.time - first.time > 0.08 else { return nil }

        let dx = last.point.x - first.point.x
        let dy = last.point.y - first.point.y
        let threshold = handSize * swipeDistance

        if abs(dx) > threshold && abs(dx) > abs(dy) * 1.8 {
            return dx > 0 ? .swipeRight : .swipeLeft
        }
        if abs(dy) > threshold && abs(dy) > abs(dx) * 1.8 {
            return dy > 0 ? .swipeDown : .swipeUp
        }
        return nil
    }

    private func isMoving(time: Double, handSize: CGFloat) -> Bool {
        guard let last = track.last,
              let reference = track.last(where: { time - $0.time >= 0.15 }) else { return false }
        return dist(reference.point, last.point) > handSize * 0.3
    }
}
