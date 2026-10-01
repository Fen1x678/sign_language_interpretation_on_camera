import SwiftUI
import AVFoundation

/// UIView, слоем которого является слой предпросмотра камеры.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

/// Изображение с камеры в SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayerReady: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onLayerReady(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Скелет кистей (одной или двух) и плечи поверх изображения.
/// Следит только за `LiveState`, поэтому на каждом кадре перерисовывается только он.
struct HandOverlay: View {
    @ObservedObject var live: LiveState
    let isActive: Bool

    private static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),            // большой
        (0, 5), (5, 6), (6, 7), (7, 8),            // указательный
        (9, 10), (10, 11), (11, 12),               // средний
        (13, 14), (14, 15), (15, 16),              // безымянный
        (0, 17), (17, 18), (18, 19), (19, 20),     // мизинец
        (5, 9), (9, 13), (13, 17)                  // ладонь
    ]

    var body: some View {
        let allHands = live.handPoints
        let resting = live.resting
        let shoulders = live.shoulders
        let bones = Self.bones
        let color: Color = isActive ? .green : .yellow

        Canvas { context, _ in
          // Плечи — так же, как точки рук: линия между плечами и две точки.
          if shoulders.count == 2 {
            var line = Path()
            line.move(to: shoulders[0])
            line.addLine(to: shoulders[1])
            context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 3)
            for point in shoulders {
                let rect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
          }
          for (h, pts) in allHands.enumerated() where pts.count == 21 {
            // Опущенная рука не учитывается — рисуем её серым.
            let isResting = h < resting.count && resting[h]
            var path = Path()
            for (a, b) in bones where pts[a].x >= 0 && pts[b].x >= 0 {
                path.move(to: pts[a])
                path.addLine(to: pts[b])
            }
            let boneColor: Color = isResting ? Color.gray.opacity(0.6) : Color.white.opacity(0.85)
            context.stroke(path, with: .color(boneColor), lineWidth: 3)

            let jointColor: Color = isResting ? Color.gray : color
            for (i, point) in pts.enumerated() where point.x >= 0 {
                let isTip = [4, 8, 12, 16, 20].contains(i)
                let r: CGFloat = isTip ? 7 : 5
                let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(jointColor))
            }
          }
        }
    }
}
