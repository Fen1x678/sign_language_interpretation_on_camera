package com.fen1x.speech.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fen1x.speech.GestureViewModel
import com.fen1x.speech.core.CustomSign
import kotlin.math.roundToInt

/** Словарь жестов для перевода: запись новых жестов, список слов, чувствительность, плечи. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibrarySheet(vm: GestureViewModel, onDismiss: () -> Unit, onRecord: (String, Boolean, Boolean) -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var newWord by remember { mutableStateOf("") }
    var isDynamic by remember { mutableStateOf(true) }
    var multiAngle by remember { mutableStateOf(true) }
    var toDelete by remember { mutableStateOf<CustomSign?>(null) }
    val canRecord = newWord.isNotBlank()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text("Словарь жестов", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            }

            // Научить новому жесту.
            item { SectionTitle("Научить новому жесту") }
            item {
                OutlinedTextField(
                    value = newWord,
                    onValueChange = { newWord = it },
                    label = { Text("Слово или фраза") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SegmentedButton(
                        selected = isDynamic,
                        onClick = { isDynamic = true },
                        shape = SegmentedButtonDefaults.itemShape(0, 2),
                    ) { Text("С движением") }
                    SegmentedButton(
                        selected = !isDynamic,
                        onClick = { isDynamic = false },
                        shape = SegmentedButtonDefaults.itemShape(1, 2),
                    ) { Text("Поза") }
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("С трёх ракурсов (рекомендуется)", Modifier.weight(1f))
                    Switch(checked = multiAngle, onCheckedChange = { multiAngle = it })
                }
            }
            item {
                Button(
                    onClick = {
                        val word = newWord
                        newWord = ""
                        onRecord(word, isDynamic, multiAngle)
                    },
                    enabled = canRecord,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("⏺ Записать жест") }
            }
            item {
                Footer(
                    (if (isDynamic) "После отсчёта покажите жест целиком за 2,5 секунды, как обычно при разговоре. "
                    else "После отсчёта держите позу 2 секунды. ") +
                        (if (multiAngle) "Запись пройдёт 3 раза: прямо, чуть левее и чуть правее — так жест будет узнаваться и под углом."
                        else "Можно одной или двумя руками."),
                )
            }

            // Список слов.
            item {
                HorizontalDivider()
                Spacer(Modifier.padding(4.dp))
                SectionTitle("Словарь: ${vm.signs.size}")
            }
            if (vm.signs.isEmpty()) {
                item { Text("Пока пусто. Запишите жесты, которые нужно переводить.", color = Secondary) }
            }
            items(vm.signs, key = { it.id }) { sign ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(if (sign.handCount == 2) "🙌" else "🤟", fontSize = 20.sp)
                    Column(Modifier.weight(1f)) {
                        Text(sign.word, fontSize = 17.sp)
                        Text(if (sign.isDynamic) "с движением" else "поза", fontSize = 12.sp, color = Secondary)
                    }
                    Text("записей: ${sign.recordings}", fontSize = 12.sp, color = Secondary)
                    IconButton(onClick = { toDelete = sign }) {
                        Icon(Icons.Filled.Delete, contentDescription = "Удалить «${sign.word}»", tint = Soft.Alert)
                    }
                }
            }
            item {
                Footer("Чтобы жест понимали у всех, запишите одно и то же слово у 2–3 разных людей — записи добавятся к слову.")
            }

            // Чувствительность.
            item {
                HorizontalDivider()
                Spacer(Modifier.padding(4.dp))
                SectionTitle("Чувствительность")
                Slider(
                    value = vm.sensitivity.toFloat(),
                    onValueChange = { vm.changeSensitivity((it * 10).roundToInt() / 10.0) },
                    valueRange = 0.6f..1.6f,
                    steps = 9,
                )
                Row {
                    Text("Строже", fontSize = 12.sp, color = Secondary)
                    Spacer(Modifier.weight(1f))
                    Text("${(vm.sensitivity * 100).roundToInt()} %", fontSize = 12.sp, color = Secondary)
                    Spacer(Modifier.weight(1f))
                    Text("Мягче", fontSize = 12.sp, color = Secondary)
                }
                Footer("Если жесты часто не распознаются — сдвиньте вправо. Если появляются лишние слова — влево.")
            }

            // Плечи.
            item {
                HorizontalDivider()
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                    Text("Учитывать плечи", Modifier.weight(1f), fontSize = 17.sp)
                    Switch(checked = vm.useShoulders, onCheckedChange = { vm.changeUseShoulders(it) })
                }
                Footer(
                    "Плечи находятся автоматически на каждом кадре (на экране — линия между плечами, как точки рук). " +
                        "Тогда одна и та же форма кисти у подбородка, у груди и у плеча — разные слова. " +
                        "Если плечи не видны, жест распознаётся только по кистям.",
                )
            }
        }
    }

    toDelete?.let { sign ->
        AlertDialog(
            onDismissRequest = { toDelete = null },
            title = { Text("Удалить «${sign.word}»?") },
            text = { Text("Все записи этого жеста будут удалены.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteSign(sign.id)
                    toDelete = null
                }) { Text("Удалить", color = Soft.Alert) }
            },
            dismissButton = { TextButton(onClick = { toDelete = null }) { Text("Отмена") } },
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Secondary)
}

@Composable
private fun Footer(text: String) {
    Text(text, fontSize = 12.sp, color = Secondary)
}
