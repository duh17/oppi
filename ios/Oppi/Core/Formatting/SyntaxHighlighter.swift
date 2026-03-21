import SwiftUI // Theme color resolution (Color.themeSyntax* → UIColor)
import UIKit

// swiftlint:disable large_tuple

// MARK: - SyntaxLanguage

/// Language identification for syntax highlighting.
///
/// Maps file extensions and markdown fence names to language-specific
/// highlighting rules (keywords, comment patterns).
enum SyntaxLanguage: Sendable, Hashable {
    case swift
    case typescript
    case javascript
    case python
    case go
    case rust
    case ruby
    case shell
    case html
    case css
    case json
    case yaml
    case toml
    case sql
    case c
    case cpp
    case java
    case kotlin
    case zig
    case unknown

    /// Detect language from file extension or code fence name.
    static func detect(_ identifier: String) -> Self {
        switch identifier.lowercased() {
        case "swift": return .swift
        case "ts", "tsx", "mts", "cts", "typescript": return .typescript
        case "js", "jsx", "mjs", "cjs", "javascript": return .javascript
        case "py", "pyi", "python": return .python
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "rb", "ruby": return .ruby
        case "sh", "bash", "zsh", "fish", "shell": return .shell
        case "html", "htm": return .html
        case "css", "scss", "less": return .css
        case "json", "jsonl", "geojson": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "sql": return .sql
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hxx", "c++": return .cpp
        case "java": return .java
        case "kt", "kts", "kotlin": return .kotlin
        case "zig": return .zig
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .typescript: return "TypeScript"
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .go: return "Go"
        case .rust: return "Rust"
        case .ruby: return "Ruby"
        case .shell: return "Shell"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .sql: return "SQL"
        case .c: return "C"
        case .cpp: return "C++"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .zig: return "Zig"
        case .unknown: return "Text"
        }
    }

    var lineCommentPrefix: [Character]? {
        switch self {
        case .swift, .typescript, .javascript, .go, .rust, .c, .cpp, .java, .kotlin, .zig, .css:
            return ["/", "/"]
        case .python, .ruby, .shell, .yaml, .toml:
            return ["#"]
        case .sql:
            return ["-", "-"]
        case .html, .json, .unknown:
            return nil
        }
    }

    var hasBlockComments: Bool {
        switch self {
        case .swift, .typescript, .javascript, .go, .rust, .c, .cpp, .java, .kotlin, .zig, .css:
            return true
        default:
            return false
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return swiftKeywords
        case .typescript, .javascript:
            return tsKeywords
        case .python:
            return pythonKeywords
        case .go:
            return goKeywords
        case .rust:
            return rustKeywords
        case .ruby:
            return rubyKeywords
        case .shell:
            return shellKeywords
        case .sql:
            return sqlKeywords
        case .c, .cpp:
            return cKeywords
        case .java:
            return javaKeywords
        case .kotlin:
            return kotlinKeywords
        case .zig:
            return zigKeywords
        case .html, .css, .json, .yaml, .toml, .unknown:
            return []
        }
    }
}

// MARK: - SyntaxHighlighter

/// Lightweight deterministic syntax highlighter used across chat, file viewer,
/// and diff surfaces.
///
/// Uses a fast scanner (comments/strings/numbers/keywords) with predictable
/// performance and no external parser dependencies.
///
/// Returns `NSAttributedString` built via `NSMutableAttributedString` internally
/// to avoid the O(n^2) cost of SwiftUI `AttributedString` concatenation.
enum SyntaxHighlighter {

    /// Maximum lines to highlight before truncating (with unhighlighted
    /// remainder appended by the full-screen code path).
    ///
    /// Bench results (simulator, M-series Mac — iPhone ~2-4x slower):
    ///   1K lines: Swift 7ms, TS 11ms, JSON 16ms
    ///   5K lines: Swift 34ms, TS 55ms, JSON 82ms
    ///  10K lines: Swift 70ms, TS 111ms, JSON 163ms
    ///
    /// All highlighting runs on Task.detached, so even worst-case JSON
    /// at 10K (~650ms on iPhone) is fine — users see plain text immediately.
    static let maxLines = 10_000

    // MARK: - Pre-computed Token Attributes

    /// Resolved UIColor attribute dictionaries for each token type.
    /// Created once per top-level highlight call to avoid repeated
    /// `UIColor(Color)` conversions per token.
    private struct TokenAttrs {
        let comment: [NSAttributedString.Key: Any]
        let keyword: [NSAttributedString.Key: Any]
        let string: [NSAttributedString.Key: Any]
        let number: [NSAttributedString.Key: Any]
        let type: [NSAttributedString.Key: Any]
        let variable: [NSAttributedString.Key: Any]
        let punctuation: [NSAttributedString.Key: Any]
        let function: [NSAttributedString.Key: Any]
        let `operator`: [NSAttributedString.Key: Any]

        // Cache: UIColor(Color) is expensive (~10μs each × 9 = ~90μs per call).
        // Invalidated on theme change via resetCachedAttrs().
        nonisolated(unsafe) private static var cached: Self?

        // Called from Task.detached for performance — must remain nonisolated.
        // Safe: cached is written only from @MainActor contexts; worst-case
        // race reads nil and rebuilds (idempotent).
        static func current() -> Self {
            if let cached { return cached }
            let attrs = Self(
                comment: [.foregroundColor: UIColor(Color.themeSyntaxComment)],
                keyword: [.foregroundColor: UIColor(Color.themeSyntaxKeyword)],
                string: [.foregroundColor: UIColor(Color.themeSyntaxString)],
                number: [.foregroundColor: UIColor(Color.themeSyntaxNumber)],
                type: [.foregroundColor: UIColor(Color.themeSyntaxType)],
                variable: [.foregroundColor: UIColor(Color.themeSyntaxVariable)],
                punctuation: [.foregroundColor: UIColor(Color.themeSyntaxPunctuation)],
                function: [.foregroundColor: UIColor(Color.themeSyntaxFunction)],
                operator: [.foregroundColor: UIColor(Color.themeSyntaxOperator)]
            )
            cached = attrs
            return attrs
        }

    }

    // MARK: - Token Type (for range-based highlighting)

    /// Token categories for range-based attribute application.
    enum TokenKind: UInt8 {
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
    struct TokenRange {
        let location: Int  // character offset in the scanned text
        let length: Int    // character length
        let kind: TokenKind
    }

    // MARK: - Public API

    /// Resolve a token kind to its UIColor using the cached TokenAttrs.
    static func color(for kind: TokenKind) -> UIColor? {
        guard kind != .variable else { return nil }
        let attrs = TokenAttrs.current()
        let dict: [NSAttributedString.Key: Any]
        switch kind {
        case .variable: return nil
        case .comment: dict = attrs.comment
        case .keyword: dict = attrs.keyword
        case .string: dict = attrs.string
        case .number: dict = attrs.number
        case .type: dict = attrs.type
        case .punctuation: dict = attrs.punctuation
        case .function: dict = attrs.function
        case .operator: dict = attrs.operator
        }
        return dict[.foregroundColor] as? UIColor
    }

    /// Scan source code and return token ranges for non-default tokens.
    ///
    /// Each range's `location` is the character offset within `code`.
    /// Used by `makeCodeAttributedText` to apply syntax colors with gutter
    /// offset mapping in a single-pass build.
    static func scanTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [TokenRange] {
        scanTokenRangesInternal(Array(truncatedCode(code)), language: language)
    }

    /// ASCII-optimized scanner using raw UTF-8 bytes.
    ///
    /// For ASCII text (which covers >99% of source code), byte offsets equal
    /// character/UTF-16 offsets, so we can skip the expensive `[Character]`
    /// array conversion entirely. Falls back to the character-based scanner
    /// for non-ASCII input.
    ///
    /// Used by `DiffAttributedStringBuilder` for batch syntax scanning.
    static func scanTokenRangesUTF8(
        _ text: String,
        language: SyntaxLanguage
    ) -> [TokenRange] {
        guard language != .unknown else { return [] }

        // Shell has complex state; JSON is already fast. Use existing scanner.
        if language == .shell || language == .json {
            return scanTokenRangesInternal(Array(text), language: language)
        }

        let utf8 = Array(text.utf8)

        // Verify all-ASCII. Any non-ASCII byte → fall back to [Character] scanner
        // where byte offsets ≠ character offsets.
        for b in utf8 where b >= 0x80 {
            return scanTokenRangesInternal(Array(text), language: language)
        }

        return scanTokenRangesFromUTF8(utf8, language: language)
    }

    /// Highlight source code using range-based attribute application.
    ///
    /// Builds a single NSMutableAttributedString from the full text with default
    /// (variable) color, then applies token-specific colors by NSRange. This avoids
    /// creating thousands of intermediate NSAttributedString objects per token.
    static func highlight(_ code: String, language: SyntaxLanguage) -> NSAttributedString {
        let truncated = truncatedCode(code)
        let attrs = TokenAttrs.current()

        // Build the full attributed string with default variable color.
        let result = NSMutableAttributedString(string: truncated, attributes: attrs.variable)

        // Scan for token ranges using the shared single-array scanner.
        let tokenRanges = scanTokenRangesInternal(Array(truncated), language: language)

        // Pre-extract UIColors to avoid dictionary lookup + cast per token.
        let commentColor = attrs.comment[.foregroundColor] as? UIColor
        let keywordColor = attrs.keyword[.foregroundColor] as? UIColor
        let stringColor = attrs.string[.foregroundColor] as? UIColor
        let numberColor = attrs.number[.foregroundColor] as? UIColor
        let typeColor = attrs.type[.foregroundColor] as? UIColor
        let punctuationColor = attrs.punctuation[.foregroundColor] as? UIColor
        let functionColor = attrs.function[.foregroundColor] as? UIColor
        let operatorColor = attrs.operator[.foregroundColor] as? UIColor

        // Apply token colors by range.
        for token in tokenRanges {
            let color: UIColor?
            switch token.kind {
            case .variable: continue // already default
            case .comment: color = commentColor
            case .keyword: color = keywordColor
            case .string: color = stringColor
            case .number: color = numberColor
            case .type: color = typeColor
            case .punctuation: color = punctuationColor
            case .function: color = functionColor
            case .operator: color = operatorColor
            }
            if let color {
                result.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSRange(location: token.location, length: token.length)
                )
            }
        }

        return result
    }

    /// Internal scanner shared by `highlight()` and `scanTokenRanges()`.
    /// Scans line-by-line using newline detection (no per-line `Array(line)` allocation).
    private static func scanTokenRangesInternal(
        _ allChars: [Character],
        language: SyntaxLanguage
    ) -> [TokenRange] {
        var tokenRanges: [TokenRange] = []
        tokenRanges.reserveCapacity(allChars.count / 4)

        if language == .json {
            scanJSONRanges(allChars, ranges: &tokenRanges)
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
                if language == .shell {
                    scanShellLineRangesSlice(
                        allChars, start: pos, end: lineEnd,
                        ranges: &tokenRanges
                    )
                } else {
                    scanLineRangesSlice(
                        allChars, start: pos, end: lineEnd,
                        language: language,
                        keywords: keywords,
                        commentPrefix: commentPrefix,
                        inBlockComment: &inBlockComment,
                        ranges: &tokenRanges
                    )
                }
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
    ) -> [TokenRange] {
        var tokenRanges: [TokenRange] = []
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
    /// All offsets are byte positions (== character positions for ASCII input).
    private static func scanLineRangesUTF8Slice(
        _ bytes: [UInt8],
        start: Int,
        end: Int,
        language: SyntaxLanguage,
        keywords: Set<String>,
        commentPrefix: [UInt8]?,
        inBlockComment: inout Bool,
        ranges: inout [TokenRange]
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
                    ranges.append(TokenRange(location: commentStart, length: i - commentStart, kind: .comment))
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
                ranges.append(TokenRange(location: commentStart, length: i - commentStart, kind: .comment))
                continue
            }

            // Line comment
            if let prefix = commentPrefix, matchesBytesAt(bytes, offset: i, end: end, pattern: prefix) {
                ranges.append(TokenRange(location: i, length: end - i, kind: .comment))
                return
            }

            // Preprocessor for C/C++
            if b == 0x23, language == .c || language == .cpp { // #
                ranges.append(TokenRange(location: i, length: end - i, kind: .keyword))
                return
            }

            // Decorator @
            if b == 0x40 {
                let tokenStart = i
                i += 1
                while i < end, isIdentByteASCII(bytes[i]) { i += 1 }
                ranges.append(TokenRange(location: tokenStart, length: i - tokenStart, kind: .type))
                continue
            }

            // String literal: " ' `
            if b == 0x22 || b == 0x27 || b == 0x60 {
                let tokenEnd = scanStringEndUTF8(bytes, from: i, end: end, quote: b)
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .string))
                i = tokenEnd
                continue
            }

            // Number: 0-9
            if b >= 0x30, b <= 0x39 {
                let tokenEnd = scanNumberEndUTF8(bytes, from: i, end: end)
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .number))
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
                        ranges.append(TokenRange(location: i, length: wordLen, kind: .keyword))
                        i = wordEnd
                        continue
                    }
                }

                // Type-like: starts uppercase, has lowercase
                if wordLen >= 2, b >= 0x41, b <= 0x5A {
                    let hasLower = ((i + 1)..<wordEnd).contains { bytes[$0] >= 0x61 && bytes[$0] <= 0x7A }
                    if hasLower {
                        ranges.append(TokenRange(location: i, length: wordLen, kind: .type))
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

    private static func truncatedCode(_ code: String) -> String {
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
        ranges: inout [TokenRange]
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
                    ranges.append(TokenRange(location: commentStart, length: i - commentStart, kind: .comment))
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
                ranges.append(TokenRange(location: commentStart, length: i - commentStart, kind: .comment))
                continue
            }

            if let prefix = commentPrefix, matchesAt(allChars, offset: i, pattern: prefix) {
                ranges.append(TokenRange(location: i, length: end - i, kind: .comment))
                return
            }

            if allChars[i] == "#", language == .c || language == .cpp {
                ranges.append(TokenRange(location: i, length: end - i, kind: .keyword))
                return
            }

            if allChars[i] == "@" {
                let tokenStart = i
                i += 1
                while i < end, isIdentChar(allChars[i]) {
                    i += 1
                }
                ranges.append(TokenRange(location: tokenStart, length: i - tokenStart, kind: .type))
                continue
            }

            let ch = allChars[i]
            if ch == "\"" || ch == "'" || ch == "`" {
                let tokenEnd = scanStringEndPos(allChars, from: i, quote: ch)
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .string))
                i = tokenEnd
                continue
            }

            if isDigitASCII(ch) {
                let tokenEnd = scanNumberEnd(allChars, from: i)
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .number))
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
                    ranges.append(TokenRange(location: i, length: wordLen, kind: .keyword))
                } else if wordLen >= 2, isUpperASCII(allChars[i]) {
                    // Check isTypeLike without String allocation
                    let hasLower = ((i + 1)..<wordEnd).contains { isLowerASCII(allChars[$0]) }
                    if hasLower {
                        ranges.append(TokenRange(location: i, length: wordLen, kind: .type))
                    }
                }
                i = wordEnd
                continue
            }

            i += 1
        }
    }

    /// Scan a shell line within allChars[start..<end] for token ranges.
    private static func scanShellLineRangesSlice(
        _ allChars: [Character],
        start: Int,
        end: Int,
        ranges: inout [TokenRange]
    ) {
        var i = start
        var expectCommand = true

        while i < end {
            let ch = allChars[i]

            if ch.isWhitespace {
                i += 1
                continue
            }

            if ch == "#", isShellCommentStart(allChars, at: i) {
                ranges.append(TokenRange(location: i, length: end - i, kind: .comment))
                return
            }

            if ch == "\"" || ch == "'" || ch == "`" {
                let tokenEnd = scanStringEndPos(allChars, from: i, quote: ch)
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .string))
                i = tokenEnd
                expectCommand = false
                continue
            }

            if ch == "$" {
                let (_, tokenEnd) = scanShellVariable(allChars, from: i)
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .type))
                i = tokenEnd
                expectCommand = false
                continue
            }

            if let (_, tokenEnd, resetsCommand) = scanShellOperator(allChars, from: i) {
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .operator))
                i = tokenEnd
                if resetsCommand { expectCommand = true }
                continue
            }

            if ch == "-", isShellOptionStart(allChars, at: i) {
                let (_, tokenEnd) = scanShellToken(allChars, from: i)
                i = tokenEnd
                expectCommand = false
                continue
            }

            let (token, tokenEnd) = scanShellToken(allChars, from: i)
            if token.isEmpty {
                i += 1
                continue
            }

            if expectCommand, isShellAssignment(token) {
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .type))
                i = tokenEnd
                continue
            }

            if shellKeywords.contains(token) {
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .keyword))
                expectCommand = shellCommandStarterKeywords.contains(token)
                i = tokenEnd
                continue
            }

            if expectCommand {
                ranges.append(TokenRange(location: i, length: tokenEnd - i, kind: .function))
                expectCommand = false
            }
            i = tokenEnd
        }
    }

    // MARK: - Shell Scanner

    private static func isShellCommentStart(_ chars: [Character], at index: Int) -> Bool {
        guard chars[index] == "#" else { return false }
        guard index > 0 else { return true }
        let prev = chars[index - 1]
        return prev.isWhitespace || prev == ";" || prev == "|" || prev == "&" || prev == "(" || prev == ")"
    }

    private static func isShellOptionStart(_ chars: [Character], at index: Int) -> Bool {
        guard chars[index] == "-", index + 1 < chars.count else { return false }
        let next = chars[index + 1]
        guard !next.isWhitespace,
              next != "|", next != "&", next != ";", next != "<", next != ">", next != ")" else {
            return false
        }
        guard index > 0 else { return true }
        let prev = chars[index - 1]
        return prev.isWhitespace || prev == "|" || prev == "&" || prev == ";" || prev == "("
    }

    private static func scanShellToken(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || isShellDelimiter(c) {
                break
            }
            i += 1
        }
        return (String(chars[start..<i]), i)
    }

    private static func isShellDelimiter(_ c: Character) -> Bool {
        c == "|" || c == "&" || c == ";" || c == "<" || c == ">" || c == "(" || c == ")"
    }

    private static func scanShellOperator(
        _ chars: [Character],
        from start: Int
    ) -> (String, Int, Bool)? {
        guard start < chars.count else { return nil }
        let ch = chars[start]

        // File descriptor redirection, e.g. 2>&1, 1>out.log
        if ch.isNumber {
            var i = start
            while i < chars.count, chars[i].isNumber { i += 1 }
            if i < chars.count, chars[i] == ">" || chars[i] == "<" {
                let end = scanShellRedirection(chars, from: i)
                return (String(chars[start..<end]), end, false)
            }
        }

        switch ch {
        case "|":
            if start + 1 < chars.count, chars[start + 1] == "|" {
                return ("||", start + 2, true)
            }
            if start + 1 < chars.count, chars[start + 1] == "&" {
                return ("|&", start + 2, true)
            }
            return ("|", start + 1, true)

        case "&":
            if start + 1 < chars.count, chars[start + 1] == "&" {
                return ("&&", start + 2, true)
            }
            if start + 1 < chars.count, chars[start + 1] == ">" {
                let end = scanShellRedirection(chars, from: start + 1)
                return (String(chars[start..<end]), end, false)
            }
            return ("&", start + 1, true)

        case ";":
            if start + 1 < chars.count, chars[start + 1] == ";" {
                return (";;", start + 2, true)
            }
            return (";", start + 1, true)

        case "(", ")":
            return (String(ch), start + 1, true)

        case "<", ">":
            let end = scanShellRedirection(chars, from: start)
            return (String(chars[start..<end]), end, false)

        default:
            return nil
        }
    }

    private static func scanShellRedirection(_ chars: [Character], from start: Int) -> Int {
        var i = start
        guard i < chars.count else { return i }

        let op = chars[i]
        i += 1

        if i < chars.count, chars[i] == op {
            // >> or <<
            i += 1
        } else if op == ">", i < chars.count, chars[i] == "|" {
            // >|
            i += 1
        }

        if i < chars.count, chars[i] == "&" {
            i += 1
            if i < chars.count, chars[i] == "-" {
                i += 1
            } else {
                while i < chars.count, chars[i].isNumber { i += 1 }
            }
        }

        return i
    }

    private static func scanShellVariable(_ chars: [Character], from start: Int) -> (String, Int) {
        guard start < chars.count, chars[start] == "$" else { return ("", start) }

        var i = start + 1
        guard i < chars.count else { return ("$", i) }
        let next = chars[i]

        if next == "{" {
            i += 1
            var depth = 1
            while i < chars.count, depth > 0 {
                let c = chars[i]
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                } else if c == "\"" || c == "'" || c == "`" {
                    i = scanStringEndPos(chars, from: i, quote: c)
                    continue
                } else if c == "\\" {
                    i = min(i + 2, chars.count)
                    continue
                }
                i += 1
            }
            return (String(chars[start..<i]), i)
        }

        if next == "(" {
            i += 1
            var depth = 1
            while i < chars.count, depth > 0 {
                let c = chars[i]
                if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                    i += 1
                    continue
                } else if c == "\"" || c == "'" || c == "`" {
                    i = scanStringEndPos(chars, from: i, quote: c)
                    continue
                } else if c == "\\" {
                    i = min(i + 2, chars.count)
                    continue
                }
                i += 1
            }
            return (String(chars[start..<i]), i)
        }

        if next == "*" || next == "@" || next == "#" || next == "?" ||
            next == "-" || next == "$" || next == "!" || next == "_" {
            return (String(chars[start...i]), i + 1)
        }

        if next.isNumber {
            i += 1
            while i < chars.count, chars[i].isNumber { i += 1 }
            return (String(chars[start..<i]), i)
        }

        if next.isLetter || next == "_" {
            i += 1
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                i += 1
            }
            return (String(chars[start..<i]), i)
        }

        return ("$", start + 1)
    }

    private static func isShellAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[token.startIndex..<eq]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
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
        ranges: inout [TokenRange]
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
                let kind: TokenKind = lookahead < chars.count && chars[lookahead] == ":" ? .type : .string
                ranges.append(TokenRange(location: i, length: end - i, kind: kind))
                i = end
                continue
            }

            if ch.isNumber || (ch == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                let end = scanJSONNumberEnd(chars, from: i)
                ranges.append(TokenRange(location: i, length: end - i, kind: .number))
                i = end
                continue
            }

            if let (length, kind) = scanJSONKeyword(chars, from: i) {
                ranges.append(TokenRange(location: i, length: length, kind: kind))
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
            ranges.append(TokenRange(location: punctuationStart, length: i - punctuationStart, kind: .punctuation))
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

    private static func scanJSONKeyword(_ chars: [Character], from i: Int) -> (length: Int, kind: TokenKind)? {
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

}
