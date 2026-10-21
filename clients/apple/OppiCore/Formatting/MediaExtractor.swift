import Foundation

/// Extract base64 image data from tool output text.
///
/// Detects `data:image/<type>;base64,<data>` data URIs.
struct ImageExtractor {
    struct ExtractedImage: Identifiable, Sendable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedImage] {
        DataURIScanner.matches(in: text, kind: "image").map {
            ExtractedImage(base64: $0.payload, mimeType: $0.mimeType, range: $0.range)
        }
    }
}

/// Extract base64 audio data from tool output text.
///
/// Detects `data:audio/<type>;base64,<data>` data URIs.
struct AudioExtractor {
    struct ExtractedAudio: Identifiable, Sendable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedAudio] {
        DataURIScanner.matches(in: text, kind: "audio").map {
            ExtractedAudio(base64: $0.payload, mimeType: $0.mimeType, range: $0.range)
        }
    }
}

/// Finds `data:<kind>/<subtype>;base64,<payload>` URIs in one linear UTF-8 pass.
///
/// User messages and tool output carry screenshots inline, often several
/// megabytes each, and the timeline reducer extracts them on the main actor.
/// A Swift Regex with a per-character alternation and lookahead took ~300 ms
/// and peaked above 1 GB on one 4.4 MB message, so reopening a chat with two
/// screenshots froze the app for seconds.
///
/// Grammar: subtype is `[A-Za-z0-9+.-]+`; the payload is base64 characters or
/// CR/LF, and a CR/LF directly followed by `data:` ends the URI so
/// newline-joined URIs stay separate. CR/LF are dropped from the payload.
enum DataURIScanner {
    struct Match {
        let mimeType: String
        let payload: String
        let range: Range<String.Index>
    }

    static func matches(in text: String, kind: String) -> [Match] {
        let prefix = Array("data:\(kind)/".utf8)
        let utf8 = text.utf8
        let spans = utf8.withContiguousStorageIfAvailable { scan($0, prefix: prefix) }
            ?? Array(utf8).withUnsafeBufferPointer { scan($0, prefix: prefix) }
        // Every boundary is an ASCII byte, so the offsets are valid String indices.
        // Offsetting a native UTF-8 string's index is O(1).
        return spans.map { span in
            let start = utf8.index(utf8.startIndex, offsetBy: span.start)
            let end = utf8.index(start, offsetBy: span.end - span.start)
            return Match(
                mimeType: kind + "/" + span.subtype,
                payload: span.payload,
                range: start..<end
            )
        }
    }

    private struct Span {
        let start: Int
        let end: Int
        let subtype: String
        let payload: String
    }

    private static let base64Marker = Array(";base64,".utf8)
    private static let uriStart = Array("data:".utf8)

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>, prefix: [UInt8]) -> [Span] {
        var spans: [Span] = []
        var index = 0
        while index + prefix.count <= bytes.count {
            guard bytes[index] == prefix[0], hasBytes(prefix, in: bytes, at: index) else {
                index += 1
                continue
            }
            let subtypeStart = index + prefix.count
            var cursor = subtypeStart
            while cursor < bytes.count, isSubtypeByte(bytes[cursor]) { cursor += 1 }
            guard cursor > subtypeStart, hasBytes(base64Marker, in: bytes, at: cursor) else {
                index += 1
                continue
            }
            let subtypeEnd = cursor
            let payloadStart = cursor + base64Marker.count
            cursor = payloadStart
            var hasLineBreak = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if isBase64Byte(byte) {
                    cursor += 1
                } else if byte == 0x0A || byte == 0x0D, !hasBytes(uriStart, in: bytes, at: cursor + 1) {
                    hasLineBreak = true
                    cursor += 1
                } else {
                    break
                }
            }
            guard cursor > payloadStart else {
                index += 1
                continue
            }
            let payloadBytes = UnsafeBufferPointer(rebasing: bytes[payloadStart..<cursor])
            let payload = hasLineBreak
                ? String(decoding: payloadBytes.filter { $0 != 0x0A && $0 != 0x0D }, as: UTF8.self)
                : String(decoding: payloadBytes, as: UTF8.self)
            spans.append(Span(
                start: index,
                end: cursor,
                subtype: String(decoding: UnsafeBufferPointer(rebasing: bytes[subtypeStart..<subtypeEnd]), as: UTF8.self),
                payload: payload
            ))
            index = cursor
        }
        return spans
    }

    private static func hasBytes(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool {
        guard offset + needle.count <= bytes.count else { return false }
        for (position, byte) in needle.enumerated() where bytes[offset + position] != byte {
            return false
        }
        return true
    }

    /// `[A-Za-z0-9+.-]`
    private static func isSubtypeByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == 0x2B || byte == 0x2E || byte == 0x2D
    }

    /// `[A-Za-z0-9+/=]`
    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == 0x2B || byte == 0x2F || byte == 0x3D
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }
}
