import Foundation
#if canImport(UIKit) && canImport(SwiftUI) && canImport(AVFoundation)
import UIKit
import SwiftUI
import AVFoundation

public enum ReceiverVideoGravity: Sendable {
    case fill
    case fit

    var avLayerGravity: AVLayerVideoGravity {
        switch self {
        case .fill:
            return .resizeAspectFill
        case .fit:
            return .resizeAspect
        }
    }
}

public final class SampleBufferDisplayView: UIView {
    private var droppedFrameCount: UInt64 = 0

    override public class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    public var displayLayer: AVSampleBufferDisplayLayer {
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            fatalError("Unexpected layer type")
        }
        return layer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    public func setGravity(_ gravity: ReceiverVideoGravity) {
        displayLayer.videoGravity = gravity.avLayerGravity
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        if !displayLayer.isReadyForMoreMediaData {
            droppedFrameCount += 1
            // Keep latest frame policy: drop queued frames and show newest.
            displayLayer.flushAndRemoveImage()
        }

        displayLayer.enqueue(sampleBuffer)
    }

    public func reset() {
        displayLayer.flushAndRemoveImage()
    }

    public func metricsDroppedFrames() -> UInt64 {
        droppedFrameCount
    }

    private func configureLayer() {
        displayLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
    }
}

public struct ReceiverVideoContainerView: UIViewRepresentable {
    public typealias UIViewType = SampleBufferDisplayView

    private let gravity: ReceiverVideoGravity
    private let onMakeView: ((SampleBufferDisplayView) -> Void)?

    public init(gravity: ReceiverVideoGravity = .fill, onMakeView: ((SampleBufferDisplayView) -> Void)? = nil) {
        self.gravity = gravity
        self.onMakeView = onMakeView
    }

    public func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        view.backgroundColor = .black
        view.setGravity(gravity)
        onMakeView?(view)
        return view
    }

    public func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {
        uiView.setGravity(gravity)
    }
}

public struct ReceiverFullScreenView: View {
    private let gravity: ReceiverVideoGravity
    private let onMakeView: ((SampleBufferDisplayView) -> Void)?

    public init(gravity: ReceiverVideoGravity = .fill, onMakeView: ((SampleBufferDisplayView) -> Void)? = nil) {
        self.gravity = gravity
        self.onMakeView = onMakeView
    }

    public var body: some View {
        GeometryReader { proxy in
            ReceiverVideoContainerView(gravity: gravity, onMakeView: onMakeView)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .ignoresSafeArea()
        }
    }
}
#endif
