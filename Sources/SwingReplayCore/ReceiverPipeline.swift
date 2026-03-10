import Foundation
import OSLog

public struct ReceiverMetrics: Equatable, Sendable {
    public let bufferedFrames: Int
    public let reassemblyBacklog: Int
    public let estimatedLatencyMs: Int
    public let oldestFrameLatenessMs: Int
    public let newestFrameLeadMs: Int
    public let playbackOffsetMs: Int

    public init(
        bufferedFrames: Int,
        reassemblyBacklog: Int,
        estimatedLatencyMs: Int,
        oldestFrameLatenessMs: Int,
        newestFrameLeadMs: Int,
        playbackOffsetMs: Int
    ) {
        self.bufferedFrames = bufferedFrames
        self.reassemblyBacklog = reassemblyBacklog
        self.estimatedLatencyMs = estimatedLatencyMs
        self.oldestFrameLatenessMs = oldestFrameLatenessMs
        self.newestFrameLeadMs = newestFrameLeadMs
        self.playbackOffsetMs = playbackOffsetMs
    }
}

public final class ReceiverPipeline {
    private struct QueuedFrame {
        let frame: ReassembledFrame
        var dueTime: TimeInterval
    }

    private let reassembler: FrameReassembler
    private let logger = Logger(subsystem: "SwingReplay", category: "ReceiverPipeline")
    private let lock = NSLock()
    private let maxBufferedFrames: Int
    private var targetDelaySeconds: TimeInterval
    private var queuedFrames: [QueuedFrame] = []
    private var anchorSenderTimestampMillis: UInt64?
    private var anchorLocalTime: TimeInterval?
    private var lastSenderTimestampMillis: UInt64?
    private var playbackOffsetSeconds: TimeInterval = 0

    public init(
        targetDelaySeconds: TimeInterval = 3,
        maxPendingFrames: Int = 120,
        maxBufferedFrames: Int = 240
    ) {
        self.reassembler = FrameReassembler(maxPendingFrames: maxPendingFrames)
        self.maxBufferedFrames = maxBufferedFrames
        self.targetDelaySeconds = max(0, targetDelaySeconds)
    }

    public func receive(chunkData: Data, now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock()
        defer { lock.unlock() }

        guard let chunk = FrameChunk(encodedData: chunkData) else {
            logger.debug("Dropped invalid chunk data")
            return
        }

        if let frame = reassembler.append(chunk) {
            enqueue(frame: frame, now: now)
        }
    }

    public func popDisplayableFrame(now: TimeInterval = Date().timeIntervalSince1970) -> ReassembledFrame? {
        lock.lock()
        defer { lock.unlock() }

        guard let first = queuedFrames.first else {
            return nil
        }
        guard now >= first.dueTime else {
            return nil
        }

        queuedFrames.removeFirst()
        return first.frame
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        reassembler.reset()
        queuedFrames.removeAll(keepingCapacity: false)
        anchorSenderTimestampMillis = nil
        anchorLocalTime = nil
        lastSenderTimestampMillis = nil
        playbackOffsetSeconds = 0
    }
    
    public func setTargetDelaySeconds(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let newDelay = max(0, seconds)
        let delta = newDelay - targetDelaySeconds
        targetDelaySeconds = newDelay
        for index in queuedFrames.indices {
            queuedFrames[index].dueTime += delta
        }
    }

    public func metrics() -> ReceiverMetrics {
        lock.lock()
        defer { lock.unlock() }
        return makeMetrics(now: Date().timeIntervalSince1970)
    }

    private func enqueue(frame: ReassembledFrame, now: TimeInterval) {
        // Timestamp regression generally means stream reset/reconnect.
        if let last = lastSenderTimestampMillis, frame.timestampMillis + 2_000 < last {
            queuedFrames.removeAll(keepingCapacity: true)
            anchorSenderTimestampMillis = nil
            anchorLocalTime = nil
            playbackOffsetSeconds = 0
        }
        lastSenderTimestampMillis = frame.timestampMillis

        if anchorSenderTimestampMillis == nil {
            anchorSenderTimestampMillis = frame.timestampMillis
            anchorLocalTime = now
        }
        guard let anchorSenderTimestampMillis, let anchorLocalTime else {
            return
        }

        let elapsedMs = frame.timestampMillis >= anchorSenderTimestampMillis
            ? frame.timestampMillis - anchorSenderTimestampMillis
            : 0
        let dueTime = anchorLocalTime + (Double(elapsedMs) / 1_000.0) + targetDelaySeconds
        queuedFrames.append(QueuedFrame(frame: frame, dueTime: dueTime))
        queuedFrames.sort { $0.dueTime < $1.dueTime }

        if queuedFrames.count > maxBufferedFrames {
            let overflow = queuedFrames.count - maxBufferedFrames
            queuedFrames.removeFirst(overflow)
            logger.debug("Dropped \(overflow) buffered frame(s) to keep memory bounded")
        }
    }

    private func makeMetrics(now: TimeInterval) -> ReceiverMetrics {
        let estimatedLatencyMs = Int(targetDelaySeconds * 1_000)
        let oldestFrameLatenessMs: Int
        if let first = queuedFrames.first {
            oldestFrameLatenessMs = Int((now - first.dueTime) * 1_000)
        } else {
            oldestFrameLatenessMs = 0
        }

        let newestFrameLeadMs: Int
        if let last = queuedFrames.last {
            newestFrameLeadMs = Int((last.dueTime - now) * 1_000)
        } else {
            newestFrameLeadMs = 0
        }

        return ReceiverMetrics(
            bufferedFrames: queuedFrames.count,
            reassemblyBacklog: reassembler.pendingFrameCount,
            estimatedLatencyMs: estimatedLatencyMs,
            oldestFrameLatenessMs: oldestFrameLatenessMs,
            newestFrameLeadMs: newestFrameLeadMs,
            playbackOffsetMs: 0
        )
    }
}
