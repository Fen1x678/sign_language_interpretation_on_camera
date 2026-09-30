package com.fen1x.speech.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable

private val Colors = darkColorScheme(
    primary = Color(0xFF4DA3FF),
    onPrimary = Color.White,
    secondary = Color(0xFF8EC5FF),
    background = Color.Black,
    surface = Color(0xFF1C1C1E),
    onSurface = Color.White,
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFFB0B0B5),
    error = Color(0xFFFF6B5E),
)

@Composable
fun SpeechTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Colors, content = content)
}

/** Полупрозрачная панель поверх изображения с камеры. */
val PanelColor = Color(0xCC1C1C1E)
val PanelShape = RoundedCornerShape(24.dp)
val Secondary = Color(0xFFB0B0B5)

fun Modifier.panel(shape: androidx.compose.ui.graphics.Shape = PanelShape): Modifier =
    this.clip(shape).background(PanelColor)

/** Круглая кнопка со значком-эмодзи. */
@Composable
fun CircleButton(
    symbol: String,
    description: String,
    background: Color = PanelColor,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(background)
            .clickable(onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, fontSize = 18.sp, color = Color.White)
    }
}

fun Context.findActivity(): Activity? {
    var context: Context = this
    while (context is ContextWrapper) {
        if (context is Activity) return context
        context = context.baseContext
    }
    return null
}
