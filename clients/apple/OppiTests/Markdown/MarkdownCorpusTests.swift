import Foundation
import Testing
import UIKit
@testable import Oppi

/// The Markdown golden corpus (`Fixtures/markdown-corpus/*.txt`): one source per
/// file with the parser's tree and the renderer's runs it must produce.
///
/// A file is a name line, optional `known-wrong:` notes for output that is
/// recorded as it is today but is not what Oppi should show, then sections:
///
///     @@@@ source
///     @@@@ tree      parseCommonMark, after the wiki-link rewrite
///     @@@@ render    FlatSegment.build, reduced to text runs and segments
///
/// Tests never write the files. Regenerate on purpose, then review the diff:
/// `clients/apple/scripts/markdown-corpus-update.sh`.
@MainActor
@Suite("Markdown golden corpus")
struct MarkdownCorpusTests {
    @Test(arguments: MarkdownCorpus.cases())
    func parserAndRendererMatchTheCorpus(_ entry: MarkdownCorpus.Case) throws {
        let actual = MarkdownCorpus.output(for: entry.source, isOrg: entry.isOrg)
        if let recordDirectory = ProcessInfo.processInfo.environment["OPPI_MARKDOWN_CORPUS_RECORD_DIR"] {
            try entry.recorded(actual).write(
                to: URL(filePath: recordDirectory).appending(path: entry.fileName),
                atomically: true,
                encoding: .utf8
            )
            return
        }
        #expect(actual.tree == entry.tree, "tree of \(entry.name)")
        #expect(actual.render == entry.render, "render of \(entry.name)")
    }

    /// The 71 audit cases (`m`, `n`, `o`) and the parity cases added after them (`p`).
    @Test func corpusHoldsEveryAuditCase() {
        #expect(MarkdownCorpus.cases().filter { !$0.fileName.hasPrefix("p") }.count == 71)
    }
}

enum MarkdownCorpus {
    struct Case: CustomTestStringConvertible, Sendable {
        let fileName: String
        let name: String
        let notes: [String]
        let source: String
        let tree: String?
        let render: String?

        var isOrg: Bool { name.hasPrefix("org:") }
        var testDescription: String { name }

        func recorded(_ output: Output) -> String {
            ([name] + notes).joined(separator: "\n")
                + "\n@@@@ source\n\(source)\n@@@@ tree\n\(output.tree)\n@@@@ render\n\(output.render)\n"
        }
    }

    struct Output {
        let tree: String
        let render: String
    }

    static func cases() -> [Case] {
        guard let directory = TestFixtures.bundle.resourceURL?.appending(path: "markdown-corpus"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else { return [] }
        return files.filter { $0.hasSuffix(".txt") }.sorted().compactMap { file in
            guard let raw = try? String(contentsOf: directory.appending(path: file), encoding: .utf8) else { return nil }
            return parse(raw, fileName: file)
        }
    }

    private static func parse(_ raw: String, fileName: String) -> Case? {
        guard let sourceMarker = raw.range(of: "@@@@ source\n") else { return nil }
        let header = raw[..<sourceMarker.lowerBound].split(separator: "\n").map(String.init)
        var body = String(raw[sourceMarker.upperBound...])
        var render: String?
        var tree: String?
        if let marker = body.range(of: "\n@@@@ render\n") {
            render = String(body[marker.upperBound...].dropLast())
            body = String(body[..<marker.lowerBound])
        }
        if let marker = body.range(of: "\n@@@@ tree\n") {
            tree = String(body[marker.upperBound...])
            body = String(body[..<marker.lowerBound])
        } else if body.hasSuffix("\n") {
            body.removeLast()
        }
        guard let name = header.first else { return nil }
        return Case(fileName: fileName, name: name, notes: Array(header.dropFirst()), source: body, tree: tree, render: render)
    }

    // MARK: - Output

    @MainActor
    static func output(for source: String, isOrg: Bool) -> Output {
        let markdown = isOrg
            ? MarkdownBlockSerializer.serialize(OrgToMarkdownConverter.convert(located: OrgParser().parseLocated(source)))
            : source
        let blocks = parseCommonMark(markdown)
        let rewritten = MarkdownWikiLinkRewriter.rewrite(
            blocks: blocks,
            serverID: "srv",
            workspaceID: "ws",
            sessionID: "s1",
            sourceDirectory: nil
        )
        var tree = rewritten.map { dump($0) }
        if isOrg { tree.insert("ORG→MD: " + oneLine(markdown), at: 0) }
        let segments = FlatSegment.build(
            from: blocks,
            serverID: "srv",
            workspaceID: "ws",
            sessionID: "s1",
            serverBaseURL: URL(string: "https://oppi.invalid")
        )
        return Output(
            tree: tree.joined(separator: "\n"),
            render: segments.map(dump).joined(separator: "\n")
        )
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "⏎")
    }

    // MARK: Tree

    static func dump(_ inline: MarkdownInline) -> String {
        switch inline {
        case .text(let s): "T(\(s))"
        case .emphasis(let c): "EM[\(c.map(dump).joined())]"
        case .strong(let c): "B[\(c.map(dump).joined())]"
        case .code(let s): "CODE(\(s))"
        case .link(let c, let destination): "LINK[\(c.map(dump).joined())→\(destination ?? "nil")]"
        case .image(let alt, let source, let size): "IMG(\(alt)→\(source ?? "nil")\(size.map { "|" + $0.markup } ?? ""))"
        case .videoEmbed(let e): "VIDEO(\(e.reference.target))"
        case .audioEmbed(let e): "AUDIO(\(e.reference.target))"
        case .usdzEmbed(let e): "USDZ(\(e.reference.target))"
        case .softBreak: "⏎"
        case .hardBreak: "⏎⏎"
        case .html(let s): "HTML(\(s))"
        case .strikethrough(let c): "S[\(c.map(dump).joined())]"
        case .styled(let style, let c): "\(style.tag.uppercased())[\(c.map(dump).joined())]"
        case .math(let math): (math.isDisplay ? "DMATH(" : "MATH(") + math.latex + ")"
        }
    }

    static func dump(_ block: MarkdownBlock, _ indent: String = "") -> String {
        func children(_ blocks: [MarkdownBlock]) -> String {
            blocks.map { dump($0, indent + "    ") }.joined(separator: "\n")
        }
        switch block {
        case .heading(let level, let inlines):
            return indent + "H\(level): " + inlines.map(dump).joined()
        case .paragraph(let inlines):
            return indent + "P: " + inlines.map(dump).joined()
        case .blockQuote(let blocks):
            return indent + "QUOTE\n" + blocks.map { dump($0, indent + "  ") }.joined(separator: "\n")
        case .codeBlock(let language, let code):
            return indent + "CODEBLOCK[\(language ?? "-")]: " + oneLine(code)
        case .unorderedList(let items), .orderedList(_, let items):
            let kind = if case .orderedList = block { "OL" } else { "UL" }
            return indent + kind + "\n" + items.map { "\(indent)  •\n" + children($0) }.joined(separator: "\n")
        case .taskList(let items):
            return indent + "TASKS\n" + items.map { "\(indent)  [\($0.checked ? "x" : " ")]\n" + children($0.content) }
                .joined(separator: "\n")
        case .thematicBreak:
            return indent + "HR"
        case .table(let headers, let rows, _):
            let cells = { (row: [[MarkdownInline]]) in row.map { $0.map(dump).joined() }.joined(separator: " ‖ ") }
            return indent + "TABLE\n\(indent)  hdr: " + cells(headers) + rows.map { "\n\(indent)  row: " + cells($0) }.joined()
        case .htmlBlock(let html):
            return indent + "HTMLBLOCK: " + oneLine(html)
        case .math(let math, let isClosed):
            return indent + "MATHBLOCK[\(isClosed ? "closed" : "open")]: " + oneLine(math.latex)
        }
    }

    // MARK: Render

    @MainActor
    static func dump(_ segment: FlatSegment) -> String {
        switch segment {
        case .text(let text): "TEXT: " + runs(
                NSAttributedString(text), fontTraits: false, palette: ThemeRuntimeState.currentThemeID().palette
            )
        case .codeBlock(let language, let code): "CODE[\(language ?? "-")]: " + oneLine(code)
        case .table(let headers, let rows, _): "TABLE\n  hdr: " + cells(headers, isHeader: true)
            + rows.map { "\n  row: " + cells($0, isHeader: false) }.joined()
        case .thematicBreak: "HR"
        case .image(let alt, let url, let size): "IMAGE(\(alt) → \(url.absoluteString)\(size.map { " |" + $0.markup } ?? ""))"
        case .video(let embed): "VIDEO(\(embed.reference.target))"
        case .audio(let embed): "AUDIO(\(embed.reference.target))"
        case .usdz(let embed): "USDZ(\(embed.reference.target))"
        case .mermaidDiagram(let code): "MERMAID: " + oneLine(code)
        case .geoJSONMap(let code, _): "MAP: " + oneLine(code)
        case .latexBlock(let code): "LATEX: " + oneLine(code)
        }
    }

    @MainActor
    private static func cells(_ row: [[MarkdownInline]], isHeader: Bool) -> String {
        row.map { cell in
            let text = NSMutableAttributedString()
            TableInlineText.appendCell(
                cell,
                to: text,
                fonts: .current,
                isHeader: isHeader,
                colors: .measuring,
                paragraph: .default
            )
            return runs(text, fontTraits: true, palette: TableInlineText.Colors.measuring.palette)
        }.joined(separator: " ‖ ")
    }

    /// Text with its inline styling as tags: `<b>`, `<i>`, `<s>`, `<u>`,
    /// `<sub>`, `<sup>`, `<code>`, `<kbd>`, `<mark>`, `<a>`; a formula as
    /// `⟦its spoken label⟧`, any other attachment as `◆`. Table cells carry
    /// emphasis in the font face, prose in the presentation intent (bold italic
    /// in its face); `palette`
    /// is the one the text was drawn in, which tells the fills apart.
    @MainActor
    private static func runs(_ text: NSAttributedString, fontTraits: Bool, palette: ThemePalette) -> String {
        var pieces: [(tags: [String], text: String)] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = (text.string as NSString).substring(with: range)
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let formula = attachment as? InlineLatexTextAttachment {
                    piece = "⟦" + (formula.accessibilityLabel ?? "")
                        .replacingOccurrences(of: "Math formula: ", with: "")
                        .replacingOccurrences(of: "Math formula source: ", with: "src:") + "⟧"
                } else {
                    piece = "◆"
                }
            }
            var tags: [String] = []
            if fontTraits {
                let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                if traits.contains(.traitBold) { tags.append("b") }
                if traits.contains(.traitItalic) || attributes[.obliqueness] != nil { tags.append("i") }
            } else if let raw = attributes[.inlinePresentationIntent] as? NSNumber {
                let intent = InlinePresentationIntent(rawValue: raw.uintValue)
                if intent.contains(.stronglyEmphasized) { tags.append("b") }
                if intent.contains(.emphasized) { tags.append("i") }
            } else if let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits,
                      traits.contains([.traitBold, .traitItalic]) {
                // Bold italic is a face of its own: UIKit would draw both intents upright.
                tags += ["b", "i"]
            }
            if attributes[.strikethroughStyle] != nil { tags.append("s") }
            if attributes[.underlineStyle] != nil, attributes[.link] == nil { tags.append("u") }
            if let offset = attributes[.baselineOffset] as? CGFloat, offset != 0 { tags.append(offset > 0 ? "sup" : "sub") }
            if let fill = attributes[.backgroundColor] as? UIColor {
                switch fill {
                case MarkdownInlineRenderer.keycapFill(palette): tags.append("kbd")
                case MarkdownInlineRenderer.highlightFill(palette): tags.append("mark")
                default: tags.append("code")
                }
            }
            if attributes[.link] != nil { tags.append("a") }
            if let last = pieces.last, last.tags == tags {
                pieces[pieces.count - 1].text += piece
            } else {
                pieces.append((tags, piece))
            }
        }
        return pieces.map { piece in
            piece.tags.map { "<\($0)>" }.joined() + oneLine(piece.text) + piece.tags.reversed().map { "</\($0)>" }.joined()
        }.joined()
    }
}
