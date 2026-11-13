import Foundation

// The wiki-link pre-pass: what `parseCommonMark` hides from cmark before it
// parses, and puts back after.
extension MarkdownWikiLinkRewriter {
    /// The wiki-link bodies to hide from cmark. The parser feeds the source in
    /// pieces with each hidden body's frame in its place, so the document is
    /// never copied, and nothing is hidden in most documents.
    struct ParserInput {
        /// Each hidden body's byte range in the source, in order.
        let hiddenRanges: [Range<Int>]
        /// Nil when nothing is hidden.
        let restoration: Restoration?
    }

    /// Puts back the wiki-link bodies `parserInput` hid from cmark.
    struct Restoration {
        /// Frames each hidden body's index: `q0q12q0q` is body 12.
        fileprivate let token: String
        fileprivate let bodies: [Substring]
        /// The 1-based source line of each hidden body, ascending.
        fileprivate let lines: [Int]

        /// What cmark reads in place of hidden body `index`.
        func frame(_ index: Int) -> String {
            token + String(index) + token
        }

        /// Whether a hidden body sits on one of `lines`: blocks outside them
        /// hold no frame and skip restoring.
        func hidesText(onLines lines: ClosedRange<Int>) -> Bool {
            var low = 0
            var high = self.lines.count
            while low < high {
                let middle = (low + high) / 2
                if self.lines[middle] < lines.lowerBound { low = middle + 1 } else { high = middle }
            }
            return low < self.lines.count && self.lines[low] <= lines.upperBound
        }

        /// `unescapingPipes`: the literal is a table cell's, where GFM reads
        /// `\|` as `|`; a hidden body gets the same reading.
        func restore(_ literal: String, unescapingPipes: Bool = false) -> String {
            guard UTF8Search.range(of: token, in: literal) != nil else { return literal }
            let frame = Array(token.utf8)
            return UTF8Search.withBytes(of: literal) { bytes in
                var result = ""
                result.reserveCapacity(bytes.count)
                var copied = 0
                var index = 0
                while index + frame.count <= bytes.count {
                    guard Self.matches(frame, in: bytes, at: index) else {
                        index += 1
                        continue
                    }
                    var cursor = index + frame.count
                    var body = 0
                    while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39, body < bodies.count {
                        body = body * 10 + Int(bytes[cursor] - 0x30)
                        cursor += 1
                    }
                    guard cursor > index + frame.count, body < bodies.count,
                          Self.matches(frame, in: bytes, at: cursor) else {
                        index += 1
                        continue
                    }
                    result += String(decoding: UnsafeBufferPointer(rebasing: bytes[copied ..< index]), as: UTF8.self)
                    result += unescapingPipes ? bodies[body].replacingOccurrences(of: #"\|"#, with: "|") : String(bodies[body])
                    index = cursor + frame.count
                    copied = index
                }
                result += String(decoding: UnsafeBufferPointer(rebasing: bytes[copied...]), as: UTF8.self)
                return result
            }
        }

        private static func matches(_ frame: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
            guard index + frame.count <= bytes.count else { return false }
            for offset in frame.indices where bytes[index + offset] != frame[offset] { return false }
            return true
        }
    }

    private static let parserBoundaryTokens = [
        "q0q", "q1q", "q2q", "q3q", "q4q", "q5q", "q6q", "q7q",
    ]
    private static let maximumTokenSelectionAttempts = 8
    private static let parserBoundaryTokenByteCount = 3

    /// The first of at most eight candidates that is a three-byte alphanumeric
    /// token absent from `source`. Returning nil is the fail-closed result when
    /// the bounded set is exhausted. One `memchr` pass per distinct first byte
    /// (all of the production tokens start with `q`, rare in prose) instead of
    /// a full search per candidate.
    static func selectParserBoundaryToken(
        absentFrom source: String,
        candidates: [String]
    ) -> String? {
        let tokens = candidates.prefix(maximumTokenSelectionAttempts).map { Array($0.utf8) }
        var unusable = tokens.map { $0.count != parserBoundaryTokenByteCount || !$0.allSatisfy(isASCIILetterOrDigit) }
        UTF8Search.withBytes(of: source) { bytes in
            guard let base = bytes.baseAddress else { return }
            for lead in Set(tokens.indices.filter { !unusable[$0] }.map { tokens[$0][0] }) {
                var index = 0
                while index + parserBoundaryTokenByteCount <= bytes.count,
                      let hit = memchr(base + index, Int32(lead), bytes.count - index) {
                    let at = UnsafeRawPointer(base).distance(to: hit)
                    guard at + parserBoundaryTokenByteCount <= bytes.count else { break }
                    for token in tokens.indices where !unusable[token] && tokens[token][0] == lead
                        && tokens[token][1] == bytes[at + 1] && tokens[token][2] == bytes[at + 2] {
                        unusable[token] = true
                    }
                    index = at + 1
                }
            }
        }
        return unusable.firstIndex(of: false).map { String(decoding: tokens[$0], as: UTF8.self) }
    }

    /// Hides the body of each wiki link from cmark, so the link stays one
    /// piece of text: the GFM table splitter does not cut it at its `|`,
    /// emphasis does not form inside it (`[[*draft*]]`), and a `[foo]: url`
    /// definition does not turn `[[foo]]` into `[` + link + `]`. comrak and
    /// Obsidian parse `[[…]]` as one node; cmark gives an extension no turn
    /// before it handles `[` itself, so this is done before cmark runs. The
    /// body becomes an alphanumeric token (`[[q0q3q0q]]`), and the
    /// restoration puts it back during AST conversion in every literal of a
    /// block that holds one, including code, HTML and math, where wiki syntax
    /// stays literal.
    ///
    /// This deliberately knows nothing about CommonMark containers. A body is
    /// hidden only when it is a supported target with an optional non-empty
    /// label after one unescaped `|`, closes on its own line, and holds no
    /// nested `[[`, escaped `]` or backtick (a backtick could pair with one
    /// outside the link as a code span). Anything else is left as written,
    /// and so is a body cmark would leave alone anyway: one without a byte it
    /// acts on (`*`, `_`, `|`, a bracket, …) in a document that defines no
    /// link reference. The first `]]` closes the link, as in Obsidian. Token selection is
    /// capped at eight checks; exhaustion hides nothing.
    ///
    /// Why before cmark, not a repair of its tree: the GFM table splitter cuts
    /// a row at an unescaped `|` and drops the cells past the header's count
    /// before any inline parsing (`[[docs/a.md|Alpha]]` in a cell, m27), so
    /// the tree no longer holds the link. Emphasis or a reference link formed
    /// inside the brackets (m26, m30) would need the written delimiters back
    /// from source positions; one mechanism covers all three instead.
    static func parserInput(_ source: String) -> ParserInput {
        let nothing = ParserInput(hiddenRanges: [], restoration: nil)
        guard UTF8Search.range(of: "[[", in: source) != nil else { return nothing }
        // Each found when first needed: a document whose links all hold a
        // byte cmark acts on never searches for `]:`.
        var definesReferences: Bool?
        var token: String?
        // Documents repeat targets; classifying one costs microseconds.
        var supportedTargets: [String: Bool] = [:]
        return UTF8Search.withBytes(of: source) { bytes in
            guard let base = bytes.baseAddress else { return nothing }
            var ranges: [Range<Int>] = []
            var bodies: [Substring] = []
            var lines: [Int] = []
            var line = 1
            var counted = 0
            var cursor = 0
            while let open = nextDoubleBracket(UInt8(ascii: "["), in: bytes, from: cursor) {
                guard let candidate = parserBoundaryCandidate(in: bytes, opening: open) else { break }
                cursor = candidate.end
                guard candidate.canProtect else { continue }
                let bodyStart = open + 2
                let bodyEnd = candidate.end - 2
                if !bytes[bodyStart ..< bodyEnd].contains(where: isInlineSyntaxByte) {
                    if definesReferences == nil { definesReferences = UTF8Search.range(of: "]:", in: source) != nil }
                    guard definesReferences == true else { continue }
                }
                let targetEnd = candidate.firstPipe ?? bodyEnd
                let target = String(decoding: UnsafeBufferPointer(rebasing: bytes[bodyStart ..< targetEnd]), as: UTF8.self)
                let isSupported = supportedTargets[target] ?? isPotentiallySupportedWikiTarget(target)
                supportedTargets[target] = isSupported
                guard isSupported else { continue }
                if token == nil {
                    token = selectParserBoundaryToken(absentFrom: source, candidates: parserBoundaryTokens)
                    guard token != nil else { return nothing }
                }
                while counted < bodyStart, let newline = memchr(base + counted, 0x0A, bodyStart - counted) {
                    line += 1
                    counted = UnsafeRawPointer(base).distance(to: newline) + 1
                }
                counted = bodyStart
                ranges.append(bodyStart ..< bodyEnd)
                bodies.append(Substring(String(decoding: UnsafeBufferPointer(rebasing: bytes[bodyStart ..< bodyEnd]), as: UTF8.self)))
                lines.append(line)
            }
            guard let token, !ranges.isEmpty else { return nothing }
            return ParserInput(hiddenRanges: ranges, restoration: Restoration(token: token, bodies: bodies, lines: lines))
        }
    }

    private struct ParserBoundaryCandidate {
        /// Just past the closing `]]`.
        let end: Int
        /// The first `|`, escaped or not: the target ends there (`\|` is how a
        /// table cell writes the separator).
        let firstPipe: Int?
        let canProtect: Bool
    }

    /// The byte offset of the next `xx` pair (`[[` or `]]`) at or after `start`.
    private static func nextDoubleBracket(_ byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        var index = start
        while index + 1 < bytes.count,
              let hit = memchr(base + index, Int32(byte), bytes.count - 1 - index) {
            index = UnsafeRawPointer(base).distance(to: hit)
            if bytes[index + 1] == byte { return index }
            index += 1
        }
        return nil
    }

    /// The candidate opened by the `[[` at `opening`, closed by the first
    /// `]]` after it, or nil when none follows (no later `[[` can close then).
    private static func parserBoundaryCandidate(
        in bytes: UnsafeBufferPointer<UInt8>,
        opening: Int
    ) -> ParserBoundaryCandidate? {
        let pipe = UInt8(ascii: "|")
        let backslash = UInt8(ascii: "\\")
        let open = UInt8(ascii: "[")
        let close = UInt8(ascii: "]")
        var cursor = opening + 2
        var precedingBackslashes = 0
        var separator: Int?
        var firstPipe: Int?
        var canProtect = true

        while cursor < bytes.count {
            let byte = bytes[cursor]
            let next: UInt8 = cursor + 1 < bytes.count ? bytes[cursor + 1] : 0
            let escaped = precedingBackslashes % 2 == 1

            if byte == open, next == open {
                canProtect = false
            } else if byte == close, escaped {
                canProtect = false
            } else if byte == close, next == close {
                let labelStart = separator.map { $0 + 1 }
                let labelIsBlank = labelStart.map { start in
                    bytes[start ..< cursor].allSatisfy { $0 == 0x20 || $0 == 0x09 }
                } ?? false
                return ParserBoundaryCandidate(
                    end: cursor + 2,
                    firstPipe: firstPipe,
                    canProtect: canProtect && cursor > opening + 2 && !labelIsBlank
                )
            } else if byte == pipe, !escaped {
                if separator == nil {
                    separator = cursor
                } else {
                    canProtect = false
                }
            } else if byte == 0x0A || byte == 0x0D || byte == UInt8(ascii: "`") {
                canProtect = false
            }
            if byte == pipe { firstPipe = firstPipe ?? cursor }

            precedingBackslashes = byte == backslash ? precedingBackslashes + 1 : 0
            cursor += 1
        }

        return nil
    }

    /// A byte cmark's inline parser or the GFM table splitter can act on.
    private static func isInlineSyntaxByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "|"), UInt8(ascii: "["),
             UInt8(ascii: "]"), UInt8(ascii: "\\"), UInt8(ascii: "<"), UInt8(ascii: "&"), UInt8(ascii: "$"),
             UInt8(ascii: "!"):
            true
        default:
            false
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}
