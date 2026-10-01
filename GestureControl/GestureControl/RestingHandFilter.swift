import CoreGraphics
import Foundation

/// Опущенная вторая рука не участвует в распознавании.
///
/// Жест часто показывают одной рукой, а вторая лежит на столе или на коленях и всё равно видна
/// в кадре. Если её учитывать, жест одной рукой превращается в «жест двумя руками» и не узнаётся
/// (а при записи позы может записаться как жест двумя руками).
///
/// Рука считается опущенной, если одновременно:
/// • в кадре две руки, и эта рука заметно ниже другой (больше чем на `lowerBy` ладони);
/// • она внизу: ниже уровня груди (дальше `belowShoulders` расстояний между плечами от линии плеч),
///   в нижней части изображения или касается его нижнего края;
/// • она почти не двигается дольше `restTime` секунд.
/// Как только рука поднимается или начинает двигаться, она сразу снова учитывается —
/// жесты двумя руками работают как обычно. Одна рука в кадре учитывается всегда.
struct RestingHandFilter {
    /// Насколько ниже другой руки (в ладонях) должна быть опущенная рука.
    static let lowerBy: CGFloat = 1.5
    /// Ниже линии плеч больше чем на столько расстояний между плечами — уровень стола или колен.
    static let belowShoulders: CGFloat = 1.0
    /// Нижняя часть изображения (доля высоты).
    static let lowPart: CGFloat = 0.8
    /// Медленнее этого (ладоней в секунду) рука считается неподвижной…
    static let stillSpeed: CGFloat = 0.5
    /// …а быстрее этого — снова учитывается сразу.
    static let activeSpeed: CGFloat = 1.2
    /// Сколько секунд рука должна лежать неподвижно внизу, чтобы перестать учитываться.
    static let restTime: Double = 0.4

    private struct Track {
        var center: CGPoint
        var time: Double
        /// Скорость центра ладони, ладоней в секунду (сглажена).
        var speed: CGFloat
        var restingSince: Double?
        var resting: Bool
    }

    private var tracks: [Track] = []

    mutating func reset() {
        tracks = []
    }

    /// - Parameters:
    ///   - hands: руки на кадре (в координатах экрана);
    ///   - body: плечи, если найдены;
    ///   - viewHeight: высота изображения.
    /// - Returns: для каждой руки: true — учитывать.
    mutating func update(_ hands: [HandSample], body: BodyReference?, viewHeight: CGFloat, time: Double) -> [Bool] {
        var active = Array(repeating: true, count: hands.count)
        var newTracks: [Track] = []
        var used = Set<Int>()

        for (i, hand) in hands.enumerated() {
            let size = hand.palmSize
            guard size > 0 else { continue }
            let center = hand.center

            // Та же рука на прошлом кадре — ближайшая по центру ладони.
            var match: Int?
            var best = CGFloat.infinity
            for (j, track) in tracks.enumerated() where !used.contains(j) {
                let d = dist(track.center, center)
                if d < best {
                    best = d
                    match = j
                }
            }
            var track: Track
            if let j = match, best < max(size * 2, 60), time - tracks[j].time < 0.5 {
                used.insert(j)
                track = tracks[j]
            } else {
                track = Track(center: center, time: time, speed: 0, restingSince: nil, resting: false)
            }
            let dt = time - track.time
            if dt > 0 {
                let raw = dist(track.center, center) / size / CGFloat(dt)
                track.speed = track.speed * 0.6 + raw * 0.4
            }
            track.center = center
            track.time = time

            var lower = false
            if let other = hands.enumerated().first(where: { $0.offset != i && $0.element.palmSize > 0 })?.element {
                lower = center.y - other.center.y > Self.lowerBy * size
            }
            let low = lower && Self.isLow(hand, body: body, viewHeight: viewHeight)
            if !low || track.speed > Self.activeSpeed {
                track.restingSince = nil
                track.resting = false
            } else if track.speed < Self.stillSpeed {
                let since = track.restingSince ?? time
                track.restingSince = since
                if time - since >= Self.restTime { track.resting = true }
            }
            newTracks.append(track)
            active[i] = !track.resting
        }
        tracks = newTracks
        // Одна рука в кадре учитывается всегда.
        if hands.count < 2 { return Array(repeating: true, count: hands.count) }
        return active
    }

    private static func isLow(_ hand: HandSample, body: BodyReference?, viewHeight: CGFloat) -> Bool {
        let c = hand.center
        if let body, (c.y - body.center.y) / body.width > belowShoulders { return true }
        guard viewHeight > 0 else { return false }
        if c.y > viewHeight * lowPart { return true }
        // Рука лежит у нижнего края изображения (часть кисти за краем).
        return hand.points.contains { $0.x >= 0 && $0.y > viewHeight * 0.97 }
    }
}
