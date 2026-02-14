import Foundation
import Testing
@testable import SwingReplayCore

struct SwingReplayCoreTests {
    @Test
    func packetRoundTrip() {
        let header = FramePacketHeader(
            frameIndex: 42,
            timestampMillis: 1_735_000_100,
            chunkIndex: 1,
            chunkCount: 3,
            payloadSize: 4,
            isKeyFrame: true
        )
        let payload = Data([1, 2, 3, 4])
        let chunk = FrameChunk(header: header, payload: payload)

        let encoded = chunk.encoded()
        let decoded = FrameChunk(encodedData: encoded)

        #expect(decoded != nil)
        #expect(decoded?.header == header)
        #expect(decoded?.payload == payload)
    }

    @Test
    func chunkAndReassembleFrame() {
        let frameData = Data((0..<200_000).map { UInt8($0 % 251) })
        let chunker = FrameChunker(maxPayloadSize: 32 * 1024)
        let chunks = chunker.makeChunks(
            frameIndex: 7,
            timestampMillis: 1_735_000_200,
            isKeyFrame: false,
            encodedFrame: frameData
        )

        #expect(!chunks.isEmpty)

        let reassembler = FrameReassembler()
        var output: ReassembledFrame?

        for chunk in chunks.reversed() {
            output = reassembler.append(chunk) ?? output
        }

        #expect(output != nil)
        #expect(output?.frameIndex == 7)
        #expect(output?.isKeyFrame == false)
        #expect(output?.data == frameData)
    }

    @Test
    func delayBufferReleasesAfterDelay() {
        let buffer = DelayBuffer<String>(targetDelay: 3, maxCount: 3)

        buffer.append("A", now: 100)
        buffer.append("B", now: 101)

        #expect(buffer.popReady(now: 102) == nil)
        #expect(buffer.popReady(now: 103) == "A")
        #expect(buffer.popReady(now: 104) == "B")
    }

    @Test
    func delayBufferDropsOldestWhenOverflow() {
        let buffer = DelayBuffer<Int>(targetDelay: 0, maxCount: 2)

        buffer.append(1, now: 100)
        buffer.append(2, now: 101)
        buffer.append(3, now: 102)

        #expect(buffer.count == 2)
        #expect(buffer.popReady(now: 200) == 2)
        #expect(buffer.popReady(now: 200) == 3)
    }

    @Test
    func receiverPipelineReassemblesAndDelaysFrames() {
        let sourceFrame = Data((0..<70_000).map { UInt8($0 % 200) })
        let chunks = FrameChunker(maxPayloadSize: 16 * 1024).makeChunks(
            frameIndex: 99,
            timestampMillis: 1_735_000_300,
            isKeyFrame: true,
            encodedFrame: sourceFrame
        )

        let pipeline = ReceiverPipeline(targetDelaySeconds: 3, maxPendingFrames: 10, maxBufferedFrames: 10)
        for chunk in chunks {
            pipeline.receive(chunkData: chunk.encoded(), now: 100)
        }

        #expect(pipeline.metrics().bufferedFrames == 1)
        #expect(pipeline.popDisplayableFrame(now: 102) == nil)

        let frame = pipeline.popDisplayableFrame(now: 103)
        #expect(frame?.frameIndex == 99)
        #expect(frame?.isKeyFrame == true)
        #expect(frame?.data == sourceFrame)
    }

    @Test
    func receiverPipelineDropsInvalidChunkData() {
        let pipeline = ReceiverPipeline(targetDelaySeconds: 0)
        pipeline.receive(chunkData: Data([1, 2, 3, 4]), now: 100)
        #expect(pipeline.metrics().bufferedFrames == 0)
    }

    @Test
    func failSafeRequestsRestartAfterNoFrameTimeout() {
        let controller = ReceiverFailSafeController(
            config: ReceiverFailSafeConfig(noFrameTimeoutSeconds: 3, maxBufferedFrames: 240, minFramesToPlay: 2)
        )
        controller.handleConnectionState(.connected(peerName: "iPhone"))
        controller.noteFrameReceived(now: 100)

        let action = controller.evaluate(metrics: ReceiverMetrics(bufferedFrames: 0, reassemblyBacklog: 0), now: 104)
        #expect(action == .restartReceiver)
        #expect(controller.runtimeState == .reconnecting)
    }

    @Test
    func failSafeRequestsPipelineResetOnBufferOverflow() {
        let controller = ReceiverFailSafeController(
            config: ReceiverFailSafeConfig(noFrameTimeoutSeconds: 10, maxBufferedFrames: 3, minFramesToPlay: 1)
        )
        controller.noteFrameReceived(now: 100)

        let action = controller.evaluate(metrics: ReceiverMetrics(bufferedFrames: 4, reassemblyBacklog: 0), now: 101)
        #expect(action == .resetPipeline)
        #expect(controller.runtimeState == .buffering)
    }

    @Test
    func failSafeMovesToPlayingWhenBufferedFramesAreEnough() {
        let controller = ReceiverFailSafeController(
            config: ReceiverFailSafeConfig(noFrameTimeoutSeconds: 10, maxBufferedFrames: 10, minFramesToPlay: 2)
        )
        controller.noteFrameReceived(now: 100)

        let action = controller.evaluate(metrics: ReceiverMetrics(bufferedFrames: 2, reassemblyBacklog: 0), now: 101)
        #expect(action == .none)
        #expect(controller.runtimeState == .playing)
    }
}
