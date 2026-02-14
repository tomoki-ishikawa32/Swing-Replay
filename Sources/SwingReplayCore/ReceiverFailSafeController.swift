import Foundation

public enum ReceiverRuntimeState: Equatable, Sendable {
    case waiting
    case connected
    case buffering
    case playing
    case reconnecting
    case error(message: String)
}

public enum ReceiverRecoveryAction: Equatable, Sendable {
    case none
    case restartReceiver
    case resetPipeline
    case waitForBuffer
}

public struct ReceiverFailSafeConfig: Equatable, Sendable {
    public let noFrameTimeoutSeconds: TimeInterval
    public let maxBufferedFrames: Int
    public let minFramesToPlay: Int

    public init(
        noFrameTimeoutSeconds: TimeInterval = 3,
        maxBufferedFrames: Int = 240,
        minFramesToPlay: Int = 24
    ) {
        self.noFrameTimeoutSeconds = max(1, noFrameTimeoutSeconds)
        self.maxBufferedFrames = max(1, maxBufferedFrames)
        self.minFramesToPlay = max(1, minFramesToPlay)
    }
}

public final class ReceiverFailSafeController {
    public private(set) var runtimeState: ReceiverRuntimeState = .waiting

    private let config: ReceiverFailSafeConfig
    private var lastFrameReceiveTime: TimeInterval?

    public init(config: ReceiverFailSafeConfig = .init()) {
        self.config = config
    }

    public func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .searching:
            runtimeState = .waiting
        case .connecting:
            runtimeState = .connected
        case .connected:
            runtimeState = .buffering
        case .reconnecting:
            runtimeState = .reconnecting
        case .error(let message):
            runtimeState = .error(message: message)
        }
    }

    public func noteFrameReceived(now: TimeInterval = Date().timeIntervalSince1970) {
        lastFrameReceiveTime = now
    }

    public func evaluate(
        metrics: ReceiverMetrics,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> ReceiverRecoveryAction {
        if metrics.bufferedFrames > config.maxBufferedFrames {
            runtimeState = .buffering
            return .resetPipeline
        }

        if let lastFrameReceiveTime,
           now - lastFrameReceiveTime > config.noFrameTimeoutSeconds {
            runtimeState = .reconnecting
            return .restartReceiver
        }

        if metrics.bufferedFrames < config.minFramesToPlay {
            runtimeState = .buffering
            return .waitForBuffer
        }

        runtimeState = .playing
        return .none
    }

    public func reset() {
        runtimeState = .waiting
        lastFrameReceiveTime = nil
    }
}
