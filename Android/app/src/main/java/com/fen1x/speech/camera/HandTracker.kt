package com.fen1x.speech.camera

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import com.fen1x.speech.core.Pt
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import java.io.Closeable
import kotlin.math.hypot

/**
 * Рука, найденная на кадре: 21 точка в координатах кадра (0…1, начало — левый верхний угол,
 * кадр в том виде, в каком он показан на экране) и уверенность в каждой точке (0…1).
 * chirality — какая это рука: +1 правая, −1 левая, 0 — неизвестно.
 */
class CameraHand(val points: List<Pt>, val confidence: List<Float>, val chirality: Int)

/**
 * Кадр, обработанный камерой:
 * • hands — найденные руки (до двух);
 * • brightness — яркость сцены (шкала APEX, как у iPhone): примерно −3 и ниже — темно,
 *   0 — полумрак, 2…5 — комната со светом, 7+ — улица днём. NaN — неизвестно;
 * • shoulders — плечи (две точки в тех же координатах, что и руки), если их нашли.
 */
class CameraFrame(val hands: List<CameraHand>, val brightness: Double, val shoulders: List<Pt>?)

/**
 * Блоки схемы «Обнаружение руки → Определение ключевых точек» (Google MediaPipe):
 * до двух рук по 21 точке и плечи человека. Работает только на потоке камеры.
 */
class HandTracker(private val context: Context) : Closeable {
    private var hands: HandLandmarker? = null
    private var pose: PoseLandmarker? = null
    private var useGpu = true
    private var lastHandTime = 0L
    private var lastPoseTime = 0L

    class Result(val hands: List<CameraHand>, val shoulders: List<Pt>?)

    /**
     * [bitmap] — кадр так, как он показан на экране (для фронтальной камеры — зеркально).
     * [mirrored] — кадр отражён (фронтальная камера): тогда MediaPipe определяет руку правильно,
     * а для незеркального кадра задней камеры правую и левую руки нужно поменять местами.
     */
    fun detect(bitmap: Bitmap, withShoulders: Boolean, mirrored: Boolean): Result {
        val image = BitmapImageBuilder(bitmap).build()
        return try {
            val found = detectHands(image, mirrored)
            val shoulders = if (withShoulders) detectShoulders(image) else null
            Result(found, shoulders)
        } catch (e: RuntimeException) {
            // Видеоускоритель на некоторых телефонах работает с ошибками — переходим на процессор.
            Log.w(TAG, "Detection failed, gpu=$useGpu", e)
            if (useGpu) {
                useGpu = false
                close()
            }
            Result(emptyList(), null)
        } finally {
            image.close()
        }
    }

    private fun detectHands(image: com.google.mediapipe.framework.image.MPImage, mirrored: Boolean): List<CameraHand> {
        val landmarker = hands ?: createHands().also { hands = it }
        lastHandTime = nextTimestamp(lastHandTime)
        val result = landmarker.detectForVideo(image, lastHandTime)
        val all = result.landmarks()
        val handedness = result.handedness()
        val out = ArrayList<CameraHand>(all.size)
        for ((i, landmarks) in all.withIndex()) {
            if (landmarks.size != 21) continue
            val points = landmarks.map { Pt(it.x(), it.y()) }
            // Уверенность нейросети в том, что это рука; точки MediaPipe находит всегда все 21.
            val category = handedness.getOrNull(i)?.firstOrNull()
            val score = category?.score() ?: 1f
            val confidence = List(21) { score }
            var chirality = when (category?.categoryName()) {
                "Right" -> 1
                "Left" -> -1
                else -> 0
            }
            if (!mirrored) chirality = -chirality
            out.add(CameraHand(points, confidence, chirality))
        }
        return out
    }

    /** Плечи ближайшего к камере человека: левое и правое плечо (точки 11 и 12). */
    private fun detectShoulders(image: com.google.mediapipe.framework.image.MPImage): List<Pt>? {
        val landmarker = pose ?: createPose().also { pose = it }
        lastPoseTime = nextTimestamp(lastPoseTime)
        val result = landmarker.detectForVideo(image, lastPoseTime)
        var best: List<Pt>? = null
        var bestWidth = 0f
        for (landmarks in result.landmarks()) {
            if (landmarks.size <= 12) continue
            val left = landmarks[11]
            val right = landmarks[12]
            if (left.visibility().orElse(1f) < 0.5f || right.visibility().orElse(1f) < 0.5f) continue
            val a = Pt(left.x(), left.y())
            val b = Pt(right.x(), right.y())
            val width = hypot(a.x - b.x, a.y - b.y)
            if (width > bestWidth) {
                bestWidth = width
                best = listOf(a, b)
            }
        }
        return best
    }

    private fun nextTimestamp(last: Long): Long = maxOf(SystemClock.uptimeMillis(), last + 1)

    private fun baseOptions(model: String): BaseOptions =
        BaseOptions.builder()
            .setModelAssetPath(model)
            .setDelegate(if (useGpu) Delegate.GPU else Delegate.CPU)
            .build()

    private fun createHands(): HandLandmarker {
        fun create(): HandLandmarker {
            val options = HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(baseOptions("hand_landmarker.task"))
                .setRunningMode(RunningMode.VIDEO)
                .setNumHands(2)
                .setMinHandDetectionConfidence(0.5f)
                .setMinHandPresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .build()
            return HandLandmarker.createFromOptions(context, options)
        }
        return try {
            create()
        } catch (e: RuntimeException) {
            if (!useGpu) throw e
            Log.w(TAG, "GPU is not available for hands, using CPU", e)
            useGpu = false
            create()
        }
    }

    private fun createPose(): PoseLandmarker {
        fun create(): PoseLandmarker {
            val options = PoseLandmarker.PoseLandmarkerOptions.builder()
                .setBaseOptions(baseOptions("pose_landmarker_lite.task"))
                .setRunningMode(RunningMode.VIDEO)
                .setNumPoses(1)
                .setMinPoseDetectionConfidence(0.5f)
                .setMinPosePresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .build()
            return PoseLandmarker.createFromOptions(context, options)
        }
        return try {
            create()
        } catch (e: RuntimeException) {
            if (!useGpu) throw e
            Log.w(TAG, "GPU is not available for pose, using CPU", e)
            useGpu = false
            create()
        }
    }

    override fun close() {
        hands?.close()
        pose?.close()
        hands = null
        pose = null
    }

    private companion object {
        const val TAG = "HandTracker"
    }
}
