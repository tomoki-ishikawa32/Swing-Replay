import AVFoundation
import SwiftUI

struct PhoneRootView: View {
    @ObservedObject var runtime: PhoneRuntimeController

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PhoneCameraPreviewView(session: runtime.captureSession)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.15),
                        Color.black.opacity(0.45)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Swing Replay / Phone")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)

                    Text("Status: \(runtime.connectionText)")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.95))

                    Text("Metrics: \(runtime.metricsText)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.white.opacity(0.9))

                    if let error = runtime.errorText {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    Spacer()
                }
                .padding(24)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

private struct PhoneCameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.attach(session: session)
    }
}

private final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    private var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }
}
