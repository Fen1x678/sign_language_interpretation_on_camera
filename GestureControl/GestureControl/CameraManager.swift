import AVFoundation
import Vision
import ImageIO

enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera:        return "Камера не найдена. Запустите приложение на реальном iPhone (в симуляторе камеры нет)."
        case .cannotAddInput:  return "Не удалось подключить камеру."
        case .cannotAddOutput: return "Не удалось получить видеопоток с камеры."
        }
    }
}

/// Рука, найденная на кадре: 21 точка в координатах камеры (0…1, начало — левый верхний угол)
/// и уверенность нейросети в каждой точке (0…1). Точка (-1, -1) с уверенностью 0 — не найдена совсем.
/// Точки с низкой уверенностью (например, пальцы, скрытые при повороте руки боком) тоже передаются:
/// дальше они учитываются с меньшим весом, а не отбрасываются.
typealias CameraHand = (points: [CGPoint], confidence: [Float])

/// Кадр, обработанный камерой:
/// • hands — найденные руки (до двух);
/// • brightness — яркость сцены по данным камеры (EXIF BrightnessValue, шкала APEX):
///   примерно −3 и ниже — темно, 0 — полумрак, 2…5 — комната со светом, 7+ — улица днём.
///   NaN — камера не сообщила яркость.
typealias CameraFrame = (hands: [CameraHand], brightness: Double)

/// Блоки структурной схемы: «Камера → Получение видеокадров → Обнаружение руки → Определение ключевых точек».
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let frames: AsyncStream<CameraFrame>

    /// Какая камера сейчас используется.
    private(set) var position: AVCaptureDevice.Position = .front

    /// Есть ли фонарик у текущей камеры (у фронтальной его нет).
    var hasTorch: Bool {
        guard let device = currentInput?.device else { return false }
        return device.hasTorch && device.isTorchAvailable
    }

    private let continuation: AsyncStream<CameraFrame>.Continuation
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "gesture.camera.video", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false

    override init() {
        // Храним только самый свежий кадр: если обработка не успевает, старые кадры отбрасываются.
        let (stream, continuation) = AsyncStream.makeStream(of: CameraFrame.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        self.frames = stream
        self.continuation = continuation
        super.init()
    }

    func configure() throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        let input = try makeInput(for: position)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        currentInput = input

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(videoOutput)

        isConfigured = true
    }

    /// Переключение между фронтальной и задней камерой.
    func switchCamera() throws {
        guard isConfigured else { return }
        setTorch(false)
        let newPosition: AVCaptureDevice.Position = position == .front ? .back : .front
        let newInput = try makeInput(for: newPosition)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput { session.removeInput(currentInput) }
        guard session.canAddInput(newInput) else {
            if let currentInput { session.addInput(currentInput) }
            throw CameraError.cannotAddInput
        }
        session.addInput(newInput)
        currentInput = newInput
        position = newPosition
    }

    private func makeInput(for position: AVCaptureDevice.Position) throws -> AVCaptureDeviceInput {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.noCamera
        }
        improveLowLight(device)
        return try AVCaptureDeviceInput(device: device)
    }

    /// В темноте камера сама поднимает чувствительность (если модель iPhone это умеет).
    private func improveLowLight(_ device: AVCaptureDevice) {
        guard device.isLowLightBoostSupported else { return }
        do {
            try device.lockForConfiguration()
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
            device.unlockForConfiguration()
        } catch {
            // Не критично: работаем без усиления.
        }
    }

    /// Включает или выключает фонарик задней камеры.
    func setTorch(_ on: Bool) {
        guard let device = currentInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on {
                if device.isTorchAvailable {
                    // Не на полную мощность: ярко, но телефон меньше греется.
                    try device.setTorchModeOn(level: min(0.8, AVCaptureDevice.maxAvailableTorchLevel))
                }
            } else if device.torchMode != .off {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            // Фонарик занят или недоступен (например, телефон перегрелся).
        }
    }

    func startRunning() {
        nonisolated(unsafe) let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning { session.startRunning() }
        }
    }

    func stopRunning() {
        nonisolated(unsafe) let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Обработка кадра (фоновая очередь)

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Яркость сцены из метаданных кадра.
        var brightness = Double.nan
        if let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any],
           let value = exif[kCGImagePropertyExifBrightnessValue as String] as? Double {
            brightness = value
        }

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else {
                continuation.yield((hands: [], brightness: brightness))   // рук нет в кадре
                return
            }

            // Порядок точек: запястье, затем по 4 точки на каждый палец (от основания к кончику).
            let order: [VNHumanHandPoseObservation.JointName] = [
                .wrist,
                .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
                .indexMCP, .indexPIP, .indexDIP, .indexTip,
                .middleMCP, .middlePIP, .middleDIP, .middleTip,
                .ringMCP, .ringPIP, .ringDIP, .ringTip,
                .littleMCP, .littlePIP, .littleDIP, .littleTip
            ]

            var hands: [CameraHand] = []
            for observation in observations {
                guard let recognized = try? observation.recognizedPoints(.all) else { continue }
                var points: [CGPoint] = []
                var confidence: [Float] = []
                for name in order {
                    if let point = recognized[name], point.confidence > 0.01 {
                        // Vision: начало координат внизу слева → переводим в координаты устройства (вверху слева).
                        points.append(CGPoint(x: point.location.x, y: 1 - point.location.y))
                        confidence.append(point.confidence)
                    } else {
                        points.append(CGPoint(x: -1, y: -1))
                        confidence.append(0)
                    }
                }
                hands.append((points: points, confidence: confidence))
            }
            continuation.yield((hands: hands, brightness: brightness))
        } catch {
            continuation.yield((hands: [], brightness: brightness))
        }
    }
}
