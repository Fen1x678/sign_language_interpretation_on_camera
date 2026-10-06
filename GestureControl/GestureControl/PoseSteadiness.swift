import Foundation

/// Поза распознаётся, только когда форма кисти устоялась.
///
/// Между двумя жестами пальцы меняют положение, и на долю секунды кисть может быть похожа
/// на какое-нибудь слово словаря. Пока форма кисти заметно меняется (больше `maxChange`
/// за `window` секунд — это больше обычного дрожания точек), поза не распознаётся.
struct PoseSteadiness {
    var window: Double = 0.15
    var maxChange: Float = 0.09

    private var history: [(time: Double, features: FrameFeatures)] = []

    mutating func reset() {
        history.removeAll()
    }

    /// - Parameter features: поза в кадре (nil — рук нет).
    /// - Returns: true, если форма кисти не меняется (или рука только появилась и сравнивать пока не с чем).
    mutating func update(_ features: FrameFeatures?, time: Double) -> Bool {
        guard let features else {
            history.removeAll()
            return false
        }
        history.append((time: time, features: features))
        while history.count > 1, let first = history.first, time - first.time > 0.5 {
            history.removeFirst()
        }
        guard let reference = history.last(where: { time - $0.time >= window }) else { return true }
        let change = FrameFeatures.handShapeDistance(features, reference.features)
        // Изменилось число рук — сравнивать нельзя, решает удержание жеста.
        guard change.isFinite else { return true }
        return change <= maxChange
    }
}
