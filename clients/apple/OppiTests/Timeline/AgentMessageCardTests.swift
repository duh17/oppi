import Testing
import UIKit

@testable import Oppi

/// The agent message card's fold: the plain-text preview a long report folds
/// into, and where a message stops fitting it. The row wiring around it is
/// drawn from these two answers, so they are what a test can pin down.
@Suite("AgentMessageCard")
@MainActor
struct AgentMessageCardTests {
    private let origin = MessageOrigin(
        kind: "session",
        sessionId: "child-session",
        name: "Review",
        intent: "report"
    )

    @Test func previewDropsHeadingMarkersAndKeepsTheirWords() {
        let preview = AgentMessageCard.previewText(forMarkdown: """
        ## Verdict

        The change is ready.

        ### Details
        - one fix
        * second fix
        """)

        #expect(!preview.contains("#"))
        #expect(preview.contains("Verdict"))
        #expect(preview.contains("Details"))
        #expect(preview.contains("\u{2022} one fix"))
        #expect(preview.contains("\u{2022} second fix"))
    }

    @Test func previewReadsTableCellsWithoutItsPipes() {
        let preview = AgentMessageCard.previewText(forMarkdown: """
        | Finding | Status |
        |---|---|
        | P2-1 stale summary | Fixed |
        | P3-1 rebuilt menu | Fixed |
        """)

        #expect(!preview.contains("|"))
        #expect(!preview.contains("---"))
        #expect(preview.contains("Finding \u{00B7} Status"))
        #expect(preview.contains("P2-1 stale summary \u{00B7} Fixed"))
    }

    @Test func proseThatHappensToContainAPipeIsNotATable() {
        let preview = AgentMessageCard.previewText(forMarkdown: "Run `grep a | sort` first.")
        #expect(!preview.contains("\u{00B7}"))
        #expect(preview.contains("grep a | sort"))
    }

    @Test func previewKeepsFencedCodeAndLinkText() {
        let preview = AgentMessageCard.previewText(forMarkdown: """
        Read [the plan](https://example.com/plan) first.

        ```swift
        let ready = true
        ```
        """)

        #expect(preview.contains("Read the plan first."))
        #expect(preview.contains("let ready = true"))
        #expect(!preview.contains("```"))
        #expect(!preview.contains("https://example.com/plan"))
    }

    @Test func previewCollapsesBlankRunsAndTrimsEnds() {
        let preview = AgentMessageCard.previewText(forMarkdown: "\n\nFirst.\n\n\n\nSecond.\n\n")
        #expect(preview == "First.\n\nSecond.")
    }

    @Test func messageThatFitsThePreviewShowsWholeWithoutAFold() {
        let width: CGFloat = 320
        let preview = AgentMessageCard.previewText(forMarkdown: "Verdict: correct.")
        #expect(!AgentMessageCard.canExpand(preview: preview, width: width, font: AppFont.messageBody))
    }

    @Test func messageTallerThanThePreviewCanExpand() {
        let width: CGFloat = 320
        let long = (1...12).map { "Line \($0) of the report." }.joined(separator: "\n")
        let preview = AgentMessageCard.previewText(forMarkdown: long)
        #expect(AgentMessageCard.canExpand(preview: preview, width: width, font: AppFont.messageBody))
    }

    @Test func shortLinesPastTheBudgetStillExpand() {
        // Four short lines do not fit three, however wide the card is.
        let preview = AgentMessageCard.previewText(forMarkdown: "One\nTwo\nThree\nFour")
        #expect(AgentMessageCard.canExpand(preview: preview, width: 2_000, font: AppFont.messageBody))
    }

    @Test func foldFollowsTheLineBudgetAndTheOpenedState() {
        let folded = AgentMessageCard(origin: origin, preview: "long", isExpanded: false, canExpand: true)
        let opened = AgentMessageCard(origin: origin, preview: "long", isExpanded: true, canExpand: true)
        let short = AgentMessageCard(origin: origin, preview: "short", isExpanded: false, canExpand: false)

        #expect(!folded.showsWholeMessage)
        #expect(opened.showsWholeMessage)
        #expect(short.showsWholeMessage)
    }

    @Test func identityNamesTheIntentAndFallsBackToAnotherSession() {
        #expect(AgentMessageCard.intentTitle("report") == "Report")
        #expect(AgentMessageCard.intentTitle("task") == "Task")
        #expect(AgentMessageCard.intentTitle("message") == "Message")
        #expect(AgentMessageCard.intentTitle("something-new") == "Message")
        #expect(AgentMessageCard.senderName(origin) == "Review")

        let named = MessageOrigin(kind: "session", sessionId: "s", name: "  ", intent: "task")
        #expect(AgentMessageCard.senderName(named) == "another session")
        #expect(AgentMessageCard.headerLabel(named) == "Task from another session")
    }
}
