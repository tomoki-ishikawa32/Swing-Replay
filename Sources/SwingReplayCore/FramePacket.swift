import Foundation

public struct FramePacketHeader: Equatable, Sendable {
    public static let byteCount = 25

    public let frameIndex: UInt64
    public let timestampMillis: UInt64
    public let chunkIndex: UInt16
    public let chunkCount: UInt16
    public let payloadSize: UInt32
    public let isKeyFrame: Bool

    public init(
        frameIndex: UInt64,
        timestampMillis: UInt64,
        chunkIndex: UInt16,
        chunkCount: UInt16,
        payloadSize: UInt32,
        isKeyFrame: Bool
    ) {
        self.frameIndex = frameIndex
        self.timestampMillis = timestampMillis
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.payloadSize = payloadSize
        self.isKeyFrame = isKeyFrame
    }

    public func encoded() -> Data {
        var data = Data()
        data.append(frameIndex.bigEndianBytes)
        data.append(timestampMillis.bigEndianBytes)
        data.append(chunkIndex.bigEndianBytes)
        data.append(chunkCount.bigEndianBytes)
        data.append(payloadSize.bigEndianBytes)
        data.append(isKeyFrame ? 1 : 0)
        return data
    }

    public init?(data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        var cursor = 0

        guard let frameIndex = data.readUInt64(at: &cursor),
              let timestampMillis = data.readUInt64(at: &cursor),
              let chunkIndex = data.readUInt16(at: &cursor),
              let chunkCount = data.readUInt16(at: &cursor),
              let payloadSize = data.readUInt32(at: &cursor),
              let keyFlag = data.readUInt8(at: &cursor)
        else {
            return nil
        }

        self.frameIndex = frameIndex
        self.timestampMillis = timestampMillis
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.payloadSize = payloadSize
        self.isKeyFrame = keyFlag != 0
    }
}

public struct FrameChunk: Equatable, Sendable {
    public let header: FramePacketHeader
    public let payload: Data

    public init(header: FramePacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public func encoded() -> Data {
        var output = header.encoded()
        output.append(payload)
        return output
    }

    public init?(encodedData: Data) {
        guard let header = FramePacketHeader(data: encodedData) else {
            return nil
        }

        let payload = encodedData.dropFirst(FramePacketHeader.byteCount)
        guard payload.count == Int(header.payloadSize) else {
            return nil
        }

        self.header = header
        self.payload = Data(payload)
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: Data {
        var be = self.bigEndian
        return Swift.withUnsafeBytes(of: &be) { Data($0) }
    }
}

private extension Data {
    mutating func append(_ value: UInt8) {
        append(contentsOf: [value])
    }

    func readUInt8(at cursor: inout Int) -> UInt8? {
        guard cursor + 1 <= count else { return nil }
        defer { cursor += 1 }
        return self[cursor]
    }

    func readUInt16(at cursor: inout Int) -> UInt16? {
        guard cursor + 2 <= count else { return nil }
        defer { cursor += 2 }
        var value: UInt16 = 0
        for index in cursor..<(cursor + 2) {
            value = (value << 8) | UInt16(self[index])
        }
        return value
    }

    func readUInt32(at cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= count else { return nil }
        defer { cursor += 4 }
        var value: UInt32 = 0
        for index in cursor..<(cursor + 4) {
            value = (value << 8) | UInt32(self[index])
        }
        return value
    }

    func readUInt64(at cursor: inout Int) -> UInt64? {
        guard cursor + 8 <= count else { return nil }
        defer { cursor += 8 }
        var value: UInt64 = 0
        for index in cursor..<(cursor + 8) {
            value = (value << 8) | UInt64(self[index])
        }
        return value
    }
}
