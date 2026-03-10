import Combine
import Foundation
import SwingReplayCore

@MainActor
final class PadRuntimeController: ObservableObject {
    @Published private(set) var connectionText: String = "Waiting"
    @Published private(set) var debugText: String = "receiveFPS=0 buffered=0"
    @Published private(set) var runtimeText: String = "waiting"
    @Published var targetDelaySeconds: Double = 3 {
        didSet {
            pipeline.setTargetDelaySeconds(targetDelaySeconds)
        }
    }

    private let receiverSession = PadReceiverSession()
    nonisolated(unsafe) private let pipeline = ReceiverPipeline(targetDelaySeconds: 3)
    private let decoder = RealtimeH264Decoder()
    private let failSafe = ReceiverFailSafeController(
        config: ReceiverFailSafeConfig(noFrameTimeoutSeconds: 10, maxBufferedFrames: 240, minFramesToPlay: 24)
    )

    private weak var displayView: SampleBufferDisplayView?
    private let receiveQueue = DispatchQueue(label: "swingreplay.pad.receive")
    private var decodeTimer: Timer?
    private var monitorTimer: Timer?
    private var fpsCounter: Int = 0
    private var started = false

    init() {
        receiverSession.stateDidChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.connectionText = Self.describe(state: state)
                self.failSafe.handleConnectionState(state)
            }
        }

        receiverSession.didReceiveData = { [weak self] data, _ in
            guard let self else { return }
            self.receiveQueue.async { [weak self] in
                guard let self else { return }
                self.pipeline.receive(chunkData: data)
            }
        }

        decoder.onFrameDecoded = { [weak self] frame in
            guard let self else { return }
            Task { @MainActor in
                self.displayView?.enqueue(frame.sampleBuffer)
                self.fpsCounter += 1
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true

        receiverSession.start()
        startDecodeTimer()
        startMonitorTimer()
    }

    func stop() {
        decodeTimer?.invalidate()
        monitorTimer?.invalidate()
        decodeTimer = nil
        monitorTimer = nil
        receiverSession.stop()
        decoder.invalidate()
        displayView?.reset()
        failSafe.reset()
        started = false
    }

    func bindDisplayView(_ view: SampleBufferDisplayView) {
        displayView = view
    }

    private func startDecodeTimer() {
        decodeTimer?.invalidate()
        decodeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let bufferedFrames = self.pipeline.metrics().bufferedFrames
            let popBudget: Int
            switch bufferedFrames {
            case ...24:
                popBudget = 1
            case ...48:
                popBudget = 3
            default:
                popBudget = 5
            }

            for _ in 0..<popBudget {
                guard let frame = self.pipeline.popDisplayableFrame() else { break }
                // Decode all due frames in order. Dropping directly to the
                // newest frame makes playback alternate between slow and fast
                // and can also break inter-frame references.
                self.decoder.decode(frame: frame)
            }
        }
    }

    private func startMonitorTimer() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let metrics = self.pipeline.metrics()
                let action = self.failSafe.evaluate(metrics: metrics)
                self.apply(action: action)
                self.runtimeText = String(describing: self.failSafe.runtimeState)
                self.debugText = """
                receiveFPS=\(self.fpsCounter) buffered=\(metrics.bufferedFrames) reassembly=\(metrics.reassemblyBacklog)
                latencyMs=\(metrics.estimatedLatencyMs) lateMs=\(metrics.oldestFrameLatenessMs) leadMs=\(metrics.newestFrameLeadMs) offsetMs=\(metrics.playbackOffsetMs)
                """
                self.fpsCounter = 0
            }
        }
    }

    private func apply(action: ReceiverRecoveryAction) {
        switch action {
        case .none:
            break
        case .restartReceiver:
            // Avoid reconnect thrash while connection is being negotiated.
            if connectionText.hasPrefix("Connected") {
                receiverSession.stop()
                receiverSession.start()
            }
        case .resetPipeline:
            pipeline.reset()
            displayView?.reset()
        case .waitForBuffer:
            break
        }
    }

    private static func describe(state: ConnectionState) -> String {
        switch state {
        case .searching:
            return "Waiting"
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
