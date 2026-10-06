package com.fen1x.speech.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Мягкое оформление: приглушённые цвета, скруглённые карточки, крупные кнопки.
 * Цвета не режут глаз в темноте и не спорят с изображением камеры.
 */
object Soft {
    /** Основной цвет: мягкий бирюзовый. */
    val Accent = Color(0xFF6BC7BD)
    /** «Всё хорошо»: мятный. */
    val Ok = Color(0xFF8CDBA3)
    /** «Подождите / ещё звучит»: тёплый янтарный. */
    val Warm = Color(0xFFFFCC7A)
    /** «Внимание»: персиковый вместо резкого красного. */
    val Alert = Color(0xFFFF8F80)
    /** Нейтральный: серо-сиреневый. */
    val Muted = Color(0xFF9E9EB8)
    /** Фон страниц: тёмно-синий, мягче чёрного. */
    val Background = Color(0xFF12141C)
    /** Фон карточек на страницах. */
    val Card = Color(0x0FFFFFFF)
    /** Текст на цветной заливке. */
    val OnColor = Color(0xD9000000)
}

private val Colors = darkColorScheme(
    primary = Soft.Accent,
    onPrimary = Soft.OnColor,
    secondary = Soft.Ok,
    onSecondary = Soft.OnColor,
    background = Soft.Background,
    surface = Color(0xFF1B1E27),
    onSurface = Color.White,
    surfaceVariant = Color(0xFF262A35),
    onSurfaceVariant = Color(0xFFB4B6C4),
    surfaceContainerLow = Color(0xFF1B1E27),
    surfaceContainer = Color(0xFF1E212B),
    surfaceContainerHigh = Color(0xFF22252F),
    error = Soft.Alert,
)

@Composable
fun SpeechTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Colors, content = content)
}

/** Полупрозрачная панель поверх изображения с камеры. */
val PanelColor = Color(0xD91B1E27)
val PanelShape = RoundedCornerShape(28.dp)
val Secondary = Color(0xFFB4B6C4)

/** Мягкая карточка: полупрозрачная, со скруглёнными углами и тонкой светлой кромкой. */
fun Modifier.panel(shape: Shape = PanelShape): Modifier =
    this.clip(shape).background(PanelColor).border(1.dp, Color.White.copy(alpha = 0.08f), shape)

/** Нажатая кнопка мягко уменьшается. */
@Composable
private fun pressScale(source: MutableInteractionSource, pressed: Float = 0.92f): Float {
    val isPressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (isPressed) pressed else 1f, tween(150), label = "press")
    return scale
}

/** Круглая кнопка со значком-эмодзи или своим содержимым. Не меньше 44 dp — легко попасть. */
@Composable
fun CircleButton(
    symbol: String,
    description: String,
    background: Color = PanelColor,
    size: Dp = 44.dp,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    RoundButton(size, background, description, enabled, onClick) {
        Text(symbol, fontSize = (size.value * 0.42f).sp, color = Color.White)
    }
}

@Composable
fun RoundButton(
    size: Dp,
    background: Color,
    description: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    val source = remember { MutableInteractionSource() }
    val scale = pressScale(source)
    Box(
        modifier = Modifier
            .size(size)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                alpha = if (enabled) 1f else 0.4f
            }
            .clip(CircleShape)
            .background(background)
            .border(1.dp, Color.White.copy(alpha = 0.10f), CircleShape)
            .clickable(
                interactionSource = source,
                indication = null,
                enabled = enabled,
                onClickLabel = description,
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

/**
 * Кнопка-капсула с подписью: мягко окрашенная, высотой не меньше 44 dp.
 * [prominent] — заливка цветом (главное действие), иначе лёгкий оттенок.
 */
@Composable
fun SoftPill(
    text: String,
    tint: Color = Soft.Accent,
    prominent: Boolean = false,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val source = remember { MutableInteractionSource() }
    val scale = pressScale(source, 0.95f)
    val shape = RoundedCornerShape(50)
    Row(
        modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                alpha = if (enabled) 1f else 0.4f
            }
            .heightIn(min = 44.dp)
            .clip(shape)
            .background(if (prominent) tint else tint.copy(alpha = 0.18f))
            .border(1.dp, tint.copy(alpha = if (prominent) 0f else 0.3f), shape)
            .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text,
            color = if (prominent) Soft.OnColor else tint,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

/** Капсула-подпись (состояние, подсказка). */
fun Modifier.chip(tint: Color? = null): Modifier {
    val shape = RoundedCornerShape(50)
    return this
        .clip(shape)
        .background(tint?.copy(alpha = 0.28f) ?: PanelColor)
        .border(1.dp, (tint ?: Color.White).copy(alpha = 0.25f), shape)
        .padding(horizontal = 14.dp, vertical = 9.dp)
}

fun Context.findActivity(): Activity? {
    var context: Context = this
    while (context is ContextWrapper) {
        if (context is Activity) return context
        context = context.baseContext
    }
    return null
}
