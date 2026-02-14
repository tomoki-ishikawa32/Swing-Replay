import Foundation
import OSLog

#if canImport(AVFoundation) && canImport(VideoToolbox)
public struct SenderMetrics: Equatable, Sendable {
    public let sentFrames: UInt64
    public let droppedFrames: UInt64
    public let queueLength: Int

    public init(sentFrames: UInt64, droppedFrames: UInt64, queueLength: Int) {
        self.sentFrames = sentFrames
        self.droppedFrames = droppedFrames
        self.queueLength = queueLength
    }
}
#endif

public final class SenderTransportPipeline {
    private let chunker: FrameChunker
    private let logger = Logger(subsystem: "SwingReplay", category: "SenderPipeline")
    private let maxInFlightFrames: Int

    private var inFlightFrames = 0
    private var sentFrames: UInt64 = 0
    private var droppedFrames: UInt64 = 0

    public init(maxChunkPayloadSize: Int = 48 * 1024, maxInFlightFrames: Int = 2) {
        self.chunker = FrameChunker(maxPayloadSize: maxChunkPayloadSize)
        self.maxInFlightFrames = max(1, maxInFlightFrames)
    }

    public func send(
        encodedFrame: EncodedVideoFrame,
        sender: PhoneSenderSession,
        reliably: Bool
    ) {
        if inFlightFrames >= maxInFlightFrames {
            droppedFrames += 1
            logger.debug("Drop frame due to in-flight limit")
            return
        }

        let chunks = chunker.makeChunks(
            frameIndex: encodedFrame.frameIndex,
            timestampMillis: encodedFrame.timestampMillis,
            isKeyFrame: encodedFrame.isKeyFrame,
            encodedFrame: encodedFrame.data
        )

        guard !chunks.isEmpty else {
            droppedFrames += 1
            return
        }

        inFlightFrames += 1
        defer { inFlightFrames = max(0, inFlightFrames - 1) }

        do {
            for chunk in chunks {
                try sender.send(chunk.encoded(), reliably: reliably)
            }
            sentFrames += 1
        } catch {
            droppedFrames += 1
            logger.error("Failed to send frame: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func metrics() -> SenderMetrics {
        SenderMetrics(
            sentFrames: sentFrames,
            droppedFrames: droppedFrames,
            queueLength: inFlightFrames
        )
    }
}
