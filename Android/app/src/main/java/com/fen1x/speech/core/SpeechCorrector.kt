package com.fen1x.speech.core

import kotlin.math.abs

/**
 * Проверка орфографии (на Android — словарь телефона). Необязательна: без неё исправляются
 * запинки, повторы, звуки-паузы и слова из «Моих слов».
 */
interface SpellChecker {
    fun isMisspelled(word: String): Boolean
    fun guesses(word: String): List<String>
}

/**
 * Исправление распознанной речи перед показом на экране.
 *
 * Распознавание речи уже подбирает слова по смыслу фразы. Поверх него исправляется то,
 * что чаще всего мешает при дефектах речи:
 * • запинки: «п-п-привет» → «привет», «прив привет» → «привет»;
 * • повторы одного слова подряд: «я я я хочу» → «я хочу»;
 * • повторы из двух-трёх слов: «я хочу я хочу пойти» → «я хочу пойти»;
 * • растянутые звуки: «приииивет» → «привет»;
 * • звуки-паузы: «э», «ээээ», «мммм», «хмм»;
 * • слова из словаря пользователя (имена, термины, слова из словаря жестов), распознанные
 *   с ошибкой в одну-две буквы: «Натаща» → «Наташа»;
 * • если есть проверка орфографии — слова, которых нет в словаре: подбирается ближайшее слово
 *   с учётом частых замен звуков при дефектах речи (р↔л, с↔ш, з↔ж и других).
 */
class SpeechCorrector(var spellChecker: SpellChecker? = null) {
    /** Слова, которые должны распознаваться точно. */
    var vocabulary: List<String> = emptyList()
        set(value) {
            field = value
            vocabularyWords = words(value)
            cache.clear()
        }

    private var vocabularyWords: List<String> = emptyList()
    private val cache = HashMap<String, String>()

    /** Исправленный текст фразы. */
    fun correct(text: String): String {
        var tokens = text.split(Regex("\\s+")).filter { it.isNotEmpty() }.map { Token.parse(it) }

        // 1. Запинки через дефис и звуки-паузы.
        tokens = tokens.mapNotNull { token ->
            val fixed = fixHyphenStutter(token.core)
            val t = if (fixed != null) token.copy(core = fixed) else token
            if (isFiller(t.core)) null else t
        }

        // 2. Повторы одного слова подряд и начала слова перед самим словом.
        var result = ArrayList<Token>()
        for ((i, token) in tokens.withIndex()) {
            val word = normalized(token.core)
            val previous = result.lastOrNull()
            if (previous != null && (previous.trailing.isEmpty() || previous.trailing == ",") &&
                normalized(previous.core) == word && word.isNotEmpty()
            ) {
                result[result.size - 1] = previous.copy(trailing = token.trailing)
                continue
            }
            if (i + 1 < tokens.size && token.trailing.isEmpty() && word !in SHORT_WORDS && word.length in 1..4) {
                val next = normalized(tokens[i + 1].core)
                if (next.length >= word.length + 2 && next.startsWith(word)) continue
            }
            result.add(token)
        }

        // 3. Повторы из двух-трёх слов подряд.
        result = removeRepeatedGroups(result)

        // 4. Слова из словаря пользователя и орфография.
        for (i in result.indices) {
            result[i] = result[i].copy(core = fixWord(result[i].core))
        }

        val line = result.joinToString(" ") { it.text }
        return line.replaceFirstChar { it.uppercase() }
    }

    // MARK: Слова

    private fun fixWord(word: String): String {
        val original = normalized(word)
        if (original.length < 3 || !original.all { it.isLetter() }) return word
        cache[word]?.let { return it }
        val checker = spellChecker

        var lower = original
        var fixed: String? = null
        // Растянутый звук: «приииивет», «ооочень», «ссссобака». Оставляем одну или две
        // одинаковые буквы — какой вариант есть в словаре; если ни одного, то одну.
        val variants = collapsedVariants(original)
        if (variants != null) {
            fixed = variants.firstOrNull { it in vocabularyWords || (checker != null && !checker.isMisspelled(it)) }
            lower = variants[0]
        }
        if (fixed == null && lower.length >= 3) {
            if (lower in vocabularyWords) {
                fixed = lower
            } else {
                val known = closest(lower, vocabularyWords, if (lower.length >= 7) 2.0 else 1.0)
                if (known != null) {
                    fixed = known
                } else if (checker != null && lower.length >= 4 && word.first().isLowerCase() && checker.isMisspelled(lower)) {
                    // Слова с заглавной буквы (обычно имена) по словарю телефона не исправляем:
                    // имени может не быть в словаре, и «исправление» его испортит.
                    fixed = closest(lower, checker.guesses(lower).map { it.lowercase() }, 1.5)
                }
            }
        }
        val chosen = fixed ?: lower
        val result = if (chosen == original) word else matchCase(chosen, word)
        if (cache.size > 2000) cache.clear()
        cache[word] = result
        return result
    }

    /**
     * Ближайшее слово по «стоимости» правок; первая буква должна совпадать
     * (с учётом частых замен), иначе исправление слишком рискованное.
     */
    private fun closest(word: String, candidates: List<String>, maxCost: Double): String? {
        val first = word.firstOrNull() ?: return null
        var best: String? = null
        var bestCost = Double.POSITIVE_INFINITY
        for (candidate in candidates) {
            if (candidate.contains(' ')) continue
            val c = candidate.firstOrNull() ?: continue
            if (c != first && "$first$c" !in CONFUSABLE) continue
            if (abs(candidate.length - word.length) > maxCost.toInt()) continue
            val cost = editCost(word, candidate)
            if (cost <= maxCost && cost < bestCost) {
                best = candidate
                bestCost = cost
            }
        }
        return best
    }

    /** Слово с прилипшими знаками препинания: «(привет,» → leading «(», core «привет», trailing «,». */
    private data class Token(val leading: String, val core: String, val trailing: String) {
        val text: String get() = leading + core + trailing

        companion object {
            fun parse(raw: String): Token {
                var start = 0
                var end = raw.length
                while (start < end && !raw[start].isLetterOrDigit()) start++
                while (end > start && !raw[end - 1].isLetterOrDigit()) end--
                return Token(raw.substring(0, start), raw.substring(start, end), raw.substring(end))
            }
        }
    }

    companion object {
        private val FILLERS = setOf("э", "ээ", "эээ", "эм", "мм", "ммм", "хм")

        /** Короткие служебные слова: «по порядку» или «на наш» — не запинка. */
        private val SHORT_WORDS = setOf(
            "а", "б", "бы", "в", "во", "да", "до", "же", "за", "и", "из", "к", "ко", "ли", "мы", "на", "не", "ни",
            "но", "о", "об", "от", "по", "под", "при", "про", "с", "со", "то", "ту", "ты", "у", "я", "вы", "он",
            "она", "оно", "они", "его", "её", "ее", "их", "мой", "моя", "мне", "наш", "ваш", "там", "тут", "так",
            "как", "кто", "что", "это", "эти", "для", "над", "без", "или", "уже", "ещё", "еще", "вот", "всё", "все",
        )

        /** Звуки, которые часто путаются при дефектах речи (такая замена «дешевле» обычной). */
        private val CONFUSABLE = setOf(
            "рл", "лр", "сш", "шс", "зж", "жз", "чщ", "щч", "цс", "сц", "тк", "кт", "дг", "гд",
            "бп", "пб", "вф", "фв", "гк", "кг", "дт", "тд", "зс", "сз", "жш", "шж", "чц", "цч", "еи", "ие", "ао", "оа",
        )

        /** Расстояние Левенштейна; замена «похожих» звуков стоит 0,5. */
        fun editCost(a: String, b: String): Double {
            if (a.isEmpty()) return b.length.toDouble()
            if (b.isEmpty()) return a.length.toDouble()
            var prev = DoubleArray(b.length + 1) { it.toDouble() }
            var cur = DoubleArray(b.length + 1)
            for (i in 1..a.length) {
                cur[0] = i.toDouble()
                for (j in 1..b.length) {
                    val substitution = when {
                        a[i - 1] == b[j - 1] -> 0.0
                        "${a[i - 1]}${b[j - 1]}" in CONFUSABLE -> 0.5
                        else -> 1.0
                    }
                    cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + substitution)
                }
                val tmp = prev
                prev = cur
                cur = tmp
            }
            return prev[b.length]
        }

        /** Звук-пауза: «э», «ээээ», «мммм», «эмм», «хмм». */
        private fun isFiller(word: String): Boolean {
            val w = normalized(word)
            if (w.isEmpty() || w.length > 8) return false
            if (w in FILLERS) return true
            if (w.all { it == 'э' || it == 'м' }) return true
            return w.length >= 2 && w[0] == 'х' && w.drop(1).all { it == 'м' }
        }

        /** Повтор группы из двух-трёх слов подряд (внутри одного предложения): первая копия убирается. */
        private fun removeRepeatedGroups(input: List<Token>): ArrayList<Token> {
            val tokens = ArrayList(input)
            for (size in intArrayOf(3, 2)) {
                var i = 0
                while (i + 2 * size <= tokens.size) {
                    var sameWords = true
                    var oneSentence = true
                    for (k in 0 until size) {
                        val a = tokens[i + k]
                        val b = tokens[i + size + k]
                        if (a.core.isEmpty() || normalized(a.core) != normalized(b.core)) sameWords = false
                        if (a.trailing.any { it == '.' || it == '!' || it == '?' }) oneSentence = false
                    }
                    if (sameWords && oneSentence) {
                        repeat(size) { tokens.removeAt(i) }
                    } else {
                        i += 1
                    }
                }
            }
            return tokens
        }

        /**
         * Варианты слова без растянутых звуков (3 и больше одинаковых букв подряд):
         * сначала с одной буквой, потом с двумя. null — растянутых звуков нет.
         */
        private fun collapsedVariants(word: String): List<String>? {
            val runs = ArrayList<Pair<Char, Int>>()
            for (c in word) {
                val last = runs.lastOrNull()
                if (last != null && last.first == c) {
                    runs[runs.size - 1] = c to last.second + 1
                } else {
                    runs.add(c to 1)
                }
            }
            if (runs.none { it.second >= 3 }) return null
            val single = runs.joinToString("") { (c, n) -> c.toString().repeat(if (n >= 3) 1 else n) }
            val double = runs.joinToString("") { (c, n) -> c.toString().repeat(if (n >= 3) 2 else n) }
            return listOf(single, double)
        }

        /** «п-п-привет» → «привет», «при-привет» → «привет». «кто-то», «по-моему» не трогаем. */
        private fun fixHyphenStutter(word: String): String? {
            val parts = word.split("-")
            if (parts.size < 2) return null
            val last = parts.last()
            if (last.length < 3) return null
            val lastLower = normalized(last)
            val fragments = parts.dropLast(1).map { normalized(it) }
            val ok = fragments.all { it.isNotEmpty() && it.length <= 3 && it.length < lastLower.length && lastLower.startsWith(it) }
            return if (ok) last else null
        }

        private fun normalized(word: String): String = word.lowercase().replace('ё', 'е')

        private fun words(vocabulary: List<String>): List<String> {
            val result = LinkedHashSet<String>()
            for (entry in vocabulary) {
                for (part in entry.split(Regex("[^\\p{L}]+"))) {
                    val word = normalized(part)
                    if (word.length >= 3) result.add(word)
                }
            }
            return result.toList()
        }

        /** Регистр как у исходного слова: «Наташа», «НАТАША», «наташа». */
        private fun matchCase(word: String, original: String): String {
            if (original == original.uppercase() && original.length > 1) return word.uppercase()
            if (original.firstOrNull()?.isUpperCase() == true) return word.replaceFirstChar { it.uppercase() }
            return word
        }
    }
}
