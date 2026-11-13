import Foundation

/// Byte searches over a string's UTF-8 storage for the Markdown pre-passes,
/// which scan whole documents before cmark runs. Foundation's `contains` and
/// `range(of:)` walk Characters, and a generic loop over `String.UTF8View`
/// manages a few hundred MB/s; on a long transcript either costs more than
/// the cmark parse itself. `memmem` and a loop over the contiguous buffer do not.
enum UTF8Search {
    /// The first `needle` in `source` at or after `start`. An ASCII needle
    /// starts and ends on a Character boundary, so the range indexes `source`.
    static func range(of needle: String, in source: String, from start: String.Index? = nil) -> Range<String.Index>? {
        let utf8 = source.utf8
        let offset = start.map { utf8.distance(from: utf8.startIndex, to: $0) } ?? 0
        let length = needle.utf8.count
        var haystack = source
        var pattern = needle
        let found: Int? = haystack.withUTF8 { text in
            pattern.withUTF8 { bytes in
                guard let base = text.baseAddress, let first = bytes.baseAddress, length > 0, offset <= text.count,
                      let hit = memmem(base + offset, text.count - offset, first, length) else { return nil }
                return UnsafeRawPointer(base).distance(to: hit)
            }
        }
        return found.map { utf8.index(utf8.startIndex, offsetBy: $0) ..< utf8.index(utf8.startIndex, offsetBy: $0 + length) }
    }

    /// Calls `body` with the string's UTF-8 bytes, without copying a native string.
    static func withBytes<Result>(of source: String, _ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        var source = source
        return source.withUTF8(body)
    }
}
