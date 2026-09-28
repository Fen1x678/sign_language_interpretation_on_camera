import AVFoundation
import Vision

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

/// Блоки структурной схемы: «Камера → Получение видеокадров → Обнаружение руки → Определение ключевых точек».
///
/// Каждый кадр обрабатывается на фоновой очереди запросом Apple Vision
/// `VNDetectHumanHandPoseRequest`, который находит руку и 21 ключевую точку кисти.
/// Для каждой найденной руки (до двух) наружу отдаётся массив из 21 точки
/// в координатах камеры (0…1, начало — левый верхний угол).
/// Точка (-1, -1) означает, что эта точка не найдена или найдена неуверенно.
/// Пустой массив — рук в кадре нет.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let frames: AsyncStream<[[CGPoint]]>

    /// Какая камера сейчас используется.
    private(set) var position: AVCaptureDevice.Position = .front

    private let continuation: AsyncStream<[[CGPoint]]>.Continuation
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "gesture.camera.video", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false

    override init() {
        // Храним только самый свежий кадр: если обработка не успевает, старые кадры отбрасываются.
        let (stream, continuation) = AsyncStream.makeStream(of: [[CGPoint]].self,
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
        return try AVCaptureDeviceInput(device: device)
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
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results, !observations.isEmpty else {
                continuation.yield([])   // рук нет в кадре
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

            var hands: [[CGPoint]] = []
            for observation in observations {
                guard let recognized = try? observation.recognizedPoints(.all) else { continue }
                let points: [CGPoint] = order.map { name in
                    guard let point = recognized[name], point.confidence > 0.3 else {
                        return CGPoint(x: -1, y: -1)
                    }
                    // Vision: начало координат внизу слева → переводим в координаты устройства (вверху слева).
                    return CGPoint(x: point.location.x, y: 1 - point.location.y)
                }
                hands.append(points)
            }
            continuation.yield(hands)
        } catch {
            continuation.yield([])
        }
    }
}
