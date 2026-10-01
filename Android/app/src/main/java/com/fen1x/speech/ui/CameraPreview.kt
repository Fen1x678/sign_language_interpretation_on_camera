package com.fen1x.speech.ui

import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.fen1x.speech.LiveState
import com.fen1x.speech.camera.CameraController
import com.fen1x.speech.core.Pt

/** Изображение с камеры. Камера подключается, пока экран виден, и переподключается при смене камеры. */
@Composable
fun CameraPreview(controller: CameraController, isFront: Boolean, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }
    AndroidView(factory = { previewView }, modifier = modifier)

    DisposableEffect(lifecycleOwner, isFront) {
        var active = true
        controller.setFront(isFront)
        // Камеру подключаем, когда размер изображения на экране известен: кадры для распознавания
        // обрезаются ровно по видимой области.
        fun tryBind(attempt: Int) {
            if (!active) return
            if (previewView.viewPort == null && attempt < 20) {
                previewView.postDelayed({ tryBind(attempt + 1) }, 50)
            } else {
                controller.bind(lifecycleOwner, previewView)
            }
        }
        previewView.post { tryBind(0) }
        onDispose {
            active = false
            controller.unbind()
        }
    }
}

private val BONES = listOf(
    0 to 1, 1 to 2, 2 to 3, 3 to 4,            // большой
    0 to 5, 5 to 6, 6 to 7, 7 to 8,            // указательный
    9 to 10, 10 to 11, 11 to 12,               // средний
    13 to 14, 14 to 15, 15 to 16,              // безымянный
    0 to 17, 17 to 18, 18 to 19, 19 to 20,     // мизинец
    5 to 9, 9 to 13, 13 to 17,                 // ладонь
)
private val TIPS = setOf(4, 8, 12, 16, 20)

/**
 * Скелет кистей (одной или двух) и плечи поверх изображения.
 * Читает только [LiveState], поэтому на каждом кадре перерисовывается только он.
 */
@Composable
fun HandOverlay(live: LiveState, isActive: Boolean, modifier: Modifier = Modifier) {
    val color = if (isActive) Color(0xFF34C759) else Color(0xFFFFD60A)
    val line = Color.White.copy(alpha = 0.85f)
    Canvas(modifier) {
        fun Pt.offset() = Offset(x.dp.toPx(), y.dp.toPx())
        val shoulders = live.shoulders
        // Плечи — так же, как точки рук: линия между плечами и две точки.
        if (shoulders.size == 2) {
            drawLine(line, shoulders[0].offset(), shoulders[1].offset(), strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
            for (p in shoulders) drawCircle(color, radius = 7.dp.toPx(), center = p.offset())
        }
        val resting = live.resting
        live.handPoints.forEachIndexed { h, pts ->
            if (pts.size != 21) return@forEachIndexed
            // Опущенная рука не учитывается — рисуем её серым.
            val isResting = resting.getOrElse(h) { false }
            val bones = if (isResting) Color.Gray.copy(alpha = 0.6f) else line
            val joints = if (isResting) Color.Gray else color
            for ((a, b) in BONES) {
                if (!pts[a].isValid || !pts[b].isValid) continue
                drawLine(bones, pts[a].offset(), pts[b].offset(), strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
            }
            pts.forEachIndexed { i, p ->
                if (!p.isValid) return@forEachIndexed
                val r = if (i in TIPS) 7.dp.toPx() else 5.dp.toPx()
                drawCircle(joints, radius = r, center = p.offset())
            }
        }
    }
}
