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
        into data: inout Data,
        at offset: Int
    ) {
        data[offset] = version
        data[offset + 1] = header.keyframe ? flagKeyframe : 0
        data[offset + 2] = UInt8(mediaHeaderBytes)
        data[offset + 3] = 0
        writeUInt32BE(header.frameId, into: &data, at: offset + 4)
        writeUInt64BE(header.capturedAtMs, into: &data, at: offset + 8)
        writeUInt16BE(header.width, into: &data, at: offset + 16)
        writeUInt16BE(header.height, into: &data, at: offset + 18)
        writeUInt32BE(payloadBytes, into: &data, at: offset + 20)
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

func writeUInt16BE(_ value: UInt16, into data: inout Data, at offset: Int) {
    data[offset] = UInt8(value >> 8)
    data[offset + 1] = UInt8(value & 0xFF)
}

func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
    data[offset] = UInt8(value >> 24)
    data[offset + 1] = UInt8((value >> 16) & 0xFF)
    data[offset + 2] = UInt8((value >> 8) & 0xFF)
    data[offset + 3] = UInt8(value & 0xFF)
}

func writeUInt64BE(_ value: UInt64, into data: inout Data, at offset: Int) {
    writeUInt32BE(UInt32(value >> 32), into: &data, at: offset)
    writeUInt32BE(UInt32(value & 0xFFFF_FFFF), into: &data, at: offset + 4)
}

func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}
