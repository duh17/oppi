import Foundation

/// Parsed CommonMark block node.
///
/// Produced by `parseCommonMark(_:)` from the cmark-gfm AST.
/// Consumed by the finalized `CommonMarkView` for SwiftUI rendering.
indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [MarkdownInline])
    case paragraph([MarkdownInline])
    case blockQuote([Self])
    case codeBlock(language: String?, code: String)
    case unorderedList([[Self]])
    case orderedList(start: Int, [[Self]])
    case taskList([TaskItem])
    case thematicBreak
    case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    case htmlBlock(String)
    /// A `$$` or `\[` display-math fence. `isClosed` is false while its
    /// closing line has not arrived (streaming) or never does; the block then
    /// runs to the end of its container.
    case math(MarkdownMath, isClosed: Bool)

    struct TaskItem: Equatable, Sendable {
        let checked: Bool
        let content: [MarkdownBlock]
        /// The 1-based source line the item's checkbox is on, when the parse
        /// knows it: a reader that can save the file toggles that line.
        var sourceLine: Int?
        /// Org's `[-]`: some but not all of the item's own sub-items are done.
        /// GFM has no such state, so this is always false outside Org.
        var isPartial: Bool

        init(checked: Bool, content: [MarkdownBlock], sourceLine: Int? = nil, isPartial: Bool = false) {
            self.checked = checked
            self.content = content
            self.sourceLine = sourceLine
            self.isPartial = isPartial
        }
    }
}

struct LocatedMarkdownBlock: Equatable, Sendable {
    let block: MarkdownBlock
    let lineRange: ClosedRange<Int>?
}

/// Parsed CommonMark inline node.
indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([Self])
    case strong([Self])
    case code(String)
    case link(children: [Self], destination: String?)
    /// `size` is Obsidian's `![[pic.png|300]]` or `![alt|300x200](pic.png)`.
    case image(alt: String, source: String?, size: MarkdownEmbedSize? = nil)
    /// Oppi-native `![[video-file]]` / `![](video-file)` embed. Produced by the
    /// wiki-link rewriter after origin and file-type checks succeed.
    case videoEmbed(MarkdownVideoEmbed)
    /// Oppi-native `![[audio-file]]` / `![](audio-file)` embed. Produced by the
    /// wiki-link rewriter after origin and file-type checks succeed.
    case audioEmbed(MarkdownAudioEmbed)
    /// Oppi-native `![[usdz-file]]` / `![](usdz-file)` embed. Produced by the
    /// wiki-link rewriter after origin and file-type checks succeed.
    case usdzEmbed(MarkdownUSDZEmbed)
    case softBreak
    case hardBreak
    case html(String)
    case strikethrough([Self])
    /// `$…$`, `$$…$$` or `\(…\)` inside a line. The parser decides what is math;
    /// renderers draw it and never scan text for delimiters again.
    case math(MarkdownMath)
}

/// A formula the parser found. The renderer draws `latex`, or shows `source`
/// unchanged when the TeX parser rejects it.
struct MarkdownMath: Equatable, Sendable {
    /// The TeX between the delimiters.
    let latex: String
    /// The exact text as written, delimiters included: fallback text, copy,
    /// search and Markdown output.
    let source: String
    /// `$$…$$` or `\[…\]`, as opposed to `$…$` or `\(…\)`.
    let isDisplay: Bool
}

/// The display size an embed asks for, in points, from the last `|` piece of
/// a wiki embed's label or an image's alt text (Obsidian Help, "Embed files"):
/// `300` is a width, and the height follows the picture; `300x200` is a box
/// the picture fits inside.
struct MarkdownEmbedSize: Hashable, Sendable {
    let width: Int
    let height: Int?

    /// `300` or `300x200`, nothing else: no units, no zero, no spaces inside.
    init?(_ text: some StringProtocol) {
        let parts = Substring(text).split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        guard let width = Self.dimension(parts[0]) else { return nil }
        if parts.count == 2 {
            guard let height = Self.dimension(parts[1]) else { return nil }
            self.height = height
        } else {
            height = nil
        }
        self.width = width
    }

    /// Splits a trailing size off a label: `"300"` is a size with no label,
    /// `"Chart|300"` a label and a size, anything else a label alone.
    static func split(label: String) -> (label: String, size: Self?) {
        if let size = Self(label.trimmingCharacters(in: .whitespaces)) { return ("", size) }
        guard let pipe = label.lastIndex(of: "|"),
              let size = Self(label[label.index(after: pipe)...].trimmingCharacters(in: .whitespaces)) else {
            return (label, nil)
        }
        return (String(label[..<pipe]).trimmingCharacters(in: .whitespaces), size)
    }

    /// The Markdown that writes this size: `300` or `300x200`.
    var markup: String { height.map { "\(width)x\($0)" } ?? "\(width)" }

    private static func dimension(_ digits: Substring) -> Int? {
        guard (1 ... 5).contains(digits.utf8.count), digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = Int(digits), value > 0 else { return nil }
        return value
    }
}

/// Extract plain text from inline nodes, stripping all formatting.
func plainText(from inlines: [MarkdownInline]) -> String {
    // Fast path: single .text inline (most common for plain table cells).
    if inlines.count == 1, case .text(let s) = inlines[0] { return s }
    return inlines.map { inline -> String in
        switch inline {
        case .text(let s): return s
        case .emphasis(let children): return plainText(from: children)
        case .strong(let children): return plainText(from: children)
        case .code(let s): return s
        case .link(let children, _): return plainText(from: children)
        case .image(let alt, _, _): return alt
        case .videoEmbed(let embed): return embed.displayLabel
        case .audioEmbed(let embed): return embed.displayLabel
        case .usdzEmbed(let embed): return embed.displayLabel
        case .softBreak: return " "
        case .hardBreak: return "\n"
        case .html(let s): return MarkdownBadge(markup: s)?.text ?? s
        case .strikethrough(let children): return plainText(from: children)
        case .math(let math): return math.source
        }
    }.joined()
}
