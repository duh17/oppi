import Foundation

// MARK: - Syntax Tokens

// MARK: - Token Type (for range-based highlighting)

/// Token categories for range-based attribute application.
enum SyntaxTokenKind: UInt8, Sendable, Equatable {
    case variable = 0  // default — no attribute override needed
    case comment = 1
    case keyword = 2
    case string = 3
    case number = 4
    case type = 5
    case punctuation = 6
    case function = 7
    case `operator` = 8
}

/// A token range recorded during scanning.
///
/// Offsets are UTF-16 code units, matching `NSRange`, `NSString`,
/// `NSAttributedString`, and tree-sitter capture ranges.
struct SyntaxTokenRange: Sendable, Equatable {
    let location: Int
    let length: Int
    let kind: SyntaxTokenKind
}


// MARK: - SyntaxTokenScanner

/// Platform-neutral syntax token scanner shared by iOS and Mac renderers.
///
/// This scanner produces UTF-16 token ranges only. Platform targets decide how
/// those ranges map to `UIColor`, `NSColor`, fonts, attributed strings, or SwiftUI
/// views.
enum SyntaxTokenScanner {
    /// Maximum lines of token work. Painters keep complete source; the tail stays
    /// the explicit base color.
    static let maxLines = 10_000

    /// Scan source code with the deterministic fallback scanner.
    ///
    /// Returned ranges use UTF-16 code unit offsets so platform renderers can
    /// apply them directly to `NSAttributedString` ranges.
    static func scanTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [SyntaxTokenRange] {
        scanFallbackTokenRanges(truncatedCode(code), language: language)
    }

    /// ASCII-optimized scanner using raw UTF-8 bytes.
    ///
    /// Input with non-ASCII bytes falls back to the character scanner so the
    /// returned offsets remain UTF-16 correct.
    static func scanTokenRangesUTF8(
        _ text: String,
        language: SyntaxLanguage
    ) -> [SyntaxTokenRange] {
        guard language != .unknown else { return [] }
        let text = truncatedCode(text)

        if language == .json || language == .xml || language == .diff {
            return scanFallbackTokenRanges(text, language: language)
        }

        let utf8 = Array(text.utf8)
        for byte in utf8 where byte >= 0x80 {
            return scanFallbackTokenRanges(text, language: language)
        }

        return scanTokenRangesFromUTF8(utf8, language: language)
    }

/// Run the hand-written fallback scanner and return public UTF-16 ranges.
private static func scanFallbackTokenRanges(
    _ text: String,
    language: SyntaxLanguage
) -> [SyntaxTokenRange] {
    let allChars = Array(text)
    let characterRanges = scanTokenRangesByCharacter(allChars, language: language)
    guard !characterRanges.isEmpty, text.utf16.count != allChars.count else {
        return characterRanges
    }
    return convertCharacterRangesToUTF16(characterRanges, in: text, characterCount: allChars.count)
}

/// Convert private fallback scanner ranges from `Array<Character>` offsets
/// into public UTF-16 offsets. This is only needed for grapheme clusters
/// that occupy multiple UTF-16 code units, such as emoji or combining marks.
private static func convertCharacterRangesToUTF16(
    _ ranges: [SyntaxTokenRange],
    in text: String,
    characterCount: Int
) -> [SyntaxTokenRange] {
    var utf16Offsets: [Int] = []
    utf16Offsets.reserveCapacity(characterCount + 1)
    var offset = 0
    utf16Offsets.append(offset)
    for character in text {
        offset += character.utf16.count
        utf16Offsets.append(offset)
    }

    return ranges.compactMap { range in
        let end = range.location + range.length
        guard range.location >= 0, end <= characterCount else { return nil }
        return SyntaxTokenRange(
            location: utf16Offsets[range.location],
            length: utf16Offsets[end] - utf16Offsets[range.location],
            kind: range.kind
        )
    }
}

/// Private scanner shared by fallback paths.
/// Scans line-by-line using newline detection (no per-line `Array(line)` allocation).
/// Returned ranges are `Array<Character>` offsets; callers must convert them
/// before applying attributes to `NSAttributedString`.
private static func scanTokenRangesByCharacter(
    _ allChars: [Character],
    language: SyntaxLanguage
) -> [SyntaxTokenRange] {
    var tokenRanges: [SyntaxTokenRange] = []
    tokenRanges.reserveCapacity(allChars.count / 4)

    if language == .json {
        scanJSONRanges(allChars, ranges: &tokenRanges)
        return tokenRanges
    }

    if language == .xml {
        scanXMLRanges(allChars, ranges: &tokenRanges)
        return tokenRanges
    }

    if language == .diff {
        scanDiffRanges(allChars, ranges: &tokenRanges)
        return tokenRanges
    }

    let keywords = language.keywords
    let commentPrefix = language.lineCommentPrefix

    var inBlockComment = false
    var pos = 0

    while pos <= allChars.count {
        var lineEnd = pos
        while lineEnd < allChars.count, allChars[lineEnd] != "\n" {
            lineEnd += 1
        }

        if lineEnd > pos {
            scanLineRangesSlice(
                allChars, start: pos, end: lineEnd,
                language: language,
                keywords: keywords,
                commentPrefix: commentPrefix,
                inBlockComment: &inBlockComment,
                ranges: &tokenRanges
            )
        }

        pos = lineEnd + 1
    }

    return tokenRanges
}

// MARK: - UTF-8 Byte Scanner (ASCII fast path)

/// Top-level UTF-8 scanner. Input must be verified all-ASCII by the caller.
private static func scanTokenRangesFromUTF8(
    _ bytes: [UInt8],
    language: SyntaxLanguage
) -> [SyntaxTokenRange] {
    var tokenRanges: [SyntaxTokenRange] = []
    tokenRanges.reserveCapacity(bytes.count / 4)

    let keywords = language.keywords
    let commentPrefix: [UInt8]? = language.lineCommentPrefix.map { $0.compactMap(\.asciiValue) }

    var inBlockComment = false
    var pos = 0
    let count = bytes.count

    while pos <= count {
        var lineEnd = pos
        while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }

        if lineEnd > pos {
            scanLineRangesUTF8Slice(
                bytes, start: pos, end: lineEnd,
                language: language,
                keywords: keywords,
                commentPrefix: commentPrefix,
                inBlockComment: &inBlockComment,
                ranges: &tokenRanges
            )
        }

        pos = lineEnd + 1
    }

    return tokenRanges
}

// MARK: Intentionally parallel to scanLineRangesSlice for ASCII fast-path performance — do not merge.

/// Scan a single line within bytes[start..<end] for token ranges.
/// All offsets are byte positions (== UTF-16 offsets for ASCII input).
private static func scanLineRangesUTF8Slice(
    _ bytes: [UInt8],
    start: Int,
    end: Int,
    language: SyntaxLanguage,
    keywords: Set<String>,
    commentPrefix: [UInt8]?,
    inBlockComment: inout Bool,
    ranges: inout [SyntaxTokenRange]
) {
    var i = start

    while i < end {
        let b = bytes[i]

        // Inside block comment — scan for */
        if inBlockComment {
            let commentStart = i
            while i < end {
                if i + 1 < end, bytes[i] == 0x2A, bytes[i + 1] == 0x2F { // */
                    i += 2
                    inBlockComment = false
                    break
                }
                i += 1
            }
            if i > commentStart {
                ranges.append(SyntaxTokenRange(location: commentStart, length: i - commentStart, kind: .comment))
            }
            continue
        }

        // Block comment open: /*
        if language.hasBlockComments,
           i + 1 < end, b == 0x2F, bytes[i + 1] == 0x2A {
            inBlockComment = true
            let commentStart = i
            i += 2
            while i < end {
                if i + 1 < end, bytes[i] == 0x2A, bytes[i + 1] == 0x2F {
                    i += 2
                    inBlockComment = false
                    break
                }
                i += 1
            }
            ranges.append(SyntaxTokenRange(location: commentStart, length: i - commentStart, kind: .comment))
            continue
        }

        // Line comment
        if let prefix = commentPrefix, matchesBytesAt(bytes, offset: i, end: end, pattern: prefix) {
            ranges.append(SyntaxTokenRange(location: i, length: end - i, kind: .comment))
            return
        }

        // Preprocessor for C/C++
        if b == 0x23, language == .c || language == .cpp { // #
            ranges.append(SyntaxTokenRange(location: i, length: end - i, kind: .keyword))
            return
        }

        // Decorator @
        if b == 0x40 {
            let tokenStart = i
            i += 1
            while i < end, isIdentByteASCII(bytes[i]) { i += 1 }
            ranges.append(SyntaxTokenRange(location: tokenStart, length: i - tokenStart, kind: .type))
            continue
        }

        // String literal: " ' `
        if b == 0x22 || b == 0x27 || b == 0x60 {
            let tokenEnd = scanStringEndUTF8(bytes, from: i, end: end, quote: b)
            ranges.append(SyntaxTokenRange(location: i, length: tokenEnd - i, kind: .string))
            i = tokenEnd
            continue
        }

        // Number: 0-9
        if b >= 0x30, b <= 0x39 {
            let tokenEnd = scanNumberEndUTF8(bytes, from: i, end: end)
            ranges.append(SyntaxTokenRange(location: i, length: tokenEnd - i, kind: .number))
            i = tokenEnd
            continue
        }

        // Identifier / keyword
        if isIdentStartByteASCII(b) {
            var wordEnd = i + 1
            while wordEnd < end, isIdentByteASCII(bytes[wordEnd]) { wordEnd += 1 }
            let wordLen = wordEnd - i

            if wordLen >= 2, wordLen <= 12 {
                let word = String(decoding: bytes[i..<wordEnd], as: UTF8.self)
                if keywords.contains(word) {
                    ranges.append(SyntaxTokenRange(location: i, length: wordLen, kind: .keyword))
                    i = wordEnd
                    continue
                }
            }

            // Type-like: starts uppercase, has lowercase
            if wordLen >= 2, b >= 0x41, b <= 0x5A {
                let hasLower = ((i + 1)..<wordEnd).contains { bytes[$0] >= 0x61 && bytes[$0] <= 0x7A }
                if hasLower {
                    ranges.append(SyntaxTokenRange(location: i, length: wordLen, kind: .type))
                }
            }
            i = wordEnd
            continue
        }

        i += 1
    }
}

// MARK: - UTF-8 Byte Helpers

@inline(__always)
private static func isIdentByteASCII(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= 0x7A) || // a-z
    (b >= 0x41 && b <= 0x5A) || // A-Z
    (b >= 0x30 && b <= 0x39) || // 0-9
    b == 0x5F                    // _
}

@inline(__always)
private static func isIdentStartByteASCII(_ b: UInt8) -> Bool {
    (b >= 0x61 && b <= 0x7A) || // a-z
    (b >= 0x41 && b <= 0x5A) || // A-Z
    b == 0x5F                    // _
}

private static func matchesBytesAt(_ bytes: [UInt8], offset: Int, end: Int, pattern: [UInt8]) -> Bool {
    guard offset + pattern.count <= end else { return false }
    for j in 0..<pattern.count where bytes[offset + j] != pattern[j] {
        return false
    }
    return true
}

private static func scanStringEndUTF8(_ bytes: [UInt8], from start: Int, end: Int, quote: UInt8) -> Int {
    var i = start + 1
    while i < end {
        let b = bytes[i]
        if b == 0x5C { // backslash escape
            i += 2
            continue
        }
        if b == quote {
            return i + 1
        }
        i += 1
    }
    return end
}

private static func scanNumberEndUTF8(_ bytes: [UInt8], from start: Int, end: Int) -> Int {
    var i = start
    // Hex prefix: 0x
    if bytes[i] == 0x30, i + 1 < end, bytes[i + 1] == 0x78 || bytes[i + 1] == 0x58 {
        i += 2
        while i < end {
            let b = bytes[i]
            if (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) ||
               (b >= 0x41 && b <= 0x46) || b == 0x5F {
                i += 1
            } else { break }
        }
        return i
    }
    // Decimal
    var hasDot = false
    while i < end {
        let b = bytes[i]
        if (b >= 0x30 && b <= 0x39) || b == 0x5F { // 0-9 _
            i += 1
        } else if b == 0x2E, !hasDot, i + 1 < end, bytes[i + 1] >= 0x30, bytes[i + 1] <= 0x39 { // .
            hasDot = true
            i += 1
        } else if b == 0x65 || b == 0x45 { // e E
            i += 1
            if i < end, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 } // + -
        } else {
            break
        }
    }
    return i
}

/// First `maxLines` lines. This is the only token-work budget; painters must
/// not truncate displayed source.
static func truncatedCode(_ code: String) -> String {
    let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count <= maxLines {
        return code
    }
    return lines.prefix(maxLines).joined(separator: "\n")
}

// MARK: - Range-based Line Scanner (slice-based)

/// Scan a line within allChars[start..<end] for token ranges.
/// Positions are absolute indices into allChars (= character offsets in the original text).
/// `keywords` and `commentPrefix` are pre-computed by the caller to avoid per-line allocation.
private static func scanLineRangesSlice(
    _ allChars: [Character],
    start: Int,
    end: Int,
    language: SyntaxLanguage,
    keywords: Set<String>,
    commentPrefix: [Character]?,
    inBlockComment: inout Bool,
    ranges: inout [SyntaxTokenRange]
) {
    var i = start

    while i < end {
        if inBlockComment {
            let commentStart = i
            while i < end {
                if i + 1 < end, allChars[i] == "*", allChars[i + 1] == "/" {
                    i += 2
                    inBlockComment = false
                    break
                }
                i += 1
            }
            if i > commentStart {
                ranges.append(SyntaxTokenRange(location: commentStart, length: i - commentStart, kind: .comment))
            }
            continue
        }

        if language.hasBlockComments,
           i + 1 < end, allChars[i] == "/", allChars[i + 1] == "*" {
            inBlockComment = true
            let commentStart = i
            i += 2
            while i < end {
                if i + 1 < end, allChars[i] == "*", allChars[i + 1] == "/" {
                    i += 2
                    inBlockComment = false
                    break
                }
                i += 1
            }
            ranges.append(SyntaxTokenRange(location: commentStart, length: i - commentStart, kind: .comment))
            continue
        }

        if let prefix = commentPrefix, matchesAt(allChars, offset: i, pattern: prefix) {
            ranges.append(SyntaxTokenRange(location: i, length: end - i, kind: .comment))
            return
        }

        if allChars[i] == "#", language == .c || language == .cpp {
            ranges.append(SyntaxTokenRange(location: i, length: end - i, kind: .keyword))
            return
        }

        if allChars[i] == "@" {
            let tokenStart = i
            i += 1
            while i < end, isIdentChar(allChars[i]) {
                i += 1
            }
            ranges.append(SyntaxTokenRange(location: tokenStart, length: i - tokenStart, kind: .type))
            continue
        }

        let ch = allChars[i]
        if ch == "\"" || ch == "'" || ch == "`" {
            let tokenEnd = scanStringEndPos(allChars, from: i, end: end, quote: ch)
            ranges.append(SyntaxTokenRange(location: i, length: tokenEnd - i, kind: .string))
            i = tokenEnd
            continue
        }

        if isDigitASCII(ch) {
            let tokenEnd = scanNumberEnd(allChars, from: i)
            ranges.append(SyntaxTokenRange(location: i, length: tokenEnd - i, kind: .number))
            i = tokenEnd
            continue
        }

        if isIdentStart(ch) {
            // Scan word boundary using fast ASCII checks
            var wordEnd = i + 1
            while wordEnd < end, isIdentChar(allChars[wordEnd]) {
                wordEnd += 1
            }
            let wordLen = wordEnd - i

            // Quick length check: keywords are 2-12 chars. Skip String alloc for longer words.
            if wordLen >= 2, wordLen <= 12, keywords.contains(String(allChars[i..<wordEnd])) {
                ranges.append(SyntaxTokenRange(location: i, length: wordLen, kind: .keyword))
            } else if wordLen >= 2, isUpperASCII(allChars[i]) {
                // Check isTypeLike without String allocation
                let hasLower = ((i + 1)..<wordEnd).contains { isLowerASCII(allChars[$0]) }
                if hasLower {
                    ranges.append(SyntaxTokenRange(location: i, length: wordLen, kind: .type))
                }
            }
            i = wordEnd
            continue
        }

        i += 1
    }
}

// MARK: - Fast ASCII Classification

/// Fast ASCII identifier check. For the 99%+ ASCII case, avoids Unicode
/// property lookups that Character.isLetter/isNumber perform.
@inline(__always)
private static func isIdentChar(_ ch: Character) -> Bool {
    guard let ascii = ch.asciiValue else {
        return ch.isLetter || ch.isNumber
    }
    // a-z, A-Z, 0-9, _
    return (ascii >= 0x61 && ascii <= 0x7A) ||
           (ascii >= 0x41 && ascii <= 0x5A) ||
           (ascii >= 0x30 && ascii <= 0x39) ||
           ascii == 0x5F
}

@inline(__always)
private static func isIdentStart(_ ch: Character) -> Bool {
    guard let ascii = ch.asciiValue else {
        return ch.isLetter
    }
    return (ascii >= 0x61 && ascii <= 0x7A) ||
           (ascii >= 0x41 && ascii <= 0x5A) ||
           ascii == 0x5F
}

@inline(__always)
private static func isUpperASCII(_ ch: Character) -> Bool {
    guard let ascii = ch.asciiValue else { return ch.isUppercase }
    return ascii >= 0x41 && ascii <= 0x5A
}

@inline(__always)
private static func isLowerASCII(_ ch: Character) -> Bool {
    guard let ascii = ch.asciiValue else { return ch.isLowercase }
    return ascii >= 0x61 && ascii <= 0x7A
}

@inline(__always)
private static func isDigitASCII(_ ch: Character) -> Bool {
    guard let ascii = ch.asciiValue else { return ch.isNumber }
    return ascii >= 0x30 && ascii <= 0x39
}

// MARK: - Position-only Scanners (no String allocation)

/// Scan string literal, return end position only (no String allocation).
private static func scanStringEndPos(_ chars: [Character], from start: Int, quote: Character) -> Int {
    scanStringEndPos(chars, from: start, end: chars.count, quote: quote)
}

/// Line-bounded variant: won't scan past `end`.
private static func scanStringEndPos(_ chars: [Character], from start: Int, end: Int, quote: Character) -> Int {
    var i = start + 1
    var escaped = false
    while i < end {
        if escaped {
            escaped = false
        } else if chars[i] == "\\" {
            escaped = true
        } else if chars[i] == quote {
            return i + 1
        }
        i += 1
    }
    return end
}

/// Scan number literal, return end position only (no String allocation).
/// Uses ASCII checks for the hot inner loop.
private static func scanNumberEnd(_ chars: [Character], from start: Int) -> Int {
    var i = start
    if chars[i] == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
        i += 2
        while i < chars.count {
            let c = chars[i]
            if isDigitASCII(c) || (c.asciiValue.map { ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) } ?? c.isHexDigit) || c == "_" {
                i += 1
            } else { break }
        }
        return i
    }
    var hasDot = false
    while i < chars.count {
        let c = chars[i]
        if isDigitASCII(c) || c == "_" {
            i += 1
        } else if c == ".", !hasDot, i + 1 < chars.count, isDigitASCII(chars[i + 1]) {
            hasDot = true
            i += 1
        } else if c == "e" || c == "E" {
            i += 1
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        } else {
            break
        }
    }
    return i
}

private static func matchesAt(_ chars: [Character], offset: Int, pattern: [Character]) -> Bool {
    guard offset + pattern.count <= chars.count else { return false }
    for j in 0..<pattern.count where chars[offset + j] != pattern[j] {
        return false
    }
    return true
}

// MARK: - JSON Highlighting

private static func scanJSONRanges(
    _ chars: [Character],
    ranges: inout [SyntaxTokenRange]
) {
    var i = 0

    while i < chars.count {
        let ch = chars[i]

        if ch == "\"" {
            let end = scanStringEnd(chars, from: i, quote: "\"")
            var lookahead = end
            while lookahead < chars.count, chars[lookahead] == " " || chars[lookahead] == "\t" {
                lookahead += 1
            }
            let kind: SyntaxTokenKind = lookahead < chars.count && chars[lookahead] == ":" ? .type : .string
            ranges.append(SyntaxTokenRange(location: i, length: end - i, kind: kind))
            i = end
            continue
        }

        if ch.isNumber || (ch == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
            let end = scanJSONNumberEnd(chars, from: i)
            ranges.append(SyntaxTokenRange(location: i, length: end - i, kind: .number))
            i = end
            continue
        }

        if let (length, kind) = scanJSONKeyword(chars, from: i) {
            ranges.append(SyntaxTokenRange(location: i, length: length, kind: kind))
            i += length
            continue
        }

        let punctuationStart = i
        i += 1
        while i < chars.count,
              chars[i] != "\"",
              !chars[i].isNumber,
              !(chars[i] == "-" && i + 1 < chars.count && chars[i + 1].isNumber),
              scanJSONKeyword(chars, from: i) == nil {
            i += 1
        }
        ranges.append(SyntaxTokenRange(location: punctuationStart, length: i - punctuationStart, kind: .punctuation))
    }
}

private static func scanStringEnd(_ chars: [Character], from start: Int, quote: Character) -> Int {
    var i = start + 1
    var escaped = false

    while i < chars.count {
        if escaped {
            escaped = false
        } else if chars[i] == "\\" {
            escaped = true
        } else if chars[i] == quote {
            return i + 1
        }
        i += 1
    }
    return chars.count
}

private static func scanJSONNumberEnd(_ chars: [Character], from start: Int) -> Int {
    var i = start
    if chars[i] == "-" { i += 1 }
    while i < chars.count {
        let c = chars[i]
        if c.isNumber || c == "." {
            i += 1
        } else if c == "e" || c == "E" {
            i += 1
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        } else {
            break
        }
    }
    return i
}

private static func scanJSONKeyword(_ chars: [Character], from i: Int) -> (length: Int, kind: SyntaxTokenKind)? {
    if matchesJSONWord(chars, at: i, word: ["t", "r", "u", "e"]) {
        return (4, .keyword)
    }
    if matchesJSONWord(chars, at: i, word: ["f", "a", "l", "s", "e"]) {
        return (5, .keyword)
    }
    if matchesJSONWord(chars, at: i, word: ["n", "u", "l", "l"]) {
        return (4, .comment)
    }
    return nil
}

private static func matchesJSONWord(_ chars: [Character], at i: Int, word: [Character]) -> Bool {
    guard i + word.count <= chars.count else { return false }
    for j in 0..<word.count where chars[i + j] != word[j] { return false }
    let end = i + word.count
    if end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
        return false
    }
    return true
}

// MARK: - XML Highlighting

private static func scanXMLRanges(
    _ chars: [Character],
    ranges: inout [SyntaxTokenRange]
) {
    var i = 0

    while i < chars.count {
        let ch = chars[i]

        // XML comment: <!-- ... -->
        if ch == "<", i + 3 < chars.count,
           chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
            let commentStart = i
            i += 4
            while i + 2 < chars.count {
                if chars[i] == "-", chars[i + 1] == "-", chars[i + 2] == ">" {
                    i += 3
                    break
                }
                i += 1
            }
            if i >= chars.count { i = chars.count }
            ranges.append(SyntaxTokenRange(location: commentStart, length: i - commentStart, kind: .comment))
            continue
        }

        // CDATA: <![CDATA[ ... ]]>
        if ch == "<", i + 8 < chars.count,
           chars[i + 1] == "!", chars[i + 2] == "[",
           chars[i + 3] == "C", chars[i + 4] == "D",
           chars[i + 5] == "A", chars[i + 6] == "T",
           chars[i + 7] == "A", chars[i + 8] == "[" {
            let cdataStart = i
            i += 9
            while i + 2 < chars.count {
                if chars[i] == "]", chars[i + 1] == "]", chars[i + 2] == ">" {
                    i += 3
                    break
                }
                i += 1
            }
            if i >= chars.count { i = chars.count }
            ranges.append(SyntaxTokenRange(location: cdataStart, length: i - cdataStart, kind: .string))
            continue
        }

        // Processing instruction: <? ... ?>
        if ch == "<", i + 1 < chars.count, chars[i + 1] == "?" {
            let piStart = i
            i += 2
            while i + 1 < chars.count {
                if chars[i] == "?", chars[i + 1] == ">" {
                    i += 2
                    break
                }
                i += 1
            }
            if i >= chars.count { i = chars.count }
            ranges.append(SyntaxTokenRange(location: piStart, length: i - piStart, kind: .keyword))
            continue
        }

        // Tag: < ... >
        if ch == "<" {
            let tagStart = i
            i += 1
            // Skip / for closing tags
            if i < chars.count, chars[i] == "/" { i += 1 }

            // Tag name
            let nameStart = i
            while i < chars.count, isIdentChar(chars[i]) || chars[i] == ":" || chars[i] == "-" {
                i += 1
            }
            if i > nameStart {
                ranges.append(SyntaxTokenRange(location: nameStart, length: i - nameStart, kind: .keyword))
            }

            // Attributes inside tag
            while i < chars.count, chars[i] != ">" {
                if chars[i] == "\"" || chars[i] == "'" {
                    let strEnd = scanStringEndPos(chars, from: i, quote: chars[i])
                    ranges.append(SyntaxTokenRange(location: i, length: strEnd - i, kind: .string))
                    i = strEnd
                    continue
                }

                // Attribute name
                if isIdentStart(chars[i]) {
                    let attrStart = i
                    while i < chars.count, isIdentChar(chars[i]) || chars[i] == ":" || chars[i] == "-" {
                        i += 1
                    }
                    ranges.append(SyntaxTokenRange(location: attrStart, length: i - attrStart, kind: .type))
                    continue
                }

                // Skip / before >
                if chars[i] == "/" { i += 1; continue }

                i += 1
            }

            // Include the closing >
            if i < chars.count, chars[i] == ">" {
                i += 1
            }

            // Record the < and > as punctuation
            ranges.append(SyntaxTokenRange(location: tagStart, length: 1, kind: .punctuation))
            if i > tagStart + 1 {
                ranges.append(SyntaxTokenRange(location: i - 1, length: 1, kind: .punctuation))
            }
            continue
        }

        // Entity reference: &name;
        if ch == "&" {
            let entityStart = i
            i += 1
            while i < chars.count, chars[i] != ";", chars[i] != "<", !chars[i].isWhitespace {
                i += 1
            }
            if i < chars.count, chars[i] == ";" { i += 1 }
            ranges.append(SyntaxTokenRange(location: entityStart, length: i - entityStart, kind: .number))
            continue
        }

        i += 1
    }
}

// MARK: - Diff Highlighting

private static func scanDiffRanges(
    _ chars: [Character],
    ranges: inout [SyntaxTokenRange]
) {
    var i = 0

    while i <= chars.count {
        // Find line boundaries
        var lineEnd = i
        while lineEnd < chars.count, chars[lineEnd] != "\n" {
            lineEnd += 1
        }

        if lineEnd > i {
            let lineLen = lineEnd - i
            let ch = chars[i]

            if ch == "+" {
                // +++ header or added line
                if lineLen >= 3, chars[i + 1] == "+", chars[i + 2] == "+" {
                    ranges.append(SyntaxTokenRange(location: i, length: lineLen, kind: .keyword))
                } else {
                    ranges.append(SyntaxTokenRange(location: i, length: lineLen, kind: .string))
                }
            } else if ch == "-" {
                // --- header or removed line
                if lineLen >= 3, chars[i + 1] == "-", chars[i + 2] == "-" {
                    ranges.append(SyntaxTokenRange(location: i, length: lineLen, kind: .keyword))
                } else {
                    ranges.append(SyntaxTokenRange(location: i, length: lineLen, kind: .comment))
                }
            } else if ch == "@" {
                // @@ hunk header
                ranges.append(SyntaxTokenRange(location: i, length: lineLen, kind: .type))
            } else if ch == "d" || ch == "i" || ch == "n" || ch == "r" {
                // diff, index, new, rename headers
                ranges.append(SyntaxTokenRange(location: i, length: lineLen, kind: .keyword))
            }
            // Context lines (space prefix) get default variable color
        }

        i = lineEnd + 1
    }
}
}
