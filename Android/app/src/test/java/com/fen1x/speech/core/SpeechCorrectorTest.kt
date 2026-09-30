package com.fen1x.speech.core

import org.junit.Assert.assertEquals
import org.junit.Test

class SpeechCorrectorTest {
    private val corrector = SpeechCorrector().apply {
        vocabulary = listOf("Наташа", "Тимофей", "спасибо", "два")
    }

    private fun check(input: String, expected: String) = assertEquals(expected, corrector.correct(input))

    @Test fun repeatedWords() = check("я я я хочу пить", "Я хочу пить")
    @Test fun hyphenStutter() = check("п-п-привет Натаща", "Привет Наташа")
    @Test fun partialWord() = check("прив привет, как дела", "Привет, как дела")
    @Test fun shortWordsAreKept() = check("по порядку идём", "По порядку идём")
    @Test fun fillers() = check("Эээ, ммм, я хочу пить", "Я хочу пить")
    @Test fun hmm() = check("Хмм как дела", "Как дела")
    @Test fun sentencesAreKept() = check("Да. Да. Конечно", "Да. Да. Конечно")
    @Test fun hyphenWordsAreKept() = check("кто-то пришёл по-моему", "Кто-то пришёл по-моему")
    @Test fun repeatedGroup() = check("я хочу я хочу пойти домой", "Я хочу пойти домой")
    @Test fun repeatedGroupAcrossSentencesIsKept() = check("я пойду. Я пойду завтра", "Я пойду. Я пойду завтра")
    @Test fun elongatedSound() = check("ооочень хорошо", "Очень хорошо")
    @Test fun elongatedConsonant() = check("ссссобака лает", "Собака лает")
    @Test fun vocabularyWithConfusableSounds() = check("Эмм, Тимофеей сказал спосибо", "Тимофей сказал спасибо")
    @Test fun elongatedShortWordIsNotReplacedByVocabulary() = check("дааа конечно", "Да конечно")
    @Test fun numbers() = check("1000 1000 рублей", "1000 рублей")

    @Test
    fun spellCheckerIsUsed() {
        val withChecker = SpeechCorrector(object : SpellChecker {
            override fun isMisspelled(word: String) = word == "малако"
            override fun guesses(word: String) = listOf("молоко", "мало")
        })
        assertEquals("Купи молоко", withChecker.correct("купи малако"))
    }

    @Test
    fun editCostTreatsConfusableSoundsAsCheaper() {
        assertEquals(0.5, SpeechCorrector.editCost("рыба", "лыба"), 1e-9)
        assertEquals(1.0, SpeechCorrector.editCost("рыба", "мыба"), 1e-9)
    }
}
