import Foundation
import OSLog
#if canImport(AVFoundation) && canImport(VideoToolbox)
import AVFoundation
import VideoToolbox
#endif

#if canImport(AVFoundation) && canImport(VideoToolbox)
public struct DecodedVideoFrame {
    public let frameIndex: UInt64
    public let timestampMillis: UInt64
    public let sampleBuffer: CMSampleBuffer

    public init(frameIndex: UInt64, timestampMillis: UInt64, sampleBuffer: CMSampleBuffer) {
        self.frameIndex = frameIndex
        self.timestampMillis = timestampMillis
        self.sampleBuffer = sampleBuffer
    }
}

public final class RealtimeH264Decoder {
    public var onFrameDecoded: ((DecodedVideoFrame) -> Void)?
    public var preferDisplayLayerDirectPath = true

    private let logger = Logger(subsystem: "SwingReplay", category: "H264Decoder")

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    private var currentSPS: Data?
    private var currentPPS: Data?

    public init(maxInFlightDecodes: Int = 2) {}

    deinit {
        invalidate()
    }

    public func decode(frame: ReassembledFrame) {
        let nals = splitAnnexBNALUnits(frame.data)
        guard !nals.isEmpty else {
            logger.debug("Drop invalid AnnexB frame")
            return
        }

        updateParameterSetsIfPresent(nals)

        guard ensureDecoderSession() else {
            logger.debug("Drop frame because decoder session is unavailable")
            return
        }

        let avccPayload = makeAVCCData(from: nals)
        guard !avccPayload.isEmpty else {
            logger.debug("Drop frame due to AVCC conversion failure")
            return
        }

        guard let sampleBuffer = makeSampleBuffer(avccData: avccPayload, timestampMillis: frame.timestampMillis) else {
            logger.debug("Drop frame due to sample buffer failure")
            return
        }
        
        if preferDisplayLayerDirectPath {
            onFrameDecoded?(DecodedVideoFrame(
                frameIndex: frame.frameIndex,
                timestampMillis: frame.timestampMillis,
                sampleBuffer: sampleBuffer
            ))
            return
        }

        guard let session = decompressionSession else {
            return
        }

        var flagsOut = VTDecodeInfoFlags()

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: UnsafeMutableRawPointer(bitPattern: Int(frame.frameIndex)),
            infoFlagsOut: &flagsOut
        )

        if status != noErr {
            logger.error("Decode request failed: \(status)")
        }
    }

    public func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        currentSPS = nil
        currentPPS = nil
    }

    private func ensureDecoderSession() -> Bool {
        if decompressionSession != nil {
            return true
        }

        guard let sps = currentSPS, let pps = currentPPS else {
            return false
        }

        guard let formatDescription = createFormatDescription(sps: sps, pps: pps) else {
            logger.error("Format description create failed")
            return false
        }

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionCallback,
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &decompressionSession
        )

        guard sessionStatus == noErr else {
            logger.error("Decoder session create failed: \(sessionStatus)")
            return false
        }

        self.formatDescription = formatDescription
        return true
    }
    
    private func createFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var formatDescription: CMVideoFormatDescription?
        let parameterSetSizes = [sps.count, pps.count]
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsPtr = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard status == noErr, let description = formatDescription else {
            return nil
        }
        return description
    }

    private func updateParameterSetsIfPresent(_ nals: [Data]) {
        for nal in nals {
            guard let nalType = nal.first.map({ $0 & 0x1F }) else { continue }
            switch nalType {
            case 7:
                currentSPS = nal
                refreshSessionOnParameterSetUpdate()
            case 8:
                currentPPS = nal
                refreshSessionOnParameterSetUpdate()
            default:
                break
            }
        }
    }

    private func refreshSessionOnParameterSetUpdate() {
        if decompressionSession != nil {
            VTDecompressionSessionInvalidate(decompressionSession!)
            decompressionSession = nil
            formatDescription = nil
        }
    }

    private func splitAnnexBNALUnits(_ frameData: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](frameData)

        var index = 0
        var start = -1

        while index + 3 < bytes.count {
            let isThree = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            let isFour = index + 4 < bytes.count && bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 0 && bytes[index + 3] == 1

            if isThree || isFour {
                let delimiter = isFour ? 4 : 3
                if start >= 0 && start < index {
                    units.append(Data(bytes[start..<index]))
                }
                start = index + delimiter
                index += delimiter
                continue
            }
            index += 1
        }

        if start >= 0 && start < bytes.count {
            units.append(Data(bytes[start..<bytes.count]))
        }

        return units.filter { !$0.isEmpty }
    }

    private func makeAVCCData(from nals: [Data]) -> Data {
        let videoSlices = nals.filter { nal in
            guard let nalType = nal.first.map({ $0 & 0x1F }) else { return false }
            return nalType == 1 || nalType == 5
        }
        let targetNals = videoSlices.isEmpty ? nals.filter { nal in
            guard let nalType = nal.first.map({ $0 & 0x1F }) else { return false }
            return nalType != 7 && nalType != 8
        } : videoSlices

        var output = Data()
        for nal in targetNals {
            guard let length = UInt32(exactly: nal.count) else { return Data() }
            let be = length.bigEndian
            Swift.withUnsafeBytes(of: be) { output.append(contentsOf: $0) }
            output.append(nal)
        }
        return output
    }

    private func makeSampleBuffer(avccData: Data, timestampMillis: UInt64) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }
        
        let replaceStatus = avccData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        _ = timestampMillis
        return sampleBuffer
    }

    fileprivate func handleDecodedFrame(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        frameRefCon: UnsafeMutableRawPointer?
    ) {
        guard status == noErr, let imageBuffer else {
            logger.debug("Decoder dropped frame status=\(status)")
            return
        }

        guard let formatDescription else {
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let statusSB = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard statusSB == noErr, let sampleBuffer else {
            return
        }

        let frameIndexRaw = frameRefCon.map { UInt(bitPattern: $0) } ?? 0
        let timestampMillis = UInt64(max(0, presentationTimeStamp.seconds * 1000))
        onFrameDecoded?(DecodedVideoFrame(frameIndex: UInt64(frameIndexRaw), timestampMillis: timestampMillis, sampleBuffer: sampleBuffer))
    }
}

private let decompressionCallback: VTDecompressionOutputCallback = {
    refCon,
    frameRefCon,
    status,
    _,
    imageBuffer,
    presentationTimeStamp,
    _
in
    guard let refCon else { return }
    let decoder = Unmanaged<RealtimeH264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecodedFrame(
        status: status,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        frameRefCon: frameRefCon
    )
}
#endif
