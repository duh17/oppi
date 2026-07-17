import Foundation

enum IrohFrameCodecError: LocalizedError, Equatable {
    case invalidHeader
    case invalidBodyLength
    case bodyLengthMismatch(expected: Int, actual: Int)
    case truncatedHeaderLength
    case headerTooLarge(limit: Int)
    case truncatedHeader
    case malformedJSON
    case bodyTooLarge(limit: Int)
    case truncatedBody
    case trailingBytes

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Iroh frame header must be a JSON object"
        case .invalidBodyLength:
            return "Iroh frame bodyLength must be a non-negative safe integer"
        case .bodyLengthMismatch:
            return "Iroh frame bodyLength does not match body bytes"
        case .truncatedHeaderLength:
            return "Iroh frame has a truncated header length"
        case .headerTooLarge(let limit):
            return "Iroh frame header exceeds \(limit) bytes"
        case .truncatedHeader:
            return "Iroh frame has a truncated JSON header"
        case .malformedJSON:
            return "Iroh frame contains malformed JSON"
        case .bodyTooLarge(let limit):
            return "Iroh frame body exceeds \(limit) bytes"
        case .truncatedBody:
            return "Iroh frame has a truncated body"
        case .trailingBytes:
            return "Iroh frame has trailing bytes after body"
        }
    }
}

struct IrohFrame: Sendable, Equatable {
    var header: [String: JSONValue]
    var body: Data
}

enum IrohFrameCodec {
    private static let defaultMaxHeaderBytes = 64 * 1024
    private static let maxSafeInteger = 9_007_199_254_740_991.0

    static func encode(header: [String: JSONValue], body: Data = Data()) throws -> Data {
        var headerWithLength = header
        if !body.isEmpty, headerWithLength["bodyLength"] == nil {
            headerWithLength["bodyLength"] = .number(Double(body.count))
        }

        if let bodyLength = headerWithLength["bodyLength"] {
            let decodedLength = try validBodyLength(bodyLength)
            guard decodedLength == body.count else {
                throw IrohFrameCodecError.bodyLengthMismatch(expected: decodedLength, actual: body.count)
            }
        }

        let headerBytes = try JSONEncoder().encode(headerWithLength)
        guard headerBytes.count <= UInt32.max else {
            throw IrohFrameCodecError.headerTooLarge(limit: Int(UInt32.max))
        }

        var length = UInt32(headerBytes.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(headerBytes)
        frame.append(body)
        return frame
    }

    static func decode(
        _ bytes: Data,
        maxHeaderBytes: Int = defaultMaxHeaderBytes,
        maxBodyBytes: Int? = nil
    ) throws -> IrohFrame {
        guard bytes.count >= 4 else {
            throw IrohFrameCodecError.truncatedHeaderLength
        }

        let headerLength = bytes.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let headerCount = Int(headerLength)
        guard headerCount <= maxHeaderBytes else {
            throw IrohFrameCodecError.headerTooLarge(limit: maxHeaderBytes)
        }

        let headerEnd = 4 + headerCount
        guard bytes.count >= headerEnd else {
            throw IrohFrameCodecError.truncatedHeader
        }

        let headerData = bytes[4..<headerEnd]
        let header: [String: JSONValue]
        do {
            let decoded = try JSONDecoder().decode(JSONValue.self, from: headerData)
            guard case .object(let object) = decoded else {
                throw IrohFrameCodecError.invalidHeader
            }
            header = object
        } catch let error as IrohFrameCodecError {
            throw error
        } catch {
            throw IrohFrameCodecError.malformedJSON
        }

        let bodyLength = try validBodyLength(header["bodyLength"] ?? .number(0))
        if let maxBodyBytes, bodyLength > maxBodyBytes {
            throw IrohFrameCodecError.bodyTooLarge(limit: maxBodyBytes)
        }

        let bodyEnd = headerEnd + bodyLength
        guard bytes.count >= bodyEnd else {
            throw IrohFrameCodecError.truncatedBody
        }
        guard bytes.count == bodyEnd else {
            throw IrohFrameCodecError.trailingBytes
        }

        return IrohFrame(
            header: header,
            body: Data(bytes[headerEnd..<bodyEnd])
        )
    }

    static func redact(header: [String: JSONValue]) -> [String: JSONValue] {
        var redacted = header
        if redacted["authorization"] != nil {
            redacted["authorization"] = .string("[redacted]")
        }

        if case .object(let headers) = redacted["headers"] {
            var redactedHeaders = headers
            for key in redactedHeaders.keys where key.lowercased() == "authorization" {
                redactedHeaders[key] = .string("[redacted]")
            }
            redacted["headers"] = .object(redactedHeaders)
        }
        return redacted
    }

    private static func validBodyLength(_ value: JSONValue) throws -> Int {
        guard case .number(let number) = value,
              number.isFinite,
              number >= 0,
              number <= maxSafeInteger,
              number.rounded(.towardZero) == number else {
            throw IrohFrameCodecError.invalidBodyLength
        }
        return Int(number)
    }
}
