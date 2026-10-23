import Testing
import UIKit

@testable import Oppi

/// The agent message card's fold: the plain-text preview a long report folds
/// into, and where a message stops fitting it. The row wiring around it is
/// drawn from these two answers, so they are what a test can pin down.
@Suite("AgentMessageCard")
@MainActor
struct AgentMessageCardTests {
    @Test func previewDropsHeadingMarkersAndKeepsTheirWords() {
        let preview = AgentMessageCard.preview(forMarkdown: """
        ## Verdict

        The change is ready.

        ### Details
        - one fix
        * second fix
        """).text

        #expect(!preview.contains("#"))
        #expect(preview.contains("Verdict"))
        #expect(preview.contains("Details"))
        #expect(preview.contains("\u{2022} one fix"))
        #expect(preview.contains("\u{2022} second fix"))
    }

    @Test func previewReadsTableCellsWithoutItsPipes() {
        let preview = AgentMessageCard.preview(forMarkdown: """
        | Finding | Status |
        |---|---|
        | P2-1 stale summary | Fixed |
        | P3-1 rebuilt menu | Fixed |
        """).text

        #expect(!preview.contains("|"))
        #expect(!preview.contains("---"))
        #expect(preview.contains("Finding \u{00B7} Status"))
        #expect(preview.contains("P2-1 stale summary \u{00B7} Fixed"))
    }

    @Test func proseThatHappensToContainAPipeIsNotATable() {
        let preview = AgentMessageCard.preview(forMarkdown: "Run `grep a | sort` first.").text
        #expect(!preview.contains("\u{00B7}"))
        #expect(preview.contains("grep a | sort"))
    }

    @Test func previewKeepsFencedCodeAndLinkText() {
        let preview = AgentMessageCard.preview(forMarkdown: """
        Read [the plan](https://example.com/plan) first.

        ```swift
        let ready = true
        ```
        """).text

        #expect(preview.contains("Read the plan first."))
        #expect(preview.contains("let ready = true"))
        #expect(!preview.contains("```"))
        #expect(!preview.contains("https://example.com/plan"))
    }

    @Test func previewJoinsBlocksWithoutBlankLines() {
        let preview = AgentMessageCard.preview(forMarkdown: "\n\nFirst.\n\n\n\nSecond.\n\n").text
        #expect(preview == "First.\nSecond.")
    }

    @Test func previewStopsReadingALongReport() {
        // A 127 KB report is one configure away from being read in full; the cap
        // keeps the fold and the label bounded and says the message is long.
        let report = (1...4_000).map { "Line \($0) of a very long report." }.joined(separator: "\n")
        let preview = AgentMessageCard.preview(forMarkdown: report)

        #expect(preview.isTruncated)
        #expect(preview.text.count <= AgentMessageCard.previewCharacterCap)
        #expect(preview.text.components(separatedBy: "\n").count <= AgentMessageCard.previewLineCap)
        #expect(!preview.text.isEmpty)
    }

    @Test func messageThatFitsThePreviewShowsWholeWithoutAFold() {
        let width: CGFloat = 320
        let preview = AgentMessageCard.preview(forMarkdown: "Verdict: correct.").text
        #expect(!AgentMessageCard.canExpand(preview: preview, width: width, font: AppFont.messageBody))
    }

    @Test func messageTallerThanThePreviewCanExpand() {
        let width: CGFloat = 320
        let long = (1...12).map { "Line \($0) of the report." }.joined(separator: "\n")
        let preview = AgentMessageCard.preview(forMarkdown: long).text
        #expect(AgentMessageCard.canExpand(preview: preview, width: width, font: AppFont.messageBody))
    }

    @Test func shortLinesPastTheBudgetStillExpand() {
        // Four short lines do not fit three, however wide the card is.
        let preview = AgentMessageCard.preview(forMarkdown: "One\nTwo\nThree\nFour").text
        #expect(AgentMessageCard.canExpand(preview: preview, width: 2_000, font: AppFont.messageBody))
    }
}
