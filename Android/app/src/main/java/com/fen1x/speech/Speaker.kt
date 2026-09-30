package com.fen1x.speech

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import java.util.Locale

/** Озвучка перевода на русском языке (синтез речи телефона). */
class Speaker(context: Context) : TextToSpeech.OnInitListener {
    private val tts = TextToSpeech(context.applicationContext, this)
    private var ready = false
    private val pending = ArrayList<String>()
    private var counter = 0

    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) return
        val result = tts.setLanguage(Locale.forLanguageTag("ru-RU"))
        ready = result != TextToSpeech.LANG_MISSING_DATA && result != TextToSpeech.LANG_NOT_SUPPORTED
        if (ready) {
            pending.forEach { speak(it) }
        }
        pending.clear()
    }

    fun speak(text: String) {
        if (text.isBlank()) return
        if (!ready) {
            pending.add(text)
            return
        }
        counter += 1
        tts.speak(text, TextToSpeech.QUEUE_ADD, Bundle(), "speech-$counter")
    }

    fun stop() {
        pending.clear()
        if (ready) tts.stop()
    }

    fun shutdown() {
        tts.stop()
        tts.shutdown()
    }
}
