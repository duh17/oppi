import AppKit
import Foundation
import Testing
@testable import Oppi

@Suite("Mac markdown paint dispatch")
struct MacMarkdownPaintDispatchTests {
    @Test func mermaidFenceDispatchesToDiagramNotCodeListing() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: """
        ```mermaid
        graph TD
        A-->B
        ```
        """)

        let kind = try #require(kinds.first)
        guard case .mermaidDiagram(let code) = kind else {
            Issue.record("Expected mermaid diagram, got \(kinds)")
            return
        }
        #expect(code.contains("graph TD"))
        #expect(code.contains("A-->B"))
        #expect(!kinds.contains { if case .codeListing = $0 { return true }; return false })
    }

    @Test func mmdFenceAliasDispatchesToDiagram() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: """
        ```mmd
        sequenceDiagram
            A->>B: Hello
        ```
        """)

        let kind = try #require(kinds.first)
        guard case .mermaidDiagram(let code) = kind else {
            Issue.record("Expected mermaid diagram for mmd, got \(kinds)")
            return
        }
        #expect(code.contains("sequenceDiagram"))
        #expect(!kinds.contains { if case .codeListing = $0 { return true }; return false })
    }

    @Test(arguments: ["latex", "tex", "math"])
    func latexTexAndMathFencesDispatchToFormula(language: String) throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: """
        ```\(language)
        x = \\frac{1}{2}
        ```
        """)

        let kind = try #require(kinds.first)
        guard case .latexFormula(let code) = kind else {
            Issue.record("Expected latex formula for \(language), got \(kinds)")
            return
        }
        #expect(code.contains("\\frac"))
        #expect(!kinds.contains { if case .codeListing = $0 { return true }; return false })
    }

    @Test func swiftFenceStaysCodeListing() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: """
        ```swift
        let answer = 42
        ```
        """)

        let kind = try #require(kinds.first)
        guard case .codeListing(let language, let code) = kind else {
            Issue.record("Expected code listing, got \(kinds)")
            return
        }
        #expect(language == "swift")
        #expect(code.contains("let answer = 42"))
        #expect(!kinds.contains { if case .mermaidDiagram = $0 { return true }; return false })
        #expect(!kinds.contains { if case .latexFormula = $0 { return true }; return false })
    }

    @Test func dollarDisplayMathDispatchesToFormulaNotMonospace() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: """
        $$
        x = \\frac{1}{2}
        $$
        """)

        let kind = try #require(kinds.first { if case .latexFormula = $0 { return true }; return false })
        guard case .latexFormula(let code) = kind else {
            Issue.record("Expected display math formula, got \(kinds)")
            return
        }
        #expect(code.contains("\\frac"))
        #expect(!code.contains("$$"))
        #expect(!kinds.contains { if case .codeListing = $0 { return true }; return false })
        #expect(!kinds.contains { if case .prose = $0 { return true }; return false })
    }

    @Test func bracketDisplayMathDispatchesToFormula() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: #"""
        \[
        \text{hit_rate} = \frac{\text{cacheRead}}{\text{cacheRead} + \text{uncachedInput}}
        \]
        """#)

        let kind = try #require(kinds.first { if case .latexFormula = $0 { return true }; return false })
        guard case .latexFormula(let code) = kind else {
            Issue.record("Expected bracket display math, got \(kinds)")
            return
        }
        #expect(code.contains(#"\frac"#))
        #expect(!code.contains(#"\["#))
        #expect(!code.contains(#"\]"#))
    }

    @Test func markdownImageInlineDispatchesToImageNotAltTextOnly() throws {
        let source = "data:image/png;base64,iVBORw0KGgo="
        let kinds = MacMarkdownPaintDispatch.kinds(from: "![plot](\(source))")

        let kind = try #require(kinds.first { if case .image = $0 { return true }; return false })
        guard case .image(let alt, let imageSource, let workspaceID, let sessionID) = kind else {
            Issue.record("Expected image paint kind, got \(kinds)")
            return
        }
        #expect(alt == "plot")
        #expect(imageSource == source)
        #expect(workspaceID == nil)
        #expect(sessionID == nil)
    }

    @Test func relativeImageSourceDispatchesWithWorkspaceContext() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(
            from: "![plot](shots/a.png)",
            workspaceID: "ws-mac",
            sessionID: "sess-mac"
        )

        let kind = try #require(kinds.first { if case .image = $0 { return true }; return false })
        guard case .image(let alt, let imageSource, let workspaceID, let sessionID) = kind else {
            Issue.record("Expected relative image with workspace context, got \(kinds)")
            return
        }
        #expect(alt == "plot")
        #expect(imageSource == "shots/a.png")
        #expect(workspaceID == "ws-mac")
        #expect(sessionID == "sess-mac")
    }

    @Test func filePathDerivesSourceDirectoryWhenSourceDirectoryIsNil() {
        #expect(
            MacMarkdownPaintDispatch.resolvedSourceDirectory(nil, filePath: "docs/notes.md")
                == "docs"
        )
        #expect(
            MacMarkdownPaintDispatch.resolvedSourceDirectory(nil, filePath: "docs/nested/notes.md")
                == "docs/nested"
        )
        #expect(MacMarkdownPaintDispatch.resolvedSourceDirectory(nil, filePath: "notes.md") == nil)
        #expect(MacMarkdownPaintDispatch.resolvedSourceDirectory(nil, filePath: "./notes.md") == nil)
        #expect(
            MacMarkdownPaintDispatch.resolvedSourceDirectory("custom", filePath: "docs/notes.md")
                == "custom"
        )
        #expect(
            MacMarkdownPaintDispatch.resolvedSourceDirectory("  ", filePath: "docs/notes.md")
                == "docs"
        )
        #expect(MacMarkdownPaintDispatch.resolvedSourceDirectory(nil, filePath: nil) == nil)
    }

    @Test func nestedMarkdownRelativeImageResolvesAgainstFileDirectory() throws {
        let directory = MacMarkdownPaintDispatch.resolvedSourceDirectory(
            nil,
            filePath: "docs/notes.md"
        )
        #expect(
            MacMarkdownWorkspaceFileLoader.resolvedPath(
                "images/foo.png",
                sourceDirectory: directory
            ) == "docs/images/foo.png"
        )

        let kinds = MacMarkdownPaintDispatch.kinds(
            from: "![](images/foo.png)",
            workspaceID: "ws-1",
            sessionID: "sess-1",
            sourceDirectory: directory
        )
        let kind = try #require(kinds.first { if case .image = $0 { return true }; return false })
        guard case .image(_, let imageSource, let workspaceID, let sessionID) = kind else {
            Issue.record("Expected relative image, got \(kinds)")
            return
        }
        #expect(imageSource == "images/foo.png")
        #expect(workspaceID == "ws-1")
        #expect(sessionID == "sess-1")
        #expect(
            MacMarkdownWorkspaceFileLoader.resolvedPath(
                try #require(imageSource),
                sourceDirectory: directory
            ) == "docs/images/foo.png"
        )
    }

    @Test func nestedMarkdownRelativeFileLinkJoinsDerivedSourceDirectory() throws {
        let directory = MacMarkdownPaintDispatch.resolvedSourceDirectory(
            nil,
            filePath: "docs/notes.md"
        )
        let blocks = MacMarkdownPaintDispatch.parsedBlocks(
            from: "See [chart](images/foo.png)",
            workspaceID: "ws-1",
            sessionID: "sess-1",
            sourceDirectory: directory
        )
        let reference = try #require(firstResourceReference(in: blocks))
        #expect(reference.fileCandidatePath == "docs/images/foo.png")
        #expect(reference.target == "images/foo.png")
    }

    @Test func nestedWikiRelativeImageJoinsDerivedSourceDirectory() throws {
        let directory = MacMarkdownPaintDispatch.resolvedSourceDirectory(
            nil,
            filePath: "docs/notes.md"
        )
        let blocks = MacMarkdownPaintDispatch.parsedBlocks(
            from: "![[./images/foo.png]]",
            workspaceID: "ws-1",
            sessionID: "sess-1",
            sourceDirectory: directory
        )
        let reference = try #require(firstResourceReference(in: blocks))
        #expect(reference.fileCandidatePath == "docs/images/foo.png")
        #expect(reference.target == "./images/foo.png")
    }

    @Test func documentViewThreadsDerivedSourceDirectoryIntoParseAndImageLoad() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacMarkdownBlockViews.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("MacMarkdownPaintDispatch.resolvedSourceDirectory"))
        #expect(source.contains("sourceDirectory: resolvedSourceDirectory"))
    }

    @Test func wikiVideoRewriteFailsIfWorkspaceIDStaysNil() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(
            from: "![[demo.mp4]]",
            workspaceID: "ws-mac",
            sessionID: "sess-mac"
        )

        let kind = try #require(kinds.first { if case .video = $0 { return true }; return false })
        guard case .video(let embed) = kind else {
            Issue.record("Expected wiki video embed, got \(kinds)")
            return
        }
        #expect(embed.reference.workspaceID == "ws-mac")
        #expect(embed.reference.sourceSessionID == "sess-mac")
        #expect(embed.reference.fileCandidatePath == "demo.mp4")
        #expect(embed.reference.kind == .workspaceFile)
    }

    @Test func inlineDollarMathDispatchesToFormulaNotLeftoverCharacters() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: "See $x^2$ here")

        let kind = try #require(kinds.first { if case .latexFormula = $0 { return true }; return false })
        guard case .latexFormula(let code) = kind else {
            Issue.record("Expected inline dollar math formula, got \(kinds)")
            return
        }
        #expect(code == "x^2")
        #expect(!code.contains("$"))
        #expect(kinds.contains(.prose))
        #expect(!kinds.contains { if case .codeListing = $0 { return true }; return false })
    }

    @Test func inlineParenMathDispatchesToFormula() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: #"See \(x^2\) here"#)

        let kind = try #require(kinds.first { if case .latexFormula = $0 { return true }; return false })
        guard case .latexFormula(let code) = kind else {
            Issue.record("Expected inline paren math formula, got \(kinds)")
            return
        }
        #expect(code == "x^2")
        #expect(!code.contains(#"\("#))
        #expect(!code.contains(#"\)"#))
        #expect(kinds.contains(.prose))
    }

    @Test func videoEmbedInlineDispatchesToVideoNotDisplayLabel() throws {
        let embed = MarkdownVideoEmbed(reference: ResourceReference(
            target: "demo.mp4",
            sourceServerID: nil,
            workspaceID: nil,
            sourceSessionID: nil,
            fileCandidatePath: "/tmp/demo.mp4",
            kind: .workspaceFile
        ))
        let kinds = MacMarkdownPaintDispatch.kinds(from: [
            .paragraph([.videoEmbed(embed)]),
        ])

        #expect(kinds == [.video(embed)])
    }

    @Test func wikiVideoLinkRewritesToVideoEmbed() throws {
        let kinds = MacMarkdownPaintDispatch.kinds(from: "![[demo.mp4]]")

        let kind = try #require(kinds.first { if case .video = $0 { return true }; return false })
        guard case .video(let embed) = kind else {
            Issue.record("Expected wiki video embed, got \(kinds)")
            return
        }
        #expect(embed.displayLabel.contains("demo.mp4") || embed.filePath.contains("demo.mp4"))
    }

    @Test func gfmTableDispatchesToTableNotProse() throws {
        let markdown = """
        | Name | State |
        | --- | --- |
        | Parser | Shared |
        """
        let kinds = MacMarkdownPaintDispatch.kinds(from: markdown)

        let kind = try #require(kinds.first)
        guard case .table(let headers, let rows) = kind else {
            Issue.record("Expected table paint, got \(kinds)")
            return
        }
        #expect(headers.map { plainText(from: $0) } == ["Name", "State"])
        #expect(rows.map { $0.map { plainText(from: $0) } } == [["Parser", "Shared"]])
        #expect(kinds == [kind])
        #expect(!kinds.contains(.prose))
        #expect(!kinds.contains { if case .codeListing = $0 { return true }; return false })
        #expect(MacMarkdownPaintDispatch.hasStructuredPaint(from: markdown))
    }

    @Test func htmlBlockDispatchesToHTMLNotTableOrRawProse() throws {
        let markdown = "<div>not a gfm table</div>"
        let kinds = MacMarkdownPaintDispatch.kinds(from: markdown)

        let kind = try #require(kinds.first)
        guard case .html(let source) = kind else {
            Issue.record("Expected HTML paint, got \(kinds)")
            return
        }
        #expect(source.contains("<div>not a gfm table</div>"))
        #expect(kinds == [kind])
        #expect(!kinds.contains(.prose))
        #expect(!kinds.contains { if case .table = $0 { return true }; return false })
        #expect(MacMarkdownPaintDispatch.hasStructuredPaint(from: markdown))
    }

    @Test func svgHtmlBlockDispatchesToSVGNotTable() throws {
        let markdown = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\">\n<rect width=\"8\" height=\"8\"/>\n</svg>\n"
        let kinds = MacMarkdownPaintDispatch.kinds(from: markdown)

        let kind = try #require(kinds.first)
        guard case .svg(let source) = kind else {
            Issue.record("Expected SVG paint, got \(kinds)")
            return
        }
        #expect(source.contains("<svg"))
        #expect(!kinds.contains(.prose))
        #expect(!kinds.contains { if case .table = $0 { return true }; return false })
        #expect(MacMarkdownPaintDispatch.hasStructuredPaint(from: markdown))
        #expect(MacMarkdownPaintDispatch.isSVGImageSource("icon.svg"))
        #expect(MacMarkdownPaintDispatch.isSVGImageSource("data:image/svg+xml;base64,abc"))
        #expect(!MacMarkdownPaintDispatch.isSVGImageSource("photo.png"))
    }

    @Test func languageDetectMapsFenceAliases() {
        #expect(MacMarkdownPaintDispatch.codeBlockKind(language: "mermaid", code: "graph TD") == .mermaidDiagram(code: "graph TD"))
        #expect(MacMarkdownPaintDispatch.codeBlockKind(language: "mmd", code: "graph TD") == .mermaidDiagram(code: "graph TD"))
        #expect(MacMarkdownPaintDispatch.codeBlockKind(language: "latex", code: "x^2") == .latexFormula(code: "x^2"))
        #expect(MacMarkdownPaintDispatch.codeBlockKind(language: "tex", code: "x^2") == .latexFormula(code: "x^2"))
        #expect(MacMarkdownPaintDispatch.codeBlockKind(language: "math", code: "x^2") == .latexFormula(code: "x^2"))
        #expect(
            MacMarkdownPaintDispatch.codeBlockKind(language: "python", code: "print(1)")
                == .codeListing(language: "python", code: "print(1)")
        )
    }

    @MainActor
    @Test func userMessageImageDecodesNSImageFromBase64() throws {
        let png = try #require(Self.pngData(width: 2, height: 3))
        let attachment = ImageAttachment(data: png.base64EncodedString(), mimeType: "image/png")

        let image = try #require(MacMarkdownImageLoader.nsImage(from: attachment))
        #expect(image.size.width == 2)
        #expect(image.size.height == 3)
    }

    @Test func remoteHTTPSourcesRequireExplicitLoad() {
        #expect(MacMarkdownPaintDispatch.isRemoteHTTPSource("https://example.com/a.png"))
        #expect(MacMarkdownPaintDispatch.isRemoteHTTPSource("http://example.com/a.png"))
        #expect(!MacMarkdownPaintDispatch.isRemoteHTTPSource("file:///tmp/a.png"))
        #expect(!MacMarkdownPaintDispatch.isRemoteHTTPSource("data:image/png;base64,xx"))
        #expect(!MacMarkdownPaintDispatch.isRemoteHTTPSource("shots/a.png"))
        #expect(!MacMarkdownPaintDispatch.isRemoteHTTPSource(nil))
    }

    private static func pngData(width: Int, height: Int) -> Data? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        return bitmap?.representation(using: .png, properties: [:])
    }

    private func firstResourceReference(in blocks: [MarkdownBlock]) -> ResourceReference? {
        firstLinkDestination(in: blocks).flatMap { destination in
            URL(string: destination).flatMap(ResourceReferenceURL.parse)
        }
    }

    private func firstLinkDestination(in blocks: [MarkdownBlock]) -> String? {
        linkDestinations(in: blocks).first
    }

    private func linkDestinations(in blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap(linkDestinations(in:))
    }

    private func linkDestinations(in block: MarkdownBlock) -> [String] {
        switch block {
        case .heading(_, let inlines), .paragraph(let inlines):
            return linkDestinations(in: inlines)
        case .blockQuote(let children):
            return children.flatMap(linkDestinations(in:))
        case .unorderedList(let items), .orderedList(_, let items):
            return items.flatMap { $0.flatMap(linkDestinations(in:)) }
        case .taskList(let items):
            return items.flatMap { $0.content.flatMap(linkDestinations(in:)) }
        case .table(let headers, let rows):
            return headers.flatMap(linkDestinations(in:))
                + rows.flatMap { $0.flatMap(linkDestinations(in:)) }
        case .codeBlock, .thematicBreak, .htmlBlock:
            return []
        }
    }

    private func linkDestinations(in inlines: [MarkdownInline]) -> [String] {
        inlines.flatMap { inline -> [String] in
            switch inline {
            case .link(let children, let destination):
                return [destination].compactMap { $0 } + linkDestinations(in: children)
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                return linkDestinations(in: children)
            case .text, .code, .image, .videoEmbed, .audioEmbed, .softBreak, .hardBreak, .html:
                return []
            }
        }
    }
}
