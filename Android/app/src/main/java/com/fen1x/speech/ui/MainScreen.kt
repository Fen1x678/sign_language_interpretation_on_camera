package com.fen1x.speech.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.fen1x.speech.GestureViewModel
import com.fen1x.speech.LightMode
import com.fen1x.speech.LiveState
import com.fen1x.speech.RecordingState
import com.fen1x.speech.core.AppMode
import com.fen1x.speech.core.Sign

/**
 * Интерфейс: изображение с камеры, скелет руки, распознанный жест, состояние системы,
 * перевод или демо-интерфейс управления.
 */
@Composable
fun MainScreen(vm: GestureViewModel, onOpenSpeech: () -> Unit) {
    val context = LocalContext.current
    val density = LocalDensity.current
    var hasCamera by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED,
        )
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasCamera = granted
        if (granted) vm.cameraPermissionGranted() else vm.cameraPermissionDenied()
    }
    LaunchedEffect(Unit) {
        if (!hasCamera) permission.launch(Manifest.permission.CAMERA)
    }
    var showHelp by remember { mutableStateOf(false) }
    var showLibrary by remember { mutableStateOf(false) }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onSizeChanged { size ->
                with(density) { vm.setViewSize(size.width.toDp().value, size.height.toDp().value) }
            },
    ) {
        if (hasCamera) {
            CameraPreview(vm.camera, vm.isFront, Modifier.fillMaxSize())
        }
        HandOverlay(vm.live, isActive = vm.currentSign != Sign.None, modifier = Modifier.fillMaxSize())

        // Подсветка экраном для фронтальной камеры: белая рамка на максимальной яркости.
        if (vm.isScreenLightOn) {
            Box(Modifier.fillMaxSize().border(44.dp, Color.White))
        }

        Column(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            TopBar(vm, onHelp = { showHelp = true })
            ModeBar(vm)
            AnimatedVisibility(visible = vm.notice != null) {
                Text(
                    vm.notice.orEmpty(),
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .panel(RoundedCornerShape(18.dp))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
            Spacer(Modifier.weight(1f))
            GestureBadge(vm)
            if (vm.mode == AppMode.TRANSLATE) {
                TranslationPanel(vm, onOpenSpeech = onOpenSpeech, onOpenLibrary = { showLibrary = true })
            } else {
                DemoPanel(vm)
            }
        }

        if (vm.recording != RecordingState.Idle) {
            RecordingOverlay(vm, Modifier.align(Alignment.Center))
        }

        vm.cameraError?.let { error ->
            ErrorOverlay(error, Modifier.align(Alignment.Center)) {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                context.startActivity(intent)
            }
        }
    }

    if (showHelp) HelpSheet(onDismiss = { showHelp = false })
    if (showLibrary) {
        LibrarySheet(vm, onDismiss = { showLibrary = false }) { word, dynamic, multiAngle ->
            showLibrary = false
            vm.startRecording(word, dynamic, multiAngle)
        }
    }
}

// MARK: Верхняя панель: состояние системы и кнопки

@Composable
private fun TopBar(vm: GestureViewModel, onHelp: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        val status = when {
            vm.handCount >= 2 -> "Две руки"
            vm.isHandDetected -> "Рука в кадре"
            vm.hasRestingHand -> "Руки опущены"
            else -> "Нет руки"
        }
        Row(
            Modifier
                .background(
                    if (vm.isHandDetected) Color(0xCC34C759) else Color(0xB3FF3B30),
                    RoundedCornerShape(50),
                )
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text((if (vm.isHandDetected) "✋ " else "🚫 ") + status, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            // Плечи найдены — учитывается, где руки относительно тела.
            if (vm.isBodyDetected) Text(" 🧍", fontSize = 13.sp)
        }
        Spacer(Modifier.weight(1f))
        LightButton(vm)
        CircleButton("🔄", "Сменить камеру") { vm.switchCamera() }
        CircleButton(if (vm.isRecognitionEnabled) "👁" else "🙈", "Распознавание") { vm.toggleRecognition() }
        CircleButton("?", "Справка", onClick = onHelp)
    }
}

/** Подсветка: авто / всегда / выключена. Жёлтый кружок — подсветка горит, буква A — авторежим. */
@Composable
private fun LightButton(vm: GestureViewModel) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        CircleButton("🔦", "Подсветка", background = if (vm.isLightOn) Color(0xFFFFD60A) else PanelColor) {
            expanded = true
        }
        if (vm.lightMode == LightMode.AUTO) {
            Text(
                "A",
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(15.dp)
                    .background(Color(0xFF0A84FF), CircleShape),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (mode in LightMode.entries) {
                DropdownMenuItem(
                    text = { Text((if (mode == vm.lightMode) "✓ " else "    ") + mode.title) },
                    onClick = {
                        vm.changeLightMode(mode)
                        expanded = false
                    },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModeBar(vm: GestureViewModel) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        val modes = AppMode.entries
        SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
            modes.forEachIndexed { index, mode ->
                SegmentedButton(
                    selected = vm.mode == mode,
                    onClick = { vm.changeMode(mode) },
                    shape = SegmentedButtonDefaults.itemShape(index, modes.size),
                ) {
                    Text(mode.title)
                }
            }
        }
        FpsLabel(vm.live, vm.isFront)
    }
}

/** Частота обработки кадров и текущая камера. */
@Composable
private fun FpsLabel(live: LiveState, isFront: Boolean) {
    Text(
        "${live.fps} FPS · ${if (isFront) "фронт." else "задняя"}",
        fontSize = 12.sp,
        fontFamily = FontFamily.Monospace,
        color = Color.White,
        modifier = Modifier
            .panel(RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 7.dp),
    )
}

// MARK: Распознанный жест

@Composable
private fun GestureBadge(vm: GestureViewModel) {
    Row(
        Modifier
            .fillMaxWidth()
            .panel(RoundedCornerShape(20.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        HoldRing(vm.live, vm.currentSign.emoji)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                if (vm.isRecognitionEnabled) vm.currentSign.title else "Распознавание выключено",
                fontWeight = FontWeight.SemiBold,
                fontSize = 17.sp,
            )
            Text(badgeSubtitle(vm), fontSize = 14.sp, color = Secondary)
        }
    }
}

private fun badgeSubtitle(vm: GestureViewModel): String {
    when (vm.mode) {
        AppMode.CONTROL -> {
            val command = vm.lastCommand
            if (command != null) return "Команда: ${vm.lastGesture.emoji} ${command.title}"
        }
        AppMode.TRANSLATE -> {
            vm.hint?.let { return it }
            vm.lastWord?.let { return "Последнее слово: «$it»" }
        }
    }
    return "Покажите жест в камеру"
}

/** Кольцо удержания статичного жеста. */
@Composable
private fun HoldRing(live: LiveState, emoji: String) {
    Box(Modifier.size(58.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 5.dp.toPx()
            val inset = stroke / 2
            val arcSize = Size(size.width - stroke, size.height - stroke)
            drawArc(Color.White.copy(alpha = 0.2f), 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(stroke))
            drawArc(
                Color(0xFF34C759), -90f, 360f * live.holdProgress, false, Offset(inset, inset), arcSize,
                style = Stroke(stroke, cap = StrokeCap.Round),
            )
        }
        Text(emoji, fontSize = 26.sp)
    }
}

// MARK: Режим «Перевод»

@Composable
private fun TranslationPanel(vm: GestureViewModel, onOpenSpeech: () -> Unit, onOpenLibrary: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .panel()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // Голосовой перевод: речь людей вокруг → текст на отдельной странице.
            TextButton(onClick = onOpenSpeech) { Text("🎤 Речь → текст", fontWeight = FontWeight.SemiBold) }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onOpenLibrary) { Text("➕ Словарь", fontWeight = FontWeight.SemiBold) }
            IconButton(onClick = { vm.speakPhrase() }) {
                Icon(Icons.Filled.PlayArrow, contentDescription = "Произнести фразу")
            }
            TextButton(onClick = { vm.toggleSpeech() }) { Text(if (vm.isSpeechEnabled) "🔊" else "🔇", fontSize = 18.sp) }
        }

        val empty = vm.phraseWords.isEmpty()
        Text(
            when {
                !empty -> vm.phraseText
                vm.signs.isEmpty() -> "Словарь пуст. Нажмите «Словарь» и покажите жесты, которые нужно переводить."
                else -> "Показывайте жесты — перевод появится здесь"
            },
            fontSize = if (empty) 16.sp else 32.sp,
            fontWeight = if (empty) FontWeight.Normal else FontWeight.Bold,
            color = if (empty) Secondary else Color.White,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp),
        )

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { vm.deleteLastWord() }) { Text("⌫ Стереть") }
            OutlinedButton(onClick = { vm.finishPhrase() }) { Text("↵ Фраза готова") }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { vm.clearTranslation() }) {
                Icon(Icons.Filled.Delete, contentDescription = "Очистить", tint = Color(0xFFFF6B5E))
            }
        }

        for (phrase in vm.phraseHistory) {
            Text(phrase, fontSize = 14.sp, color = Secondary)
        }

        Text("Опустите руки на 2 секунды — фраза закончится сама", fontSize = 11.sp, color = Secondary)
    }
}

// MARK: Режим «Управление» (демо-интерфейс)

@Composable
private fun DemoPanel(vm: GestureViewModel) {
    val screen = vm.screens[vm.screenIndex]
    Column(
        Modifier
            .fillMaxWidth()
            .panel()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                Modifier
                    .size(44.dp)
                    .background(Color(0x404DA3FF), RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(screen.icon, fontSize = 22.sp)
            }
            Column(Modifier.weight(1f)) {
                Text(screen.title, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("Экран ${vm.screenIndex + 1} из ${vm.screens.size}", fontSize = 12.sp, color = Secondary)
            }
            if (vm.selectedIndex == vm.screenIndex) {
                Text("✅ Выбран", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color(0xFF34C759))
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            vm.screens.indices.forEach { i ->
                Box(
                    Modifier
                        .size(width = if (i == vm.screenIndex) 18.dp else 6.dp, height = 6.dp)
                        .background(if (i == vm.screenIndex) Color.White else Color(0x66FFFFFF), RoundedCornerShape(50)),
                )
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (vm.isPlaying) "▶ Воспроизведение" else "⏸ Пауза", fontSize = 14.sp)
            Spacer(Modifier.weight(1f))
            Text("🔊 ${vm.volume}%", fontSize = 14.sp, fontFamily = FontFamily.Monospace)
        }
        LinearProgressIndicator(progress = { vm.volume / 100f }, modifier = Modifier.fillMaxWidth())

        vm.confirmation?.let { Text("✅ $it", fontSize = 14.sp, color = Color(0xFF34C759)) }

        for (line in vm.log) {
            Text(line, fontSize = 11.sp, fontFamily = FontFamily.Monospace, color = Secondary)
        }
    }
}

// MARK: Запись нового жеста

@Composable
private fun RecordingOverlay(vm: GestureViewModel, modifier: Modifier) {
    Column(
        modifier
            .widthIn(max = 300.dp)
            .panel()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        when (val state = vm.recording) {
            is RecordingState.Countdown -> {
                if (vm.recordingSteps > 1) {
                    Text("Ракурс ${vm.recordingStep} из ${vm.recordingSteps}", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Secondary)
                }
                Text(vm.recordingPrompt, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                Text("${state.n}", fontSize = 72.sp, fontWeight = FontWeight.Bold)
            }
            is RecordingState.Recording -> {
                Text(
                    if (vm.recordingDynamic) "Покажите жест целиком, с движением" else "Держите жест",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                LinearProgressIndicator(progress = { state.progress }, color = Color(0xFFFF3B30), modifier = Modifier.width(200.dp))
                Text(
                    if (vm.recordingDynamic) "Показывайте так же, как обычно, с обычной скоростью"
                    else "Слегка поворачивайте кисть — так жест будет узнаваться надёжнее",
                    fontSize = 12.sp,
                    color = Secondary,
                    textAlign = TextAlign.Center,
                )
            }
            RecordingState.Idle -> Unit
        }
        Text("«${vm.recordingWord}»", fontSize = 22.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun ErrorOverlay(message: String, modifier: Modifier, onOpenSettings: () -> Unit) {
    Column(
        modifier
            .padding(32.dp)
            .panel(RoundedCornerShape(20.dp))
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("📷", fontSize = 34.sp)
        Text(message, textAlign = TextAlign.Center)
        Button(onClick = onOpenSettings) { Text("Открыть настройки") }
    }
}
