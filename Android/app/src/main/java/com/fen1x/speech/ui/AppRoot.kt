package com.fen1x.speech.ui

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.fen1x.speech.GestureViewModel
import com.fen1x.speech.Haptic

/** Главный экран (камера) или страница «Речь → текст». */
@Composable
fun AppRoot(vm: GestureViewModel) {
    var showSpeech by rememberSaveable { mutableStateOf(false) }

    // Приложение свёрнуто или снова открыто: подсветка выключается сразу.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> vm.onAppActive(true)
                Lifecycle.Event.ON_PAUSE -> vm.onAppActive(false)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Вибрация-отклик.
    val view = LocalView.current
    LaunchedEffect(vm) {
        vm.haptics.collect { type ->
            val constant = when (type) {
                Haptic.LIGHT -> HapticFeedbackConstants.KEYBOARD_TAP
                Haptic.MEDIUM -> HapticFeedbackConstants.VIRTUAL_KEY
                Haptic.SUCCESS ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM
                    else HapticFeedbackConstants.VIRTUAL_KEY
                Haptic.WARNING, Haptic.ERROR ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.REJECT
                    else HapticFeedbackConstants.LONG_PRESS
            }
            view.performHapticFeedback(constant)
        }
    }

    // Подсветка экраном для фронтальной камеры: яркость окна на максимум.
    // Когда приложение закрыто или свёрнуто, Android сам возвращает прежнюю яркость.
    val activity = LocalContext.current.findActivity()
    DisposableEffect(vm.isScreenLightOn, activity) {
        val window = activity?.window
        if (window != null) {
            val params = window.attributes
            params.screenBrightness = if (vm.isScreenLightOn) {
                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
            } else {
                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            }
            window.attributes = params
        }
        onDispose { }
    }

    LaunchedEffect(showSpeech) { vm.setCameraPaused(showSpeech) }

    if (showSpeech) {
        SpeechScreen(dictionaryWords = vm.signs.map { it.word }, onClose = { showSpeech = false })
    } else {
        MainScreen(vm, onOpenSpeech = { showSpeech = true })
    }
}
