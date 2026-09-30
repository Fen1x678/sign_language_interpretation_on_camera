package com.fen1x.speech.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.fen1x.speech.speech.SpokenPhrase
import com.fen1x.speech.speech.VoiceTranslator
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Страница «Речь → текст»: живая расшифровка того, что говорят вокруг, крупным текстом.
 * Каждая реплика (после паузы) — отдельная строка, поэтому речь нескольких людей не сливается.
 */
@Composable
fun SpeechScreen(dictionaryWords: List<String>, onClose: () -> Unit) {
    val context = LocalContext.current
    val translator = remember { VoiceTranslator(context.applicationContext) }
    var showWords by remember { mutableStateOf(false) }

    LaunchedEffect(dictionaryWords) { translator.setDictionaryWords(dictionaryWords) }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) translator.start() else translator.permissionDenied()
    }
    fun startListening() {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) translator.start() else permission.launch(Manifest.permission.RECORD_AUDIO)
    }
    LaunchedEffect(Unit) { startListening() }

    // Приложение свернули — пауза; вернулись — прослушивание продолжается само.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> translator.onBackground()
                Lifecycle.Event.ON_START -> translator.onForeground()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            translator.stop()
        }
    }

    val close = {
        translator.stop()
        onClose()
    }
    BackHandler(onBack = close)

    Column(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .safeDrawingPadding(),
    ) {
        Header(translator, onClose = close, onWords = { showWords = true })
        Transcript(translator, Modifier.weight(1f))
        Controls(translator, onToggle = {
            if (translator.isListening) translator.stop() else startListening()
        })
    }

    if (showWords) WordsDialog(translator, onDismiss = { showWords = false })
}

@Composable
private fun Header(translator: VoiceTranslator, onClose: () -> Unit, onWords: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = onClose) { Text("Готово", fontSize = 17.sp) }
        Text("Речь → текст", Modifier.weight(1f), textAlign = TextAlign.Center, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Box {
            TextButton(onClick = { menu = true }) { Text("⋯", fontSize = 22.sp) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("📖 Мои слова") }, onClick = {
                    menu = false
                    onWords()
                })
                HorizontalDivider()
                Text(
                    "Новая строка после паузы",
                    fontSize = 12.sp,
                    color = Secondary,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                )
                for ((seconds, title) in listOf(0.8f to "Быстрый разговор — 0,8 с", 1.2f to "Обычно — 1,2 с", 2.0f to "Медленная речь — 2 с")) {
                    DropdownMenuItem(
                        text = { Text((if (translator.splitPause == seconds) "✓ " else "    ") + title) },
                        onClick = { translator.changeSplitPause(seconds) },
                    )
                }
                HorizontalDivider()
                if (translator.supportsOnDevice) {
                    DropdownMenuItem(
                        text = { Text((if (translator.onDeviceOnly) "✓ " else "    ") + "Только на телефоне (без интернета)") },
                        onClick = { translator.changeOnDeviceOnly(!translator.onDeviceOnly) },
                    )
                }
                DropdownMenuItem(
                    text = { Text((if (translator.muteBeep) "✓ " else "    ") + "Без звукового сигнала") },
                    onClick = { translator.changeMuteBeep(!translator.muteBeep) },
                )
            }
        }
    }
}

@Composable
private fun Transcript(translator: VoiceTranslator, modifier: Modifier) {
    val listState = rememberLazyListState()
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    // Прокручивать к новым фразам. Выключается, когда человек листает вверх, чтобы перечитать,
    // и включается снова, когда он долистал до конца.
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling) follow = !listState.canScrollForward
        }
    }
    val phrases = translator.phrases
    val lastText = phrases.lastOrNull()?.text
    LaunchedEffect(phrases.size, lastText) {
        if (follow && phrases.isNotEmpty()) listState.scrollToItem(phrases.size)
    }

    Box(modifier.fillMaxWidth()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (phrases.isEmpty()) {
                item {
                    Text(
                        if (translator.isListening) "Говорите — текст появится здесь" else "Нажмите на микрофон, чтобы начать",
                        fontSize = 20.sp,
                        color = Secondary,
                        modifier = Modifier.padding(top = 40.dp),
                    )
                }
            }
            items(phrases, key = { it.id }) { phrase ->
                PhraseRow(phrase, translator.fontSize, highlighted = !phrase.isFinal && translator.isListening)
            }
            item(key = "bottom") { Spacer(Modifier.heightIn(min = 1.dp)) }
        }
        if (!follow && phrases.isNotEmpty()) {
            Text(
                "↓ К новым",
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 12.dp)
                    .background(PanelColor, RoundedCornerShape(50))
                    .clickable {
                        follow = true
                        scope.launch { listState.animateScrollToItem(phrases.size) }
                    }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }
}

private val TIME_FORMAT = SimpleDateFormat("HH:mm", Locale.getDefault())

/** Одна фраза: время и текст. Жёлтая — фраза ещё звучит и может измениться. */
@Composable
private fun PhraseRow(phrase: SpokenPhrase, fontSize: Float, highlighted: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(TIME_FORMAT.format(Date(phrase.time)), fontSize = 11.sp, color = Secondary, fontFamily = FontFamily.Monospace)
        Text(
            phrase.text,
            fontSize = fontSize.sp,
            lineHeight = (fontSize * 1.2f).sp,
            fontWeight = FontWeight.SemiBold,
            color = if (highlighted) Color(0xFFFFD60A) else Color.White,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun Controls(translator: VoiceTranslator, onToggle: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Color(0xFF1C1C1E))
            .padding(top = 10.dp, bottom = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        translator.error?.let {
            Text(it, fontSize = 13.sp, color = Color(0xFFFF9F0A), textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 16.dp))
        }
        ListeningStatus(translator)
        Row(horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.CenterVertically) {
            RoundButton(52, PanelColor, "Очистить", enabled = translator.phrases.isNotEmpty(), onClick = { translator.clear() }) {
                Icon(Icons.Filled.Delete, contentDescription = null, tint = Color.White)
            }
            RoundButton(
                78,
                if (translator.isListening) Color(0xFFFF3B30) else Color(0xFF0A84FF),
                if (translator.isListening) "Остановить" else "Слушать",
                onClick = onToggle,
            ) {
                Text(if (translator.isListening) "■" else "🎤", fontSize = 30.sp, color = Color.White)
            }
            RoundButton(52, PanelColor, "Размер текста", onClick = { translator.changeFontSize() }) {
                Text("Aa", fontSize = 18.sp, color = Color(0xFF4DA3FF), fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun RoundButton(
    size: Int,
    color: Color,
    description: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    Box(
        Modifier
            .size(size.dp)
            .background(if (enabled) color else color.copy(alpha = 0.4f), CircleShape)
            .clickable(enabled = enabled, onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

/** Индикатор громкости и что сейчас происходит. */
@Composable
private fun ListeningStatus(translator: VoiceTranslator) {
    val level by animateFloatAsState(translator.level, label = "level")
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (translator.isListening) {
            Box(
                Modifier
                    .width(160.dp)
                    .heightIn(min = 6.dp, max = 6.dp)
                    .background(Color(0x26FFFFFF), RoundedCornerShape(50)),
            ) {
                Box(
                    Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(level.coerceIn(0.04f, 1f))
                        .background(if (level > 0.35f) Color(0xFF34C759) else Color.Gray, RoundedCornerShape(50)),
                )
            }
        }
        val notice = translator.notice
        val status = when {
            !translator.isListening -> "Пауза — нажмите на микрофон"
            notice != null -> notice
            else -> "Слушаю. Новая строка — после паузы в разговоре"
        }
        Text(
            status,
            fontSize = 12.sp,
            color = if (notice != null && translator.isListening) Color(0xFFFF9F0A) else Secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
}

/**
 * Слова, которые должны распознаваться точно: имена, названия, термины.
 * Если слово распознано с ошибкой в одну-две буквы, оно исправляется на слово из этого списка.
 */
@Composable
private fun WordsDialog(translator: VoiceTranslator, onDismiss: () -> Unit) {
    var newWord by remember { mutableStateOf("") }
    fun add() {
        translator.addWord(newWord)
        newWord = ""
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Готово") } },
        title = { Text("Мои слова") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = newWord,
                        onValueChange = { newWord = it },
                        label = { Text("Имя, название, термин") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { add() }),
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = { add() }, enabled = newWord.isNotBlank()) { Text("Добавить") }
                }
                Text(
                    "Эти слова распознаются точнее. Если слово распознано с ошибкой в одну-две буквы (например, из-за особенностей произношения), оно исправится на слово из списка. Слова из словаря жестов учитываются автоматически.",
                    fontSize = 12.sp,
                    color = Secondary,
                )
                Text("Мои слова: ${translator.customWords.size}", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                LazyColumn(Modifier.heightIn(max = 240.dp)) {
                    items(translator.customWords) { word ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(word, Modifier.weight(1f))
                            IconButton(onClick = { translator.removeWord(word) }) {
                                Icon(Icons.Filled.Delete, contentDescription = "Удалить «$word»", tint = Color(0xFFFF6B5E))
                            }
                        }
                    }
                }
            }
        },
    )
}
