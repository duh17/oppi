/// The one set of rules for where TeX math starts and ends in Markdown.
///
/// Pandoc's `tex_math_dollars` and `tex_math_single_backslash`, with the
/// dollar closer widened from "not before a digit" to "not before a letter or
/// digit", so `$PATH:$HOME` and `$USD/$EUR` stay prose. The cmark extension
/// (`MarkdownMathExtension`) asks these functions at a candidate opener; code
/// spans, escapes, table cells and block structure are cmark's, so nothing here
/// tracks them. Every function reads UTF-8 bytes in one forward pass and stops
/// at the first candidate closer: no backtracking, so a paragraph costs linear
/// time however many dollars it holds.
///
/// - `$…$`: the opener is not next to another `$` and is followed by a
///   non-space; the first unescaped `$` after it decides. It closes when a
///   non-space precedes it and no letter, digit or `$` follows. `\$` never
///   delimits.
/// - `$$…$$` inside a line: display math; the first unescaped `$$` decides, by
///   the same "no letter or digit after" rule.
/// - `\(…\)`: the closer is the first `\)` whose backslash is not escaped.
/// - A display block is a line that is exactly `$$` or `\[`, closed by a line
///   that ends with `$$` or `\]`, or one line `$$…$$` / `\[…\]`.
enum MathDelimiterRules {
    static let dollar = UInt8(ascii: "$")
    static let backslash = UInt8(ascii: "\\")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")

    enum InlineKind: Equatable {
        /// `$…$`
        case dollar
        /// `$$…$$`
        case displayDollar
        /// `\(…\)`
        case paren

        var opener: String {
            switch self {
            case .dollar: "$"
            case .displayDollar: "$$"
            case .paren: #"\("#
            }
        }

        var closer: String {
            switch self {
            case .dollar: "$"
            case .displayDollar: "$$"
            case .paren: #"\)"#
            }
        }
    }

    /// A formula found inside a line: the TeX lies in `contentStart..<contentEnd`
    /// and the source, delimiters included, ends before `end`.
    struct InlineMatch: Equatable {
        let kind: InlineKind
        let contentStart: Int
        let contentEnd: Int
        let end: Int
    }

    /// The formula that starts with the `$` at `open`, if any.
    static func dollarMath(in bytes: UnsafeBufferPointer<UInt8>, open: Int) -> InlineMatch? {
        guard bytes[open] == dollar, open == 0 || bytes[open - 1] != dollar else { return nil }
        if open + 1 < bytes.count, bytes[open + 1] == dollar {
            return displayDollarMath(in: bytes, open: open)
        }
        let contentStart = open + 1
        guard contentStart < bytes.count, !isSpace(bytes[contentStart]) else { return nil }
        var index = contentStart
        while index < bytes.count {
            let byte = bytes[index]
            if byte == backslash {
                index += 2
                continue
            }
            if byte == dollar {
                guard index > contentStart, !isSpace(bytes[index - 1]),
                      !continuesWord(bytes, at: index + 1) else { return nil }
                return InlineMatch(kind: .dollar, contentStart: contentStart, contentEnd: index, end: index + 1)
            }
            index += 1
        }
        return nil
    }

    private static func displayDollarMath(in bytes: UnsafeBufferPointer<UInt8>, open: Int) -> InlineMatch? {
        let contentStart = open + 2
        guard contentStart < bytes.count, bytes[contentStart] != dollar else { return nil }
        var index = contentStart
        while index < bytes.count {
            let byte = bytes[index]
            if byte == backslash {
                index += 2
                continue
            }
            if byte == dollar {
                guard index + 1 < bytes.count, bytes[index + 1] == dollar,
                      hasNonSpace(bytes, contentStart ..< index),
                      !continuesWord(bytes, at: index + 2) else { return nil }
                return InlineMatch(kind: .displayDollar, contentStart: contentStart, contentEnd: index, end: index + 2)
            }
            index += 1
        }
        return nil
    }

    /// The formula whose `\(` has its `(` at `open`. The backslash before it
    /// must itself be unescaped.
    static func parenMath(in bytes: UnsafeBufferPointer<UInt8>, open: Int) -> InlineMatch? {
        guard bytes[open] == openParen, isUnescapedBackslash(bytes, at: open - 1) else { return nil }
        let contentStart = open + 1
        var index = contentStart
        while index + 1 < bytes.count {
            if bytes[index] == backslash {
                if bytes[index + 1] == closeParen {
                    guard hasNonSpace(bytes, contentStart ..< index) else { return nil }
                    return InlineMatch(kind: .paren, contentStart: contentStart, contentEnd: index, end: index + 2)
                }
                index += 2
                continue
            }
            index += 1
        }
        return nil
    }

    /// Whether the byte at `index` is a backslash that an odd run ends, so it
    /// escapes what follows rather than being escaped itself.
    static func isUnescapedBackslash(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        var count = 0
        var cursor = index
        while cursor >= 0, bytes[cursor] == backslash {
            count += 1
            cursor -= 1
        }
        return count % 2 == 1
    }

    // MARK: - Display blocks

    enum BlockFence: Equatable {
        case dollars
        case brackets

        var opener: String { self == .dollars ? "$$" : #"\["# }
        var closer: String { self == .dollars ? "$$" : #"\]"# }
    }

    /// How a line opens a display block: its fence, and the TeX of a one-line
    /// block (`$$x$$`), or nil content for a fence line that the block's later
    /// lines fill. `line` excludes the line ending and container indentation.
    static func blockOpening(_ line: UnsafeBufferPointer<UInt8>) -> (fence: BlockFence, oneLine: Range<Int>?)? {
        let body = trimmed(line)
        guard body.count >= 2 else { return nil }
        let fence: BlockFence
        if line[body.lowerBound] == dollar, line[body.lowerBound + 1] == dollar {
            fence = .dollars
        } else if line[body.lowerBound] == backslash, line[body.lowerBound + 1] == UInt8(ascii: "[") {
            fence = .brackets
        } else {
            return nil
        }
        if body.count == 2 { return (fence, nil) }
        guard body.count > 4, let closerStart = closerStart(line, body: body, fence: fence),
              closerStart == body.upperBound - 2, closerStart > body.lowerBound + 2 else { return nil }
        let content = body.lowerBound + 2 ..< closerStart
        guard hasNonSpace(line, content) else { return nil }
        return (fence, content)
    }

    /// For a line inside an open block: the TeX it adds, and whether it closes
    /// the block (it ends with the fence's closer). A closer line with only
    /// spaces before the closer adds nothing.
    static func blockLine(_ line: UnsafeBufferPointer<UInt8>, fence: BlockFence) -> (content: Range<Int>, closes: Bool) {
        let body = trimmed(line)
        guard body.count >= 2, line[body.upperBound - 2] == (fence == .dollars ? dollar : backslash),
              line[body.upperBound - 1] == (fence == .dollars ? dollar : UInt8(ascii: "]")),
              fence == .dollars || isUnescapedBackslash(line, at: body.upperBound - 2) else {
            return (0 ..< line.count, false)
        }
        let content = 0 ..< body.upperBound - 2
        return (hasNonSpace(line, content) ? content : 0 ..< 0, true)
    }

    private static func closerStart(
        _ line: UnsafeBufferPointer<UInt8>,
        body: Range<Int>,
        fence: BlockFence
    ) -> Int? {
        var index = body.lowerBound + 2
        while index + 1 < body.upperBound {
            let byte = line[index]
            if fence == .dollars, byte == dollar, line[index + 1] == dollar { return index }
            if byte == backslash {
                if fence == .brackets, line[index + 1] == UInt8(ascii: "]") { return index }
                index += 2
                continue
            }
            index += 1
        }
        return nil
    }

    // MARK: - Bytes

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func hasNonSpace(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Bool {
        range.contains { !isSpace(bytes[$0]) }
    }

    private static func trimmed(_ line: UnsafeBufferPointer<UInt8>) -> Range<Int> {
        var start = 0
        var end = line.count
        while start < end, isSpace(line[start]) { start += 1 }
        while end > start, isSpace(line[end - 1]) { end -= 1 }
        return start ..< end
    }

    /// Whether the scalar starting at `index` is a letter, a digit or `$`: a
    /// dollar there is a price or a variable (`$5`, `$HOME`), not a closer.
    private static func continuesWord(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        guard index < bytes.count else { return false }
        let lead = bytes[index]
        if lead < 0x80 {
            return lead == dollar || (lead >= 0x30 && lead <= 0x39)
                || (lead | 0x20 >= 0x61 && lead | 0x20 <= 0x7A)
        }
        var iterator = UnsafeBufferPointer(rebasing: bytes[index...]).makeIterator()
        var decoder = UTF8()
        guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
