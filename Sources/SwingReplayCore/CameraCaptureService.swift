import Foundation
import OSLog
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)
public final class CameraCaptureService: NSObject, @unchecked Sendable {
    public struct Configuration: Sendable {
        public let width: Int32
        public let height: Int32
        public let fps: Int32

        public init(width: Int32 = 960, height: Int32 = 540, fps: Int32 = 24) {
            self.width = width
            self.height = height
            self.fps = fps
        }
    }

    public let session = AVCaptureSession()
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let outputQueue = DispatchQueue(label: "swingreplay.capture.output")
    private let logger = Logger(subsystem: "SwingReplay", category: "CameraCapture")
    private let configuration: Configuration
    private var lastFrameTime: CMTime?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        super.init()
    }

    public func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraCaptureError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        try configure(camera: camera)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)

        _ = output.connection(with: .video)
    }

    public func startRunning() {
        guard !session.isRunning else { return }
        outputQueue.async { [weak self] in
            self?.session.startRunning()
            self?.logger.info("Capture session started")
        }
    }

    public func stopRunning() {
        guard session.isRunning else { return }
        outputQueue.async { [weak self] in
            self?.session.stopRunning()
            self?.logger.info("Capture session stopped")
        }
    }

    private func configure(camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        let targetDimension = CMVideoDimensions(width: configuration.width, height: configuration.height)
        if let format = camera.formats.first(where: {
            let dim = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dim.width == targetDimension.width && dim.height == targetDimension.height
        }) {
            camera.activeFormat = format
        }

        let frameDuration = CMTime(value: 1, timescale: configuration.fps)
        camera.activeVideoMinFrameDuration = frameDuration
        camera.activeVideoMaxFrameDuration = frameDuration
    }
}

public enum CameraCaptureError: Error {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let currentPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let previousPTS = lastFrameTime {
            let delta = CMTimeSubtract(currentPTS, previousPTS)
            logger.debug("Frame interval: \(delta.seconds, privacy: .public)")
        }
        lastFrameTime = currentPTS

        onSampleBuffer?(sampleBuffer)
    }
}
#endif
