package com.fen1x.speech.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fen1x.speech.core.Gesture

private val TRANSLATE_HELP = listOf(
    "Приложение переводит жесты, которым его научили: «Перевод» → «Словарь» → слово → «Записать жест».",
    "«Поза» — жест без движения, его нужно задержать на долю секунды. «С движением» — жест распознаётся целиком, как только закончен, можно показывать быстро.",
    "Каждое слово лучше записать 2–3 раза: с разных камер, при разном свете. Чем больше примеров, тем точнее перевод.",
    "Задняя камера: наведите телефон на собеседника — перевод на экране и голосом. Фронтальная: жестикулирующий сам видит, правильно ли переведено.",
    "Опустите руки на 2 секунды — фраза закончится и уйдёт в историю.",
    "Разные люди: приложение сравнивает углы сгиба пальцев, а не их длину, и понимает левую руку как зеркало правой. Для лучшей точности запишите одно слово у 2–3 разных людей.",
    "Разные ракурсы: записывайте жесты «С трёх ракурсов».",
    "Жест одной рукой: вторую руку можно держать опущенной — на столе или на коленях. Неподвижная опущенная рука не учитывается (на экране она серая). Как только она поднимается или двигается, жест считается жестом двумя руками.",
    "Если новый жест похож на уже записанное слово, приложение предупредит об этом после записи.",
    "Подсказка «Похоже на «слово» — N%»: 100% — жест достаточно похож, чтобы засчитаться. Если процент держится ниже, сдвиньте «Чувствительность» вправо или запишите слово ещё раз. Для жестов с движением в скобках бывает причина отказа: «мало движения» — покажите с тем же размахом, что при записи; «слишком быстро» — медленнее.",
    "Плечи: приложение само находит плечи на каждом кадре (линия между плечами) и учитывает, где руки относительно тела. Чтобы это работало, в кадре должны быть видны плечи. Отключить — «Словарь» → «Учитывать плечи».",
)

private val SPEECH_HELP = listOf(
    "Кнопка «Речь → текст» в панели перевода открывает голосовой перевод: всё, что говорят вокруг, сразу появляется на экране крупным текстом. Когда говорят несколько человек, каждая реплика после паузы — с новой строки.",
    "Запинки, повторы и звуки-паузы («э-э») убираются. Имена и редкие слова добавьте в «Мои слова» (кнопка «⋯») — тогда они распознаются точнее и исправляются, если распознаны с ошибкой.",
    "Телефонные звонки перевести нельзя: Android не даёт приложениям звук звонка.",
)

private val LIGHT_HELP = listOf(
    "Кнопка 🔦 вверху: «Авто» — включается сама, когда темно, и выключается, когда стало светло; «Всегда вкл.» или «Выключена».",
    "У задней камеры светит фонарик. У фронтальной фонарика нет — светит экран: яркость на максимум и белая рамка вокруг изображения.",
)

/** Справка по жестам и режимам. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HelpSheet(onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item { Text("Справка", fontSize = 22.sp, fontWeight = FontWeight.Bold) }
            item { Title("Перевод (сурдоперевод)") }
            items(TRANSLATE_HELP) { Body(it) }
            item { Title("Речь → текст") }
            items(SPEECH_HELP) { Body(it) }
            item { Title("Подсветка") }
            items(LIGHT_HELP) { Body(it) }
            item { Title("Управление — статичные жесты (удерживать 0,4 с)") }
            items(Gesture.entries.filter { it != Gesture.IDLE && !it.isDynamic && it.command != null }) { GestureRow(it) }
            item { Title("Управление — движения руки") }
            items(Gesture.entries.filter { it.isDynamic }) { GestureRow(it) }
        }
    }
}

@Composable
private fun Title(text: String) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Secondary, modifier = Modifier.padding(top = 10.dp))
}

@Composable
private fun Body(text: String) {
    Text(text, fontSize = 14.sp)
}

@Composable
private fun GestureRow(gesture: Gesture) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(gesture.emoji, fontSize = 28.sp)
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(gesture.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(gesture.hint, fontSize = 12.sp, color = Secondary)
            Text("Команда: ${gesture.command?.title ?: "—"}", fontSize = 12.sp)
        }
    }
}
