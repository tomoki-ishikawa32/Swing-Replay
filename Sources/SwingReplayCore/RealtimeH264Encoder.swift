import Foundation
import OSLog
#if canImport(AVFoundation) && canImport(VideoToolbox)
import AVFoundation
import VideoToolbox
#endif

#if canImport(AVFoundation) && canImport(VideoToolbox)
public struct EncodedVideoFrame: Sendable, Equatable {
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

public final class RealtimeH264Encoder {
    public struct Configuration: Sendable {
        public let width: Int32
        public let height: Int32
        public let fps: Int32
        public let bitrate: Int32
        public let keyFrameInterval: Int32

        public init(
            width: Int32 = 960,
            height: Int32 = 540,
            fps: Int32 = 24,
            bitrate: Int32 = 1_000_000,
            keyFrameInterval: Int32 = 24
        ) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
            self.keyFrameInterval = keyFrameInterval
        }
    }

    public var onFrameEncoded: ((EncodedVideoFrame) -> Void)?

    private let config: Configuration
    private let logger = Logger(subsystem: "SwingReplay", category: "H264Encoder")
    private var session: VTCompressionSession?
    private var frameIndex: UInt64 = 0

    public init(configuration: Configuration = .init()) {
        self.config = configuration
    }

    deinit {
        invalidate()
    }

    public func start() throws {
        guard session == nil else { return }

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: config.width,
            height: config.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &newSession
        )

        guard status == noErr, let newSession else {
            throw EncoderError.sessionCreateFailed(status)
        }

        session = newSession

        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)

        var bitrate = config.bitrate
        let bitrateCF = CFNumberCreate(nil, .sInt32Type, &bitrate)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateCF)

        var interval = config.keyFrameInterval
        let intervalCF = CFNumberCreate(nil, .sInt32Type, &interval)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: intervalCF)

        var expectedFPS = config.fps
        let fpsCF = CFNumberCreate(nil, .sInt32Type, &expectedFPS)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fpsCF)

        VTCompressionSessionPrepareToEncodeFrames(newSession)
        logger.info("Encoder started")
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        frameIndex += 1

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: timestamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: Int(frameIndex)),
            infoFlagsOut: nil
        )

        if status != noErr {
            logger.error("Encode failed status=\(status)")
        }
    }

    public func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    public func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            logger.info("Encoder invalidated")
        }
    }

    fileprivate func handleEncodedBuffer(_ sampleBuffer: CMSampleBuffer, status: OSStatus, frameIndex: UInt64) {
        guard status == noErr else {
            logger.error("Compression callback error status=\(status)")
            return
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            logger.debug("Dropped frame: sample buffer not ready")
            return
        }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let firstAttachment = attachmentsArray.first
        else {
            return
        }

        let isKeyFrame = !(firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampMillis = UInt64(max(0, timestamp.seconds * 1000))

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let statusPointer = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard statusPointer == noErr, let dataPointer else {
            logger.error("Failed to read block buffer")
            return
        }

        let avccData = Data(bytes: dataPointer, count: totalLength)
        var annexBData = convertAVCCToAnnexB(avccData)
        if isKeyFrame, let parameterSets = parameterSetsAnnexB(from: sampleBuffer) {
            annexBData = parameterSets + annexBData
        }

        guard !annexBData.isEmpty else {
            logger.debug("Dropped frame: empty encoded data")
            return
        }

        onFrameEncoded?(EncodedVideoFrame(
            frameIndex: frameIndex,
            timestampMillis: timestampMillis,
            isKeyFrame: isKeyFrame,
            data: annexBData
        ))
    }

    private func convertAVCCToAnnexB(_ data: Data) -> Data {
        var offset = 0
        var output = Data()

        while offset + 4 <= data.count {
            let lengthBytes = data[offset..<(offset + 4)]
            let naluLength = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4

            guard naluLength > 0 else { continue }
            guard offset + Int(naluLength) <= data.count else {
                return Data()
            }

            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data[offset..<(offset + Int(naluLength))])
            offset += Int(naluLength)
        }

        return output
    }
    
    private func parameterSetsAnnexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        
        var setCount: Int = 0
        var headerLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &setCount,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard countStatus == noErr, setCount > 0 else { return nil }
        
        var output = Data()
        for index in 0..<setCount {
            var pointer: UnsafePointer<UInt8>?
            var size: Int = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                continue
            }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(pointer, count: size)
        }
        
        return output.isEmpty ? nil : output
    }
}

private let compressionCallback: VTCompressionOutputCallback = { refcon, sourceFrameRefCon, status, _, sampleBuffer in
    guard let refcon, let sampleBuffer else { return }
    let encoder = Unmanaged<RealtimeH264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    let raw = sourceFrameRefCon.map { UInt(bitPattern: $0) } ?? 0
    encoder.handleEncodedBuffer(sampleBuffer, status: status, frameIndex: UInt64(raw))
}

public enum EncoderError: Error {
    case sessionCreateFailed(OSStatus)
}
#endif
