package com.fen1x.speech.core

/** Режим работы приложения. */
enum class AppMode(val title: String) {
    TRANSLATE("Перевод"),
    CONTROL("Управление"),
}

/** Команды управления, в которые преобразуются распознанные жесты. */
enum class Command(val title: String) {
    CONFIRM("Подтверждение"),
    PAUSE("Пауза / продолжить"),
    SELECT("Выбор"),
    NEXT_SCREEN("Следующий экран"),
    PREVIOUS_SCREEN("Предыдущий экран"),
    INCREASE("Увеличение параметра"),
    DECREASE("Уменьшение параметра"),
}

/**
 * Встроенные жесты для режима «Управление» (бесконтактное управление телефоном).
 * В режиме «Перевод» используются только жесты, которым пользователь обучил приложение.
 */
enum class Gesture(
    val title: String,
    val emoji: String,
    /** Подсказка, как правильно выполнить жест. */
    val hint: String,
    /** Режим «Управление»: жест → команда. */
    val command: Command?,
    val isDynamic: Boolean,
) {
    IDLE("Жест не распознан", "❔", "", null, false),
    // Статические жесты
    THUMBS_UP("Большой палец вверх", "👍", "Кулак, большой палец направлен вверх", Command.CONFIRM, false),
    OPEN_PALM("Открытая ладонь", "✋", "Все пальцы выпрямлены, ладонь к камере", Command.PAUSE, false),
    POINTING("Указательный палец", "☝️", "Выпрямлен только указательный палец", Command.SELECT, false),
    FIST("Кулак", "✊", "Все пальцы сжаты, большой прижат", null, false),
    VICTORY("Два пальца (V)", "✌️", "Выпрямлены указательный и средний пальцы", null, false),
    OK("Жест «Окей»", "👌", "Большой и указательный — кольцо, остальные выпрямлены", null, false),
    CALL_ME("Большой палец и мизинец", "🤙", "Выпрямлены только большой палец и мизинец", null, false),
    // Динамические жесты
    SWIPE_RIGHT("Движение руки вправо", "➡️", "Быстро проведите рукой вправо", Command.NEXT_SCREEN, true),
    SWIPE_LEFT("Движение руки влево", "⬅️", "Быстро проведите рукой влево", Command.PREVIOUS_SCREEN, true),
    SWIPE_UP("Движение руки вверх", "⬆️", "Быстро поднимите руку вверх", Command.INCREASE, true),
    SWIPE_DOWN("Движение руки вниз", "⬇️", "Быстро опустите руку вниз", Command.DECREASE, true),
}

/** Результат распознавания: встроенный жест или жест, которому пользователь обучил приложение. */
sealed class Sign {
    object None : Sign()
    data class BuiltIn(val gesture: Gesture) : Sign()
    data class Custom(val id: String, override val word: String) : Sign()

    val emoji: String
        get() = when (this) {
            None -> Gesture.IDLE.emoji
            is BuiltIn -> gesture.emoji
            is Custom -> "🤟"
        }

    val title: String
        get() = when (this) {
            None -> Gesture.IDLE.title
            is BuiltIn -> gesture.title
            is Custom -> "Свой жест «$word»"
        }

    /** Слово для режима «Перевод» (встроенные жесты — только для режима «Управление»). */
    open val word: String? get() = null
}
