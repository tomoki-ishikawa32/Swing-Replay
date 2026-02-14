import AVFoundation
import Combine
import Foundation
import SwingReplayCore

@MainActor
final class PhoneRuntimeController: ObservableObject {
    @Published private(set) var connectionText: String = "Searching"
    @Published private(set) var metricsText: String = "sent=0 dropped=0 queue=0"
    @Published private(set) var errorText: String?

    private let senderSession = PhoneSenderSession()
    private let transport = SenderTransportPipeline()
    private let capture = CameraCaptureService()
    private let encoder = RealtimeH264Encoder()

    private var metricsTimer: Timer?
    private var started = false

    init() {
        senderSession.stateDidChange = { [weak self] state in
            Task { @MainActor in
                self?.connectionText = Self.describe(state: state)
            }
        }

        capture.onSampleBuffer = { [weak self] sampleBuffer in
            self?.encoder.encode(sampleBuffer)
        }

        encoder.onFrameEncoded = { [weak self] frame in
            guard let self else { return }
            self.transport.send(encodedFrame: frame, sender: self.senderSession, reliably: true)
        }
    }

    func start() {
        guard !started else { return }
        started = true

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            Task { @MainActor in
                if !granted {
                    self.errorText = "Camera permission denied"
                    return
                }
                do {
                    try self.capture.configureSession()
                    try self.encoder.start()
                    self.senderSession.start()
                    self.capture.startRunning()
                    self.startMetricsTimer()
                } catch {
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        capture.stopRunning()
        encoder.flush()
        encoder.invalidate()
        senderSession.stop()
        started = false
    }

    private func startMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let metrics = self.transport.metrics()
                self.metricsText = "sent=\(metrics.sentFrames) dropped=\(metrics.droppedFrames) queue=\(metrics.queueLength)"
            }
        }
    }

    private static func describe(state: ConnectionState) -> String {
        switch state {
        case .searching:
            return "Searching"
        case .connecting:
            return "Connecting"
        case .connected(let peerName):
            return "Connected: \(peerName)"
        case .reconnecting:
            return "Reconnecting"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
