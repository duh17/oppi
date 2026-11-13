import Foundation
import Testing
@testable import Oppi

/// Wiki links and embeds as Obsidian and comrak read them, around cmark:
/// the body of `[[…]]` stays one literal, embeds take Obsidian's size, and an
/// embed in a table cell or heading becomes a link that opens it.
@Suite("Wiki links and embeds around cmark")
struct MarkdownWikiEmbedGlueTests {
    private static func blocks(_ source: String) -> [MarkdownBlock] {
        MarkdownWikiLinkRewriter.rewrite(blocks: parseCommonMark(source), workspaceID: "ws", sourceDirectory: nil)
    }

    private static func inlines(_ source: String) -> [MarkdownInline] {
        guard case .paragraph(let inlines)? = blocks(source).first else { return [] }
        return inlines
    }

    /// Each wiki link as `label→target`, with the text between them, in order.
    private static func reading(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text): text
            case .link(let children, let destination):
                "<" + plainText(from: children) + "→" + (destination.flatMap(URL.init(string:))
                    .flatMap(ResourceReferenceURL.parse)?.target ?? destination ?? "nil") + ">"
            case .emphasis(let children): "_" + reading(children) + "_"
            case .code(let code): "`" + code + "`"
            case .math(let math): "⟦" + math.latex + "⟧"
            default: "?"
            }
        }.joined()
    }

    @Test(arguments: [
        ("See [[*draft*]] and [[a__b__c.md]].", "See <*draft*→*draft*> and <a__b__c.md→a__b__c.md>."),
        ("See [[foo]] here.\n\n[foo]: https://example.com", "See <foo→foo> here."),
        ("*see [[a*b]]* and [[x_y_z|_label_]] with _em_", "_see <a*b→a*b>_ and <_label_→x_y_z> with _em_"),
        ("`[[c*d*]]` and $f([[g]])$ stay as written.", "`[[c*d*]]` and ⟦f([[g]])⟧ stay as written."),
        // Obsidian closes at the first `]]`; its label cannot hold `]]`.
        ("See [[docs/c.md|[c]]].", "See <[c→docs/c.md>]."),
    ])
    func wikiLinkBodyIsOneLiteral(source: String, expected: String) {
        #expect(Self.reading(Self.inlines(source)) == expected)
    }

    @Test func wikiLinkInTableCellKeepsEmphasisCharactersAndItsCell() throws {
        guard case .table(_, let rows)? = Self.blocks("| A | B |\n|---|---|\n| [[*a*\\|b]] | x |").first else {
            Issue.record("Expected a table")
            return
        }
        #expect(rows[0].count == 2)
        #expect(Self.reading(rows[0][0]) == "<b→*a*>")
    }

    @Test(arguments: [
        ("![[img/pic.png|300]]", "img/pic.png", MarkdownEmbedSize("300")),
        ("![[img/pic.png|Chart|120x80]]", "Chart", MarkdownEmbedSize("120x80")),
        ("![[img/pic.png|300px]]", "300px", nil),
        ("![[img/2024.png]]", "img/2024.png", nil),
        ("![250](img/b.png)", "", MarkdownEmbedSize("250")),
        ("![Logo|64](img/c.png)", "Logo", MarkdownEmbedSize("64")),
        ("![Year 2024](img/d.png)", "Year 2024", nil),
    ] as [(String, String, MarkdownEmbedSize?)])
    func embedTakesObsidianSizeFromItsLastPipePiece(source: String, alt: String, size: MarkdownEmbedSize?) throws {
        guard case .image(let parsedAlt, _, let parsedSize)? = Self.inlines(source).first else {
            Issue.record("Expected an image in \(source)")
            return
        }
        #expect(parsedAlt == alt)
        #expect(parsedSize == size)
    }

    @Test func embedSizeSurvivesMarkdownSerialization() {
        let image = MarkdownInline.image(alt: "Chart", source: "img/a.png", size: MarkdownEmbedSize("120x80"))
        let markdown = MarkdownBlockSerializer.serialize([.paragraph([image])])
        guard case .image(let alt, _, let size)? = Self.inlines(markdown).first else {
            Issue.record("Expected an image in \(markdown)")
            return
        }
        #expect(alt == "Chart")
        #expect(size == MarkdownEmbedSize("120x80"))
    }

    @Test func embedsInTableCellsAndHeadingsBecomeLinksThatOpenThem() {
        let blocks = Self.blocks("# Plot ![[img/p.png]]\n\n| Clip | Pic |\n|---|---|\n| ![[clips/a.mp4]] | ![alt](img/p.png) |")
        guard case .heading(_, let heading)? = blocks.first, case .table(_, let rows)? = blocks.last else {
            Issue.record("Expected a heading and a table")
            return
        }
        #expect(Self.reading(heading) == "Plot <img/p.png→img/p.png>")
        #expect(rows[0].map(Self.reading) == ["<clips/a.mp4→clips/a.mp4>", "<alt→img/p.png>"])
    }

    @Test func imagesInQuotesAndListsDrawAsImages() {
        let segments = FlatSegment.build(
            from: parseCommonMark("> ![[img/y.png|200]]\n\n- ![x](img/z.png)"),
            themeID: .dark,
            workspaceID: "ws",
            serverBaseURL: URL(string: "https://oppi.invalid")
        )
        let images = segments.compactMap { segment -> String? in
            guard case .image(_, let url, let size) = segment else { return nil }
            return url.lastPathComponent + (size.map { "|" + $0.markup } ?? "")
        }
        #expect(images == ["y.png|200", "z.png"])
    }

    /// The line break around a picture pulled out of a paragraph ends at the
    /// picture: the text after it starts on its own first line, not an empty one.
    @Test func textAroundAPromotedImageStartsWithoutABlankLine() {
        let segments = FlatSegment.build(
            from: parseCommonMark("> Before\n> ![[img/y.png]]\n> after the picture."),
            themeID: .dark,
            workspaceID: "ws",
            serverBaseURL: URL(string: "https://oppi.invalid")
        )
        let texts = segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return String(text.characters).trimmingCharacters(in: CharacterSet(charactersIn: "▎ "))
        }
        #expect(texts == ["Before", "after the picture."])
    }

    /// Org prose reaches the reader as Markdown; what goes out unescaped as
    /// math is what the parser reads as math.
    @Test func orgDollarsAndStarsStayProseThroughTheSerializer() {
        let markdown = MarkdownBlockSerializer.serialize([
            .paragraph([.text("Costs $5*2 or (2*$3) total and $x_1$ math, \\(a*b\\).")]),
        ])
        #expect(Self.reading(Self.inlines(markdown)) == "Costs $5*2 or (2*$3) total and ⟦x_1⟧ math, ⟦a*b⟧.")
    }

    @Test(arguments: ["300", "300x200", "1", "99999"])
    func sizeReadsWidthAndHeight(text: String) throws {
        let size = try #require(MarkdownEmbedSize(text))
        #expect(size.markup == text)
    }

    @Test(arguments: ["", "0", "x200", "300x", "300px", "3 00", "100000", "300x200x1", "-5"])
    func sizeRejectsAnythingElse(text: String) {
        #expect(MarkdownEmbedSize(text) == nil)
    }
}
