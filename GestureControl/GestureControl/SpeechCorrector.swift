import Foundation
import UIKit

/// Исправление распознанной речи перед показом на экране.
///
/// Распознавание Apple уже подбирает слова по смыслу фразы. Поверх него исправляется то,
/// что чаще всего мешает при дефектах речи:
/// • запинки: «п-п-привет» → «привет», «прив привет» → «привет»;
/// • повторы одного слова подряд: «я я я хочу» → «я хочу»;
/// • повторы из двух-трёх слов: «я хочу я хочу пойти» → «я хочу пойти»;
/// • растянутые звуки: «приииивет» → «привет»;
/// • звуки-паузы: «э», «ээээ», «мммм», «хмм»;
/// • слова из словаря пользователя (имена, термины, слова из словаря жестов), распознанные
///   с ошибкой в одну-две буквы: «Натаща» → «Наташа»;
/// • слова, которых нет в русском словаре iPhone: подбирается ближайшее слово с учётом
///   частых замен звуков при дефектах речи (р↔л, с↔ш, з↔ж и других).
@MainActor
struct SpeechCorrector {
    /// Слова, которые должны распознаваться точно.
    var vocabulary: [String] = [] {
        didSet { vocabularyWords = Self.words(in: vocabulary) }
    }

    private var vocabularyWords: [String] = []
    private var cache: [String: String] = [:]
    private let checker = UITextChecker()
    private let language = "ru_RU"
    private var spellCheckAvailable: Bool { UITextChecker.availableLanguages.contains(language) }

    private static let fillers: Set<String> = ["э", "ээ", "эээ", "эм", "мм", "ммм", "хм"]
    /// Короткие служебные слова: «по порядку» или «на наш» — не запинка.
    private static let shortWords: Set<String> = [
        "а", "б", "бы", "в", "во", "да", "до", "же", "за", "и", "из", "к", "ко", "ли", "мы", "на", "не", "ни",
        "но", "о", "об", "от", "по", "под", "при", "про", "с", "со", "то", "ту", "ты", "у", "я", "вы", "он",
        "она", "оно", "они", "его", "её", "ее", "их", "мой", "моя", "мне", "наш", "ваш", "там", "тут", "так",
        "как", "кто", "что", "это", "эти", "для", "над", "без", "или", "уже", "ещё", "еще", "вот", "всё", "все"
    ]
    /// Звуки, которые часто путаются при дефектах речи (такая замена «дешевле» обычной).
    private static let confusable: Set<String> = [
        "рл", "лр", "сш", "шс", "зж", "жз", "чщ", "щч", "цс", "сц", "тк", "кт", "дг", "гд",
        "бп", "пб", "вф", "фв", "гк", "кг", "дт", "тд", "зс", "сз", "жш", "шж", "чц", "цч", "еи", "ие", "ао", "оа"
    ]

    /// Исправленный текст фразы.
    mutating func correct(_ text: String) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(Token.init)

        // 1. Запинки через дефис и звуки-паузы.
        tokens = tokens.compactMap { token in
            var token = token
            if let fixed = Self.fixHyphenStutter(token.core) { token.core = fixed }
            return Self.isFiller(token.core) ? nil : token
        }

        // 2. Повторы одного слова подряд и начала слова перед самим словом.
        var result: [Token] = []
        for (i, token) in tokens.enumerated() {
            let word = Self.normalized(token.core)
            if let previous = result.last, previous.trailing.isEmpty || previous.trailing == ",",
               Self.normalized(previous.core) == word, !word.isEmpty {
                result[result.count - 1].trailing = token.trailing
                continue
            }
            if i + 1 < tokens.count, token.trailing.isEmpty, !Self.shortWords.contains(word),
               (1...4).contains(word.count) {
                let next = Self.normalized(tokens[i + 1].core)
                if next.count >= word.count + 2 && next.hasPrefix(word) { continue }
            }
            result.append(token)
        }

        // 3. Повторы из двух-трёх слов подряд.
        result = Self.removeRepeatedGroups(result)

        // 4. Слова из словаря пользователя и орфография.
        for i in result.indices {
            result[i].core = fixWord(result[i].core)
        }

        var line = result.map(\.text).joined(separator: " ")
        if let first = line.first { line.replaceSubrange(...line.startIndex, with: String(first).uppercased()) }
        return line
    }

    // MARK: Слова

    private mutating func fixWord(_ word: String) -> String {
        let original = Self.normalized(word)
        guard original.count >= 3, original.allSatisfy(\.isLetter) else { return word }
        if let cached = cache[word] { return cached }

        var lower = original
        var fixed: String?
        // Растянутый звук: «приииивет», «ооочень», «ссссобака». Оставляем одну или две
        // одинаковые буквы — какой вариант есть в словаре; если ни одного, то одну.
        if let variants = Self.collapsedVariants(original) {
            fixed = variants.first { vocabularyWords.contains($0) || (spellCheckAvailable && !isMisspelled($0)) }
            lower = variants[0]
        }
        if fixed == nil, lower.count >= 3 {
            if vocabularyWords.contains(lower) {
                fixed = lower
            } else if let known = closest(to: lower, among: vocabularyWords, maxCost: lower.count >= 7 ? 2 : 1) {
                fixed = known
            } else if lower.count >= 4, word.first?.isLowercase == true, spellCheckAvailable, isMisspelled(lower),
                      let guess = closest(to: lower, among: guesses(for: lower), maxCost: 1.5) {
                // Слова с заглавной буквы (обычно имена) по словарю iPhone не исправляем:
                // имени может не быть в словаре, и «исправление» его испортит.
                fixed = guess
            }
        }
        let chosen = fixed ?? lower
        let result = chosen == original ? word : Self.matchCase(chosen, like: word)
        if cache.count > 2000 { cache.removeAll() }
        cache[word] = result
        return result
    }

    private func isMisspelled(_ word: String) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let found = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
        return found.location != NSNotFound
    }

    private func guesses(for word: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return (checker.guesses(forWordRange: range, in: word, language: language) ?? []).map { $0.lowercased() }
    }

    /// Ближайшее слово по «стоимости» правок; первая буква должна совпадать
    /// (с учётом частых замен), иначе исправление слишком рискованное.
    private func closest(to word: String, among candidates: [String], maxCost: Double) -> String? {
        guard let first = word.first else { return nil }
        var best: (word: String, cost: Double)?
        for candidate in candidates where !candidate.contains(" ") {
            guard let c = candidate.first, c == first || Self.confusable.contains(String([first, c])) else { continue }
            guard abs(candidate.count - word.count) <= Int(maxCost) else { continue }
            let cost = Self.editCost(word, candidate)
            if cost <= maxCost, cost < (best?.cost ?? .infinity) { best = (candidate, cost) }
        }
        return best?.word
    }

    /// Расстояние Левенштейна; замена «похожих» звуков стоит 0,5.
    private static func editCost(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return Double(b.count) }
        guard !b.isEmpty else { return Double(a.count) }
        var prev = (0...b.count).map { Double($0) }
        var cur = [Double](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = Double(i)
            for j in 1...b.count {
                let substitution: Double
                if a[i - 1] == b[j - 1] {
                    substitution = 0
                } else {
                    substitution = confusable.contains(String([a[i - 1], b[j - 1]])) ? 0.5 : 1
                }
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + substitution)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Звук-пауза: «э», «ээээ», «мммм», «эмм», «хмм».
    private static func isFiller(_ word: String) -> Bool {
        let w = normalized(word)
        guard !w.isEmpty, w.count <= 8 else { return false }
        if fillers.contains(w) { return true }
        if Set(w).isSubset(of: ["э", "м"]) { return true }
        return w.count >= 2 && w.first == "х" && Set(w.dropFirst()).isSubset(of: ["м"])
    }

    /// Повтор группы из двух-трёх слов подряд (внутри одного предложения): первая копия убирается.
    private static func removeRepeatedGroups(_ input: [Token]) -> [Token] {
        var tokens = input
        for size in [3, 2] {
            var i = 0
            while i + 2 * size <= tokens.count {
                let first = tokens[i..<(i + size)]
                let second = tokens[(i + size)..<(i + 2 * size)]
                let sameWords = zip(first, second).allSatisfy { a, b in
                    !a.core.isEmpty && normalized(a.core) == normalized(b.core)
                }
                let oneSentence = first.allSatisfy { token in
                    !token.trailing.contains(where: { ".!?".contains($0) })
                }
                if sameWords && oneSentence {
                    tokens.removeSubrange(i..<(i + size))
                } else {
                    i += 1
                }
            }
        }
        return tokens
    }

    /// Варианты слова без растянутых звуков (3 и больше одинаковых букв подряд):
    /// сначала с одной буквой, потом с двумя. nil — растянутых звуков нет.
    private static func collapsedVariants(_ word: String) -> [String]? {
        var runs: [(character: Character, count: Int)] = []
        for character in word {
            if let last = runs.last, last.character == character {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((character, 1))
            }
        }
        guard runs.contains(where: { $0.count >= 3 }) else { return nil }
        let single = String(runs.flatMap { run in Array(repeating: run.character, count: run.count >= 3 ? 1 : run.count) })
        let double = String(runs.flatMap { run in Array(repeating: run.character, count: run.count >= 3 ? 2 : run.count) })
        return [single, double]
    }

    /// «п-п-привет» → «привет», «при-привет» → «привет». «кто-то», «по-моему» не трогаем:
    /// части перед дефисом должны быть началом последнего слова.
    private static func fixHyphenStutter(_ word: String) -> String? {
        let parts = word.split(separator: "-").map(String.init)
        guard parts.count >= 2, let last = parts.last, last.count >= 3 else { return nil }
        let lastLower = normalized(last)
        let fragments = parts.dropLast().map(normalized)
        guard fragments.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.count < lastLower.count && lastLower.hasPrefix($0) }) else {
            return nil
        }
        return last
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func words(in vocabulary: [String]) -> [String] {
        var result = Set<String>()
        for entry in vocabulary {
            for part in entry.split(whereSeparator: { character in !character.isLetter }) {
                let word = normalized(String(part))
                if word.count >= 3 { result.insert(word) }
            }
        }
        return Array(result)
    }

    /// Регистр как у исходного слова: «Наташа», «НАТАША», «наташа».
    private static func matchCase(_ word: String, like original: String) -> String {
        if original == original.uppercased() && original.count > 1 { return word.uppercased() }
        if let first = original.first, first.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }

    /// Слово с прилипшими знаками препинания: «(привет,» → leading «(», core «привет», trailing «,».
    private struct Token {
        var leading: String
        var core: String
        var trailing: String

        init(_ raw: Substring) {
            let chars = Array(raw)
            var start = 0
            var end = chars.count
            while start < end && !chars[start].isLetter && !chars[start].isNumber { start += 1 }
            while end > start && !chars[end - 1].isLetter && !chars[end - 1].isNumber { end -= 1 }
            leading = String(chars[0..<start])
            core = String(chars[start..<end])
            trailing = String(chars[end..<chars.count])
        }

        var text: String { leading + core + trailing }
    }
}
