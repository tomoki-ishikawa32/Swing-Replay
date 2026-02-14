import Foundation

public struct FrameChunker: Sendable {
    public let maxPayloadSize: Int

    public init(maxPayloadSize: Int = 48 * 1024) {
        precondition(maxPayloadSize > 0, "maxPayloadSize must be positive")
        self.maxPayloadSize = maxPayloadSize
    }

    public func makeChunks(
        frameIndex: UInt64,
        timestampMillis: UInt64,
        isKeyFrame: Bool,
        encodedFrame: Data
    ) -> [FrameChunk] {
        guard !encodedFrame.isEmpty else { return [] }

        let chunkCount = Int(ceil(Double(encodedFrame.count) / Double(maxPayloadSize)))
        guard chunkCount <= Int(UInt16.max) else { return [] }

        var chunks: [FrameChunk] = []
        chunks.reserveCapacity(chunkCount)

        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * maxPayloadSize
            let end = min(start + maxPayloadSize, encodedFrame.count)
            let payload = Data(encodedFrame[start..<end])
            guard let payloadSize = UInt32(exactly: payload.count) else { continue }
            guard let chunkIndex16 = UInt16(exactly: chunkIndex),
                  let chunkCount16 = UInt16(exactly: chunkCount)
            else {
                continue
            }

            let header = FramePacketHeader(
                frameIndex: frameIndex,
                timestampMillis: timestampMillis,
                chunkIndex: chunkIndex16,
                chunkCount: chunkCount16,
                payloadSize: payloadSize,
                isKeyFrame: isKeyFrame
            )
            chunks.append(FrameChunk(header: header, payload: payload))
        }

        return chunks
    }
}

public final class FrameReassembler {
    private struct PartialFrame {
        let chunkCount: Int
        let isKeyFrame: Bool
        let timestampMillis: UInt64
        var chunks: [Int: Data]

        var isComplete: Bool { chunks.count == chunkCount }
    }

    private var partialFrames: [UInt64: PartialFrame] = [:]
    private let maxPendingFrames: Int
    
    public var pendingFrameCount: Int {
        partialFrames.count
    }

    public init(maxPendingFrames: Int = 120) {
        self.maxPendingFrames = max(1, maxPendingFrames)
    }

    public func append(_ chunk: FrameChunk) -> ReassembledFrame? {
        let frameID = chunk.header.frameIndex
        let expectedCount = Int(chunk.header.chunkCount)
        let chunkIndex = Int(chunk.header.chunkIndex)

        guard expectedCount > 0,
              chunkIndex >= 0,
              chunkIndex < expectedCount
        else {
            return nil
        }

        if partialFrames[frameID] == nil {
            if partialFrames.count >= maxPendingFrames,
               let oldestKey = partialFrames.keys.min() {
                partialFrames.removeValue(forKey: oldestKey)
            }

            partialFrames[frameID] = PartialFrame(
                chunkCount: expectedCount,
                isKeyFrame: chunk.header.isKeyFrame,
                timestampMillis: chunk.header.timestampMillis,
                chunks: [:]
            )
        }

        guard var partial = partialFrames[frameID], partial.chunkCount == expectedCount else {
            partialFrames.removeValue(forKey: frameID)
            return nil
        }

        partial.chunks[chunkIndex] = chunk.payload

        if partial.isComplete {
            partialFrames.removeValue(forKey: frameID)
            var output = Data()
            for index in 0..<partial.chunkCount {
                guard let data = partial.chunks[index] else { return nil }
                output.append(data)
            }

            return ReassembledFrame(
                frameIndex: frameID,
                timestampMillis: partial.timestampMillis,
                isKeyFrame: partial.isKeyFrame,
                data: output
            )
        }

        partialFrames[frameID] = partial
        return nil
    }

    public func reset() {
        partialFrames.removeAll(keepingCapacity: false)
    }
}

public struct ReassembledFrame: Equatable {
    public let frameIndex: UInt64
    public let timestampMillis: UInt64
    public let isKeyFrame: Bool
    public let data: Data

    public init(frameIndex: UInt64, timestampMillis: UInt64, isKeyFrame: Bool, data: Data) {
        self.frameIndex = frameIndex
        self.timestampMillis = timestampMillis
        self.isKeyFrame = isKeyFrame
        self.data = data
    }
}
