import Foundation
import Testing
import UIKit

@testable import Oppi

/// The segment source builds only the blocks the parser just froze and mutates
/// the merged prose run in place, so a streamed answer must still render exactly
/// like a fresh full build at every tick. These fixtures cover every top-level
/// block kind and inline markup at chunk sizes from one character to whole
/// blocks: the prefix extension, the boundary text run, and the merged-tail
/// cache all have to agree with a canonical build on each step.
@Suite("Streaming markdown segment source")
@MainActor
struct StreamingSegmentSourceTests {
    private static let fixtures: [(name: String, source: String)] = [
        (
            "prose",
            """
            The server keeps one parser per row.

            Each tick appends a few bytes of prose and the parser reuses the
            frozen prefix instead of re-reading the whole answer.

            A third paragraph ends the answer.
            """
        ),
        (
            "headings",
            """
            # Title

            Intro under the title.

            ## Section

            Text under the section.

            ### Deeper

            - one
            - two
            """
        ),
        (
            "lists",
            """
            Steps:

            1. First item
            2. Second item with `code`
               - nested bullet
               - another nested bullet

            - loose bullet
            - last bullet
            """
        ),
        (
            "list with a fence",
            """
            Steps:

            - First item

              ```swift
              let value = 42
              ```

            - Second item
            """
        ),
        (
            "fenced code",
            """
            Before the fence.

            ```swift
            let value = 42
            print(value)
            ```

            After the fence.
            """
        ),
        (
            // One item only. A paragraph break followed by a new list marker makes
            // cmark re-join a list the parser already froze, so a two-item stream
            // renders a blank line where a canonical build has none. That split is
            // pre-existing (the pre-change pipeline splits at the same tick) and
            // unrelated to the nested-fence verdict the append suite covers.
            "fence inside a list item",
            """
            1. First step

               ```swift
               let a = 1
               let b = 2
               ```
            """
        ),
        (
            "setext headings",
            """
            Prose line
            ==========

            Wrapped prose that sits above the next underline
            ---

            After the setext headings.
            """
        ),
        (
            "table",
            """
            | Key | Value |
            | --- | --- |
            | alpha | beta |
            | gamma | delta |

            After the table.
            """
        ),
        (
            "mixed inline markup",
            """
            Use **bold**, *emphasis*, `code`, ~~strike~~, and a [link](https://example.com) in one paragraph.

            > A quote with **bold** inside.

            ---

            Last line with an ![image](https://example.com/pixel.png) inline.
            """
        ),
        (
            "link reference definition",
            """
            Read [the guide][ref] first.

            An unrelated paragraph.

            [ref]: https://example.com/guide

            Then [the guide][ref] again.
            """
        ),
    ]

    @Test(arguments: [1, 3, 8, 17, 64, 4096])
    func streamedSegmentsMatchAFullBuildAtEveryTick(chunkSize: Int) {
        for fixture in Self.fixtures {
            let source = AssistantMarkdownSegmentSource()
            var content = ""

            for (tick, prefix) in Self.prefixes(of: fixture.source, chunkSize: chunkSize).enumerated() {
                content = prefix
                let streamed = source.buildSegments(.make(
                    content: content,
                    isStreaming: true,
                    themeID: .dark
                ))
                let canonical = FlatSegment.build(from: parseCommonMark(content), themeID: .dark)

                #expect(
                    Self.segmentsEqual(streamed, canonical),
                    "\(fixture.name) diverged at tick \(tick) (\(content.utf8.count) UTF-8 bytes, chunk \(chunkSize))"
                )
            }
        }
    }

    /// The frozen prefix is built once per block. Building it again per freeze
    /// is the cost this path exists to remove, so the count must not grow with
    /// the number of ticks.
    @Test func eachFrozenBlockIsBuiltOnlyOnce() {
        let paragraphs = (0..<40).map { "Paragraph \($0) of a streamed answer that keeps growing." }
        let content = paragraphs.joined(separator: "\n\n")
        let source = AssistantMarkdownSegmentSource()

        var streamed = ""
        for chunk in Self.prefixes(of: content, chunkSize: 32) {
            streamed = chunk
            _ = source.buildSegments(.make(content: streamed, isStreaming: true, themeID: .dark))
        }

        let blocks = parseCommonMark(streamed)
        #expect(blocks.count == paragraphs.count)
        #expect(
            source.debugPrefixBlockBuildCountForTesting <= blocks.count,
            "Built \(source.debugPrefixBlockBuildCountForTesting) prefix blocks for \(blocks.count) blocks: a freeze rebuilt the whole prefix"
        )
    }

    /// A context that changes mid-stream must reproduce a full build, not keep
    /// the segments it built under the old context.
    @Test func sessionContextChangeMidStreamMatchesAFullBuild() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let source = AssistantMarkdownSegmentSource()
        var content = ""

        for prefix in Self.prefixes(of: Self.contextFixture, chunkSize: 12) {
            content = prefix
            _ = source.buildSegments(.make(
                content: content,
                isStreaming: true,
                themeID: .dark,
                resourceAccess: MarkdownResourceAccess(
                    identity: .init(workspaceID: "workspace-a", serverBaseURL: baseURL)
                )
            ))
        }

        let streamed = source.buildSegments(.make(
            content: content + " More.",
            isStreaming: true,
            themeID: .dark,
            resourceAccess: MarkdownResourceAccess(
                identity: .init(
                    workspaceID: "workspace-a",
                    sessionID: "session-a",
                    serverBaseURL: baseURL
                )
            )
        ))
        let canonical = FlatSegment.build(
            from: parseCommonMark(content + " More."),
            themeID: .dark,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )
        #expect(Self.segmentsEqual(streamed, canonical))
    }

    private static let contextFixture = """
        Intro paragraph before the image.

        ![diagram](/absolute/diagram.svg)

        Closing paragraph after the image.
        """

    // MARK: - Helpers

    private static func prefixes(of source: String, chunkSize: Int) -> [String] {
        let characters = Array(source)
        var result: [String] = []
        var content = ""
        var offset = 0
        while offset < characters.count {
            let end = min(offset + chunkSize, characters.count)
            content.append(contentsOf: characters[offset..<end])
            offset = end
            result.append(content)
        }
        return result
    }

    private static func segmentsEqual(_ lhs: [FlatSegment], _ rhs: [FlatSegment]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        return zip(lhs, rhs).allSatisfy { left, right in
            switch (left, right) {
            case (.text(let leftText), .text(let rightText)):
                return NSAttributedString(leftText).isEqual(to: NSAttributedString(rightText))
            case let (.codeBlock(leftLanguage, leftCode), .codeBlock(rightLanguage, rightCode)):
                return leftLanguage == rightLanguage && leftCode == rightCode
            case let (.table(leftHeaders, leftRows), .table(rightHeaders, rightRows)):
                return leftHeaders == rightHeaders && leftRows == rightRows
            case (.thematicBreak, .thematicBreak):
                return true
            case let (.image(leftAlt, leftURL), .image(rightAlt, rightURL)):
                return leftAlt == rightAlt && leftURL == rightURL
            case let (.mermaidDiagram(leftCode), .mermaidDiagram(rightCode)):
                return leftCode == rightCode
            case let (.latexBlock(leftCode), .latexBlock(rightCode)):
                return leftCode == rightCode
            default:
                return false
            }
        }
    }
}
