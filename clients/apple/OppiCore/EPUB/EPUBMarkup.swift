import Foundation

/// One top-level block of a rendered chapter. The reader keeps its position as
/// an index into this list, and the Markdown body's segments start on exactly
/// these lines, so an ordinal survives a text-size change.
struct EPUBChapterBlock: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case text
        case code
        case table
        case thematicBreak
    }

    /// 1-based line of the chapter's Markdown where this block starts, as the
    /// reader's located blocks report it: a fenced code block starts on its
    /// first code line, not on the opening fence.
    let markdownStartLine: Int
    let kind: Kind
}

/// A chapter as the native reader shows it: Markdown for the existing body,
/// plus where each top-level block begins.
struct EPUBChapterSource: Equatable, Sendable {
    let markdown: String
    let blocks: [EPUBChapterBlock]
    /// Paragraph direction from `dir`/`xml:lang`; nil when the document does
    /// not say (the spine's page-progression-direction then decides).
    let isRightToLeft: Bool?

    /// A chapter this slice cannot show natively: a document that is not the
    /// XML we read (tag soup, vertical writing, an over-budget file).
    static let unavailable = EPUBChapterSource(markdown: "", blocks: [], isRightToLeft: nil)
    var isAvailable: Bool { !blocks.isEmpty }
}

/// XHTML → Markdown for the native reading body.
///
/// The reader's Markdown body already owns selection, themes, text size, and
/// the viewport, so a chapter becomes its source: headings, paragraphs, lists,
/// quotes, code, and tables. Publisher fonts, colours, floats, and images are
/// dropped on purpose; an image keeps its alt text so the words stay.
enum EPUBMarkup {
    /// Nil when the chapter is not well-formed XML (the body then shows its
    /// placeholder). An empty document is available and empty.
    static func convert(_ document: String) -> EPUBChapterSource? {
        // Vertical writing needs a TextKit container we do not have yet.
        if document.range(of: "vertical-rl", options: .caseInsensitive) != nil {
            return nil
        }
        let parser = MarkupParser()
        guard EPUBXML.parse(document, with: parser) else { return nil }
        parser.finish()
        return EPUBChapterSource(
            markdown: parser.markdown,
            blocks: parser.blocks,
            isRightToLeft: parser.isRightToLeft
        )
    }
}

extension EPUBMarkup {
    fileprivate final class MarkupParser: NSObject, XMLParserDelegate {
        private(set) var isRightToLeft: Bool?
        private(set) var blocks: [EPUBChapterBlock] = []
        private var lines: [String] = []
        private var flow = ""
        /// Depth of the element that owns the top-level block being collected.
        private var blockDepth: Int?
        private var blockKind: EPUBChapterBlock.Kind = .text
        private var blockStartLine = 0
        private var depth = 0
        /// Depth of a subtree whose text is not part of the flow.
        private var skipDepth: Int?
        private var inline = ""
        private var preText: String?
        private var preLanguage: String?
        private var tableRows: [[String]]?
        private var tableRow: [String]?
        private var tableCell: String?
        private var headingLevel: Int?
        private var quoteDepth: Int?
        private var listDepth = 0
        private var orderedListStack: [Bool] = []

        var markdown: String { lines.joined(separator: "\n") }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            depth += 1
            if skipDepth != nil { return }
            if let direction = attributeDict["dir"]?.lowercased() {
                isRightToLeft = isRightToLeft ?? (direction == "rtl")
            }
            if let language = attributeDict["xml:lang"] ?? attributeDict["lang"] {
                isRightToLeft = isRightToLeft ?? language.isRightToLeftScript
            }
            switch localName(elementName) {
            case "head", "script", "style", "rt", "rp", "svg", "math", "title":
                // Scripts never run; ruby annotations and SVG are not rendered.
                skipDepth = depth
            case "h1", "h2", "h3", "h4", "h5", "h6":
                startBlock(.text)
                headingLevel = Int(localName(elementName).dropFirst()) ?? 2
            case "br":
                inline += "  \n"
            case "hr":
                startBlock(.thematicBreak)
                appendParagraph("---")
                endBlock(at: blockDepth ?? depth)
            case "blockquote":
                startBlock(.text)
                if blockDepth == depth { quoteDepth = depth }
            case "ul", "ol":
                startBlock(.text)
                orderedListStack.append(localName(elementName) == "ol")
                listDepth += 1
            case "li":
                flushInline()
                let ordered = orderedListStack.last ?? false
                let indent = String(repeating: "  ", count: max(0, listDepth - 1))
                inline += indent + (ordered ? "1. " : "- ")
            case "pre":
                startBlock(.code)
                preText = ""
                preLanguage = languageHint(attributeDict["class"])
            case "table":
                startBlock(.table)
                tableRows = []
            case "tr":
                tableRow = []
            case "td", "th":
                tableCell = ""
            case "img":
                let alt = (attributeDict["alt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alt.isEmpty else { return }
                if blockDepth == nil, inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // A standalone image keeps its alt text as its own paragraph.
                    startBlock(.text)
                    appendParagraph(escape(alt))
                    endBlock(at: blockDepth ?? depth)
                } else {
                    inline += escape(alt)
                }
            case "em", "i", "cite", "dfn":
                inline += "*"
            case "strong", "b":
                inline += "**"
            case "code", "kbd", "samp", "tt":
                // EPUB 3 puts the language on the `code` inside a `pre`.
                if preText != nil, let language = languageHint(attributeDict["class"]) {
                    preLanguage = language
                } else {
                    inline += "`"
                }
            case "s", "strike", "del":
                inline += "~~"
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let skipDepth, depth >= skipDepth { return }
            if preText != nil {
                preText? += string
            } else if tableCell != nil {
                tableCell? += string
            } else {
                inline += escape(string)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if let skip = skipDepth, depth >= skip {
                if depth == skip { skipDepth = nil }
                depth -= 1
                return
            }
            defer { depth -= 1 }
            switch localName(elementName) {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushInline()
                headingLevel = nil
                endBlock(at: depth)
            case "p", "figcaption", "dt", "dd":
                flushInline()
                if blockDepth == depth { endBlock(at: depth) }
            case "blockquote":
                flushInline()
                if quoteDepth == depth {
                    quoteDepth = nil
                    endBlock(at: depth)
                }
            case "ul", "ol":
                listDepth = max(0, listDepth - 1)
                if !orderedListStack.isEmpty { orderedListStack.removeLast() }
                flushInline()
                if blockDepth == depth { endBlock(at: depth) }
            case "li":
                flushInline()
            case "pre":
                flushInline()
                emitCodeBlock()
                endBlock(at: depth)
            case "tr":
                if let row = tableRow { tableRows?.append(row) }
                tableRow = nil
            case "td", "th":
                tableRow?.append((tableCell ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                tableCell = nil
            case "table":
                flushInline()
                emitTable()
                endBlock(at: depth)
            case "em", "i", "cite", "dfn":
                inline += "*"
            case "strong", "b":
                inline += "**"
            case "code", "kbd", "samp", "tt":
                if preText == nil { inline += "`" }
            case "s", "strike", "del":
                inline += "~~"
            case "div", "section", "article", "header", "footer", "aside", "main", "figure", "dl", "body":
                // Loose text directly inside a container is a paragraph.
                if blockDepth == nil { flushInline() }
            default:
                break
            }
        }

        /// Text nobody closed: a document that ends inside a bare container.
        func finish() {
            flushInline()
            if blockDepth != nil { endBlock(at: blockDepth ?? depth) }
        }

        private func localName(_ element: String) -> String {
            guard let colon = element.lastIndex(of: ":") else { return element.lowercased() }
            return String(element[element.index(after: colon)...]).lowercased()
        }

        private func languageHint(_ value: String?) -> String? {
            guard let value else { return nil }
            for token in value.split(separator: " ") {
                if token.hasPrefix("language-") { return String(token.dropFirst("language-".count)) }
                if token.hasPrefix("lang-") { return String(token.dropFirst("lang-".count)) }
            }
            return nil
        }

        // MARK: - Blocks

        private func startBlock(_ kind: EPUBChapterBlock.Kind) {
            guard blockDepth == nil else { return }
            blockDepth = depth
            blockKind = kind
            // One blank line separates blocks; the block starts after it.
            blockStartLine = lines.count + (lines.isEmpty ? 1 : 2)
            flow = ""
        }

        private func endBlock(at depth: Int) {
            guard blockDepth == depth, blockDepth != nil else { return }
            let body = flow.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                // The Markdown reader reports a fenced block from its first
                // code line: the opening fence is not part of the block start.
                let startLine = blockKind == .code ? blockStartLine + 1 : blockStartLine
                blocks.append(EPUBChapterBlock(markdownStartLine: startLine, kind: blockKind))
            }
            blockDepth = nil
            flow = ""
            quoteDepth = nil
        }

        private func flushInline() {
            guard !inline.isEmpty else { return }
            let text = inline
            inline = ""
            if blockDepth == nil {
                startBlock(.text)
                appendParagraph(text)
                endBlock(at: blockDepth ?? depth)
                return
            }
            // Consecutive list items are one CommonMark list, so they are one
            // block: a blank line between them would split it in two.
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let isListItem = listDepth > 0 && (trimmed.hasPrefix("- ") || trimmed.hasPrefix("1. "))
            appendParagraph(text, separator: isListItem ? "\n" : nil)
        }

        /// A quoted line keeps a multi-paragraph blockquote one CommonMark
        /// block, so a recorded block start stays a top-level block start.
        private var separator: String { quoteDepth != nil ? "\n>\n" : "\n\n" }

        private func appendParagraph(_ text: String, separator joined: String? = nil) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var body = trimmed
            if let headingLevel {
                body = String(repeating: "#", count: min(6, max(1, headingLevel))) + " " + body
            }
            if quoteDepth != nil {
                body = body
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }
                    .joined(separator: "\n")
            }
            if !flow.isEmpty { flow += joined ?? separator }
            flow += body
        }

        private func emitCodeBlock() {
            let code = (preText ?? "").replacingOccurrences(of: "\u{FEFF}", with: "")
            preText = nil
            let language = preLanguage ?? ""
            preLanguage = nil
            let fence = code.contains("```") ? "````" : "```"
            let body = code.trimmingCharacters(in: .newlines)
            appendParagraph(blockKind == .code ? "\(fence)\(language)\n\(body)\n\(fence)" : body)
        }

        private func emitTable() {
            let rows = (tableRows ?? []).filter { !$0.isEmpty }
            tableRows = nil
            guard !rows.isEmpty else { return }
            let columnCount = rows.map(\.count).max() ?? 1
            func line(_ cells: [String]) -> String {
                var padded = cells
                while padded.count < columnCount { padded.append("") }
                return "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|") }
                    .joined(separator: " | ") + " |"
            }
            var text = line(rows[0]) + "\n"
            text += "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |\n"
            for row in rows.dropFirst() { text += line(row) + "\n" }
            appendParagraph(text.trimmingCharacters(in: .newlines))
        }

        /// Escapes what CommonMark would otherwise read as structure.
        private func escape(_ text: String) -> String {
            var result = ""
            result.reserveCapacity(text.count)
            for character in text {
                switch character {
                case "\\", "`", "*", "_", "[", "]", "<", ">", "|":
                    result.append("\\")
                    result.append(character)
                default:
                    result.append(character)
                }
            }
            return result
        }
    }
}

extension String {
    /// Language tags whose script reads right to left.
    var isRightToLeftScript: Bool {
        let language = lowercased()
        return language.hasPrefix("ar") || language.hasPrefix("he")
            || language.hasPrefix("fa") || language.hasPrefix("ur")
            || language.hasPrefix("yi") || language.hasPrefix("ps")
            || language.hasPrefix("sd")
    }
}
