import Darwin
import Foundation

enum DesktopViewStreamWire {
    static let version = UInt8(1)
    static let mediaHeaderBytes = 24
    static let companionUpgrade = "oppi-desktop-view"
    static let path = "/view/stream"
    static let jsonType: UInt8 = 1
    static let mediaType: UInt8 = 2
    static let flagKeyframe: UInt8 = 1
    static let featureAvcc = "h264-avcc"
    static let maxFrameBytes = 16 * 1024 * 1024

    static let errorProtocolFatal = 4100
    static let errorGrantUnavailable = 4102
    static let errorGrantNotBound = 4103
    static let errorGrantRevoked = 4104
    static let errorGrantExpired = 4105
    static let errorSurfaceGone = 4106
    static let alreadyStreamingBody = "already streaming\n"

    struct MediaHeader: Equatable {
        var keyframe: Bool
        var frameId: UInt32
        var capturedAtMs: UInt64
        var width: UInt16
        var height: UInt16
        var payloadBytes: UInt32
    }

    static func companionFrame(type: UInt8, payload: Data) -> Data {
        var data = Data()
        var length = UInt32(1 + payload.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(type)
        data.append(payload)
        return data
    }

    static func jsonFrame(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return nil
        }
        return companionFrame(type: jsonType, payload: payload)
    }

    /// Test helper. Production frames are filled in one allocation by the encoder.
    static func mediaCompanionFrame(header: MediaHeader, avcc: Data) -> Data {
        var payload = Data(count: mediaHeaderBytes)
        writeMediaHeader(header, payloadBytes: UInt32(avcc.count), into: &payload, at: 0)
        payload.append(avcc)
        return companionFrame(type: mediaType, payload: payload)
    }

    static func writeMediaHeader(
        _ header: MediaHeader,
        payloadBytes: UInt32,
        to base: UnsafeMutableRawPointer
    ) {
        base.storeBytes(of: version, toByteOffset: 0, as: UInt8.self)
        base.storeBytes(of: header.keyframe ? flagKeyframe : 0, toByteOffset: 1, as: UInt8.self)
        base.storeBytes(of: UInt8(mediaHeaderBytes), toByteOffset: 2, as: UInt8.self)
        base.storeBytes(of: UInt8(0), toByteOffset: 3, as: UInt8.self)
        writeUInt32BE(header.frameId, to: base, at: 4)
        writeUInt64BE(header.capturedAtMs, to: base, at: 8)
        writeUInt16BE(header.width, to: base, at: 16)
        writeUInt16BE(header.height, to: base, at: 18)
        writeUInt32BE(payloadBytes, to: base, at: 20)
    }

    static func writeMediaHeader(
        _ header: MediaHeader,
        payloadBytes: UInt32,
        into data: inout Data,
        at offset: Int
    ) {
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            writeMediaHeader(header, payloadBytes: payloadBytes, to: base.advanced(by: offset))
        }
    }

    static func parseJSON(_ payload: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let record = object as? [String: Any]
        else {
            return nil
        }
        return record
    }
}

final class DesktopViewCompanionReader {
    private var buffer = Data()

    func push(_ chunk: Data) throws -> [(type: UInt8, payload: Data)] {
        buffer.append(chunk)
        var frames: [(type: UInt8, payload: Data)] = []
        while buffer.count >= 5 {
            let length = readUInt32BE(buffer, at: 0)
            guard length >= 1, length <= DesktopViewStreamWire.maxFrameBytes else {
                throw DesktopViewStreamWireError.invalidLength
            }
            if buffer.count < 4 + Int(length) { break }
            let type = buffer[4]
            let payload = buffer.subdata(in: 5..<(4 + Int(length)))
            frames.append((type, payload))
            buffer.removeSubrange(0..<(4 + Int(length)))
        }
        return frames
    }
}

enum DesktopViewStreamWireError: Error {
    case invalidLength
}

func writeUInt16BE(_ value: UInt16, to base: UnsafeMutableRawPointer, at offset: Int) {
    var be = value.bigEndian
    memcpy(base.advanced(by: offset), &be, 2)
}

func writeUInt32BE(_ value: UInt32, to base: UnsafeMutableRawPointer, at offset: Int) {
    var be = value.bigEndian
    memcpy(base.advanced(by: offset), &be, 4)
}

func writeUInt64BE(_ value: UInt64, to base: UnsafeMutableRawPointer, at offset: Int) {
    writeUInt32BE(UInt32(value >> 32), to: base, at: offset)
    writeUInt32BE(UInt32(value & 0xFFFF_FFFF), to: base, at: offset + 4)
}

func writeUInt16BE(_ value: UInt16, into data: inout Data, at offset: Int) {
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        writeUInt16BE(value, to: base, at: offset)
    }
}

func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        writeUInt32BE(value, to: base, at: offset)
    }
}

func writeUInt64BE(_ value: UInt64, into data: inout Data, at offset: Int) {
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        writeUInt64BE(value, to: base, at: offset)
    }
}

func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}
