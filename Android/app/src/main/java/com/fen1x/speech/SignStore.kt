package com.fen1x.speech

import android.content.Context
import android.util.Log
import com.fen1x.speech.core.SignLibrary
import java.io.File
import java.util.concurrent.Executors

/** Словарь жестов (файл) и настройки распознавания хранятся на телефоне. */
class SignStore(context: Context) {
    private val file = File(context.filesDir, "sign_dictionary_v2.json")
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val io = Executors.newSingleThreadExecutor()

    var sensitivity: Double
        get() = prefs.getFloat(KEY_SENSITIVITY, 1f).toDouble()
        set(value) = prefs.edit().putFloat(KEY_SENSITIVITY, value.toFloat()).apply()

    var useShoulders: Boolean
        get() = prefs.getBoolean(KEY_SHOULDERS, true)
        set(value) = prefs.edit().putBoolean(KEY_SHOULDERS, value).apply()

    fun load(library: SignLibrary) {
        library.sensitivity = sensitivity
        if (!file.exists()) return
        try {
            if (!library.load(file.readText())) Log.w(TAG, "Dictionary file is damaged")
        } catch (e: Exception) {
            Log.w(TAG, "Cannot read dictionary", e)
        }
    }

    /** Сохранение в фоне: сначала во временный файл, затем подмена — файл не повредится при сбое. */
    fun save(library: SignLibrary) {
        val json = library.toJson()
        io.execute {
            try {
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.writeText(json)
                if (!tmp.renameTo(file)) {
                    file.writeText(json)
                    tmp.delete()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Cannot save dictionary", e)
            }
        }
    }

    private companion object {
        const val TAG = "SignStore"
        const val KEY_SENSITIVITY = "signSensitivity"
        const val KEY_SHOULDERS = "useShoulders"
    }
}
