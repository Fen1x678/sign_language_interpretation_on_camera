package com.fen1x.speech.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.util.Log
import android.util.Size
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.log2
import kotlin.math.roundToInt

/**
 * Блоки структурной схемы: «Камера → Получение видеокадров → Обнаружение руки → Определение ключевых точек».
 *
 * Изображение с камеры показывается в [PreviewView], а кадры для распознавания обрезаются
 * ровно по видимой на экране области (ViewPort): поэтому координаты точек 0…1 сразу
 * переводятся в координаты экрана умножением на размер изображения.
 */
class CameraController(private val context: Context) {
    /** Обработанный кадр. Вызывается на потоке камеры. */
    @Volatile
    var onFrame: ((CameraFrame) -> Unit)? = null

    /** Искать плечи (вызывается с главного потока, читается на потоке камеры). */
    @Volatile
    var bodyTracking = true

    /** Какая камера используется: фронтальная (по умолчанию) или задняя. */
    @Volatile
    var isFront = true
        private set

    /** Есть ли фонарик у текущей камеры (у фронтальной обычно нет). */
    val hasTorch: Boolean get() = camera?.cameraInfo?.hasFlashUnit() == true

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var tracker: HandTracker? = null
    private var bindToken = 0

    // Картинки кадра переиспользуются (только на потоке камеры). Раньше на каждом кадре создавались
    // две новые картинки по ~1,2 МБ — около 70 МБ в секунду, и сборка мусора вызывала подёргивания.
    private var sourceBitmap: Bitmap? = null
    private var packedPixels: ByteBuffer? = null
    private var uprightBitmap: Bitmap? = null
    private var uprightCanvas: Canvas? = null
    private val uprightMatrix = Matrix()
    private val uprightBounds = RectF()
    private val uprightPaint = Paint(Paint.FILTER_BITMAP_FLAG)

    /** Яркость сцены по выдержке, светочувствительности и диафрагме (обновляется на каждом кадре). */
    @Volatile
    private var brightness = Double.NaN

    /** Ошибка камеры для экрана (вызывается на главном потоке). */
    var onError: ((String) -> Unit)? = null

    fun setFront(front: Boolean) {
        isFront = front
    }

    /** Подключить камеру к экрану. Повторный вызов переподключает (например, после смены камеры). */
    fun bind(owner: LifecycleOwner, previewView: PreviewView) {
        val token = ++bindToken
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (token != bindToken) return@addListener   // экран уже закрыт
            try {
                val provider = future.get()
                this.provider = provider
                bindUseCases(provider, owner, previewView)
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed", e)
                onError?.invoke("Не удалось включить камеру: ${e.localizedMessage ?: e.javaClass.simpleName}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Отключить камеру (экран закрыт или открыта страница «Речь → текст»). */
    fun unbind() {
        bindToken++
        provider?.unbindAll()
        camera = null
    }

    fun setTorch(on: Boolean) {
        val camera = camera ?: return
        if (!camera.cameraInfo.hasFlashUnit()) return
        camera.cameraControl.enableTorch(on)
    }

    fun release() {
        unbind()
        executor.execute {
            tracker?.close()
            tracker = null
        }
        executor.shutdown()
    }

    @androidx.annotation.OptIn(markerClass = [ExperimentalCamera2Interop::class])
    private fun bindUseCases(provider: ProcessCameraProvider, owner: LifecycleOwner, previewView: PreviewView) {
        val selector = if (isFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        val ratio = AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY

        val preview = Preview.Builder()
            .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(ratio).build())
            .build()
        preview.setSurfaceProvider(previewView.surfaceProvider)

        // Небольших кадров достаточно: MediaPipe всё равно уменьшает их до ~200 точек.
        val analysisBuilder = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setAspectRatioStrategy(ratio)
                    .setResolutionStrategy(
                        ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                    )
                    .build(),
            )
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
        Camera2Interop.Extender(analysisBuilder).setSessionCaptureCallback(captureCallback)
        val analysis = analysisBuilder.build()
        val front = isFront
        analysis.setAnalyzer(executor) { image -> analyze(image, front) }

        val group = UseCaseGroup.Builder()
            .addUseCase(preview)
            .addUseCase(analysis)
        previewView.viewPort?.let { group.setViewPort(it) }

        provider.unbindAll()
        camera = provider.bindToLifecycle(owner, selector, group.build())
    }

    /** Яркость сцены (шкала APEX): Bv = Av + Tv − Sv — так же её считает камера iPhone. */
    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
            val exposure = result.get(CaptureResult.SENSOR_EXPOSURE_TIME) ?: return   // наносекунды
            val iso = result.get(CaptureResult.SENSOR_SENSITIVITY) ?: return
            if (exposure <= 0L || iso <= 0) return
            val boost = (result.get(CaptureResult.CONTROL_POST_RAW_SENSITIVITY_BOOST) ?: 100) / 100.0
            val aperture = (result.get(CaptureResult.LENS_APERTURE) ?: 1.8f).toDouble()
            val seconds = exposure / 1e9
            brightness = log2(aperture * aperture / seconds) - log2(iso * boost / 3.125)
        }
    }

    /** Кадр → точки рук и плеч (поток камеры). */
    private fun analyze(image: ImageProxy, front: Boolean) {
        try {
            val bitmap = sourcePixels(image)
            val crop = image.cropRect
            val left = crop.left.coerceIn(0, bitmap.width - 1)
            val top = crop.top.coerceIn(0, bitmap.height - 1)
            val width = crop.width().coerceIn(1, bitmap.width - left)
            val height = crop.height().coerceIn(1, bitmap.height - top)
            val upright = upright(bitmap, left, top, width, height, image.imageInfo.rotationDegrees, front)
            val tracker = tracker ?: HandTracker(context).also { tracker = it }
            val result = tracker.detect(upright, bodyTracking, front)
            onFrame?.invoke(CameraFrame(result.hands, brightness, result.shoulders))
        } catch (e: Exception) {
            Log.w(TAG, "Frame analysis failed", e)
        } finally {
            image.close()
        }
    }

    /** Пиксели кадра (RGBA) в переиспользуемой картинке. */
    private fun sourcePixels(image: ImageProxy): Bitmap {
        val plane = image.planes.firstOrNull()
        if (plane == null || plane.pixelStride != 4) return image.toBitmap()   // необычный формат — как раньше
        val width = image.width
        val height = image.height
        val bitmap = sourceBitmap?.takeIf { it.width == width && it.height == height && !it.isRecycled }
            ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { sourceBitmap = it }
        val rowBytes = width * 4
        val buffer = plane.buffer
        buffer.rewind()
        if (plane.rowStride == rowBytes && buffer.remaining() >= rowBytes * height) {
            bitmap.copyPixelsFromBuffer(buffer)
        } else {
            // Строки кадра с отступами в конце — собираем их подряд.
            val packed = packedPixels?.takeIf { it.capacity() == rowBytes * height }
                ?: ByteBuffer.allocateDirect(rowBytes * height).also { packedPixels = it }
            packed.clear()
            for (row in 0 until height) {
                val start = row * plane.rowStride
                buffer.limit(buffer.capacity())
                buffer.position(start)
                buffer.limit(start + rowBytes)
                packed.put(buffer)
            }
            buffer.limit(buffer.capacity())
            packed.flip()
            bitmap.copyPixelsFromBuffer(packed)
        }
        return bitmap
    }

    /**
     * Видимая часть кадра, повёрнутая как на экране (фронтальная камера — зеркально, как её показывает экран),
     * в переиспользуемой картинке. То же, что Bitmap.createBitmap(..., matrix, true), но без новой картинки.
     */
    private fun upright(source: Bitmap, left: Int, top: Int, width: Int, height: Int, rotation: Int, front: Boolean): Bitmap {
        val matrix = uprightMatrix
        matrix.reset()
        matrix.postRotate(rotation.toFloat())
        if (front) matrix.postScale(-1f, 1f)
        val bounds = uprightBounds
        bounds.set(0f, 0f, width.toFloat(), height.toFloat())
        matrix.mapRect(bounds)
        val outWidth = bounds.width().roundToInt().coerceAtLeast(1)
        val outHeight = bounds.height().roundToInt().coerceAtLeast(1)
        matrix.preTranslate(-left.toFloat(), -top.toFloat())
        matrix.postTranslate(-bounds.left, -bounds.top)

        var bitmap = uprightBitmap
        var canvas = uprightCanvas
        if (bitmap == null || canvas == null || bitmap.width != outWidth || bitmap.height != outHeight || bitmap.isRecycled) {
            bitmap = Bitmap.createBitmap(outWidth, outHeight, Bitmap.Config.ARGB_8888)
            canvas = Canvas(bitmap)
            uprightBitmap = bitmap
            uprightCanvas = canvas
        }
        canvas.drawBitmap(source, matrix, uprightPaint)
        return bitmap
    }

    private companion object {
        const val TAG = "CameraController"
    }
}
