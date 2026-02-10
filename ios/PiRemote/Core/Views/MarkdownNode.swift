import Foundation

/// Parsed CommonMark block node.
///
/// Produced by `parseCommonMark(_:)` from the swift-markdown AST.
/// Consumed by the finalized `CommonMarkView` for SwiftUI rendering.
indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [MarkdownInline])
    case paragraph([MarkdownInline])
    case blockQuote([Self])
    case codeBlock(language: String?, code: String)
    case unorderedList([[Self]])
    case orderedList(start: Int, [[Self]])
    case thematicBreak
    case table(headers: [String], rows: [[String]])
    case htmlBlock(String)
}

/// Parsed CommonMark inline node.
indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([Self])
    case strong([Self])
    case code(String)
    case link(children: [Self], destination: String?)
    case image(alt: String, source: String?)
    case softBreak
    case hardBreak
    case html(String)
    case strikethrough([Self])
}

/// Extract plain text from inline nodes, stripping all formatting.
func plainText(from inlines: [MarkdownInline]) -> String {
    inlines.map { inline -> String in
        switch inline {
        case .text(let s): return s
        case .emphasis(let children): return plainText(from: children)
        case .strong(let children): return plainText(from: children)
        case .code(let s): return s
        case .link(let children, _): return plainText(from: children)
        case .image(let alt, _): return alt
        case .softBreak: return " "
        case .hardBreak: return "\n"
        case .html(let s): return s
        case .strikethrough(let children): return plainText(from: children)
        }
    }.joined()
}
