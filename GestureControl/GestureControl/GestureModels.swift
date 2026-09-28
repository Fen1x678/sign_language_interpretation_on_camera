import Foundation

/// Режим работы приложения.
enum AppMode: String, CaseIterable, Identifiable {
    case control = "Управление"
    case translate = "Перевод"

    var id: String { rawValue }
}

/// Команды управления, в которые преобразуются распознанные жесты.
enum Command: Equatable {
    case confirm
    case pause
    case select
    case nextScreen
    case previousScreen
    case increase
    case decrease

    var title: String {
        switch self {
        case .confirm:        return "Подтверждение"
        case .pause:          return "Пауза / продолжить"
        case .select:         return "Выбор"
        case .nextScreen:     return "Следующий экран"
        case .previousScreen: return "Предыдущий экран"
        case .increase:       return "Увеличение параметра"
        case .decrease:       return "Уменьшение параметра"
        }
    }
}

/// Встроенные жесты для режима «Управление» (бесконтактное управление телефоном).
/// В режиме «Перевод» используются только жесты, которым пользователь обучил приложение.
enum Gesture: String, CaseIterable, Identifiable {
    case idle
    // Статические жесты
    case thumbsUp
    case openPalm
    case pointing
    case fist
    case victory
    case ok
    case callMe
    // Динамические жесты
    case swipeRight
    case swipeLeft
    case swipeUp
    case swipeDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle:       return "Жест не распознан"
        case .thumbsUp:   return "Большой палец вверх"
        case .openPalm:   return "Открытая ладонь"
        case .pointing:   return "Указательный палец"
        case .fist:       return "Кулак"
        case .victory:    return "Два пальца (V)"
        case .ok:         return "Жест «Окей»"
        case .callMe:     return "Большой палец и мизинец"
        case .swipeRight: return "Движение руки вправо"
        case .swipeLeft:  return "Движение руки влево"
        case .swipeUp:    return "Движение руки вверх"
        case .swipeDown:  return "Движение руки вниз"
        }
    }

    var emoji: String {
        switch self {
        case .idle:       return "❔"
        case .thumbsUp:   return "👍"
        case .openPalm:   return "✋"
        case .pointing:   return "☝️"
        case .fist:       return "✊"
        case .victory:    return "✌️"
        case .ok:         return "👌"
        case .callMe:     return "🤙"
        case .swipeRight: return "➡️"
        case .swipeLeft:  return "⬅️"
        case .swipeUp:    return "⬆️"
        case .swipeDown:  return "⬇️"
        }
    }

    /// Подсказка, как правильно выполнить жест.
    var hint: String {
        switch self {
        case .idle:       return ""
        case .thumbsUp:   return "Кулак, большой палец направлен вверх"
        case .openPalm:   return "Все пальцы выпрямлены, ладонь к камере"
        case .pointing:   return "Выпрямлен только указательный палец"
        case .fist:       return "Все пальцы сжаты, большой прижат"
        case .victory:    return "Выпрямлены указательный и средний пальцы"
        case .ok:         return "Большой и указательный — кольцо, остальные выпрямлены"
        case .callMe:     return "Выпрямлены только большой палец и мизинец"
        case .swipeRight: return "Быстро проведите рукой вправо"
        case .swipeLeft:  return "Быстро проведите рукой влево"
        case .swipeUp:    return "Быстро поднимите руку вверх"
        case .swipeDown:  return "Быстро опустите руку вниз"
        }
    }

    /// Режим «Управление»: жест → команда.
    var command: Command? {
        switch self {
        case .thumbsUp:   return .confirm
        case .openPalm:   return .pause
        case .pointing:   return .select
        case .swipeRight: return .nextScreen
        case .swipeLeft:  return .previousScreen
        case .swipeUp:    return .increase
        case .swipeDown:  return .decrease
        default:          return nil
        }
    }

    var isDynamic: Bool {
        switch self {
        case .swipeRight, .swipeLeft, .swipeUp, .swipeDown: return true
        default: return false
        }
    }
}

/// Результат распознавания: встроенный жест или жест, которому пользователь обучил приложение.
enum Sign: Equatable {
    case none
    case builtIn(Gesture)
    case custom(id: UUID, word: String)

    var emoji: String {
        switch self {
        case .none:                return Gesture.idle.emoji
        case .builtIn(let gesture): return gesture.emoji
        case .custom:              return "🤟"
        }
    }

    var title: String {
        switch self {
        case .none:                return Gesture.idle.title
        case .builtIn(let gesture): return gesture.title
        case .custom(_, let word): return "Свой жест «\(word)»"
        }
    }

    /// Слово для режима «Перевод».
    var word: String? {
        switch self {
        case .none:                return nil
        case .builtIn:             return nil   // встроенные жесты — только для режима «Управление»
        case .custom(_, let word): return word
        }
    }
}
