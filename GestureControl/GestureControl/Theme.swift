import SwiftUI

/// Мягкое оформление: приглушённые цвета, скруглённые карточки, крупные кнопки.
/// Цвета не режут глаз в темноте и не спорят с изображением камеры.
enum Soft {
    /// Основной цвет: мягкий бирюзовый.
    static let accent = Color(red: 0.42, green: 0.78, blue: 0.74)
    /// «Всё хорошо»: мятный.
    static let ok = Color(red: 0.55, green: 0.86, blue: 0.64)
    /// «Подождите / ещё звучит»: тёплый янтарный.
    static let warm = Color(red: 1.0, green: 0.80, blue: 0.48)
    /// «Внимание»: персиковый вместо резкого красного.
    static let alert = Color(red: 1.0, green: 0.56, blue: 0.50)
    /// Нейтральный: серо-сиреневый.
    static let muted = Color(red: 0.62, green: 0.62, blue: 0.72)
    /// Фон страниц: тёмно-синий, мягче чёрного.
    static let background = Color(red: 0.07, green: 0.08, blue: 0.11)
    /// Фон карточек на страницах.
    static let card = Color.white.opacity(0.06)

    static let cornerRadius: CGFloat = 26
    /// Кнопки не меньше 46 точек — по ним легко попасть.
    static let buttonSize: CGFloat = 46

    /// Плавная анимация для всего интерфейса.
    static let animation = Animation.smooth(duration: 0.35)
}

extension View {
    /// Мягкая карточка поверх камеры: матовое стекло, тонкая светлая кромка и лёгкая тень.
    func softCard(cornerRadius: CGFloat = Soft.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    /// Капсула-подпись (состояние, подсказка).
    func softChip(_ tint: Color? = nil) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if let tint {
                    Capsule().fill(tint.opacity(0.28))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder((tint ?? .white).opacity(0.25), lineWidth: 1))
    }
}

/// Круглая кнопка с иконкой: матовая, при нажатии мягко уменьшается.
struct SoftIconButtonStyle: ButtonStyle {
    var size: CGFloat = Soft.buttonSize
    /// Заливка кружка (nil — матовое стекло).
    var tint: Color? = nil
    /// Цвет иконки на матовом стекле.
    var iconColor: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(tint == nil ? iconColor : Color.black.opacity(0.8))
            .frame(width: size, height: size)
            .background {
                if let tint {
                    Circle().fill(tint)
                } else {
                    Circle().fill(.ultraThinMaterial)
                }
            }
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Кнопка-капсула с подписью: мягко окрашенная, крупная.
struct SoftPillButtonStyle: ButtonStyle {
    var tint: Color = Soft.accent
    /// true — заливка цветом (главное действие), false — лёгкий оттенок.
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.82) : tint)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Capsule().fill(prominent ? tint : tint.opacity(0.18)))
            .overlay(Capsule().strokeBorder(tint.opacity(prominent ? 0 : 0.3), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
