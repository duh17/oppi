import Foundation
import Testing
import UIKit

@testable import Oppi

@Suite("AskCard")
@MainActor
struct AskCardTests {
    // MARK: - Test Fixtures

    private static func singleSelectRequest() -> AskRequest {
        AskRequest(
            id: "ask-1",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "approach",
                    question: "What testing approach?",
                    options: [
                        AskOption(value: "unit", label: "Unit tests", description: "Fast, isolated"),
                        AskOption(value: "integration", label: "Integration", description: "End-to-end"),
                        AskOption(value: "both", label: "Both", description: nil),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: true,
            timeout: nil
        )
    }

    private static func multiQuestionRequest() -> AskRequest {
        AskRequest(
            id: "ask-2",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "approach",
                    question: "Testing approach?",
                    options: [
                        AskOption(value: "unit", label: "Unit", description: nil),
                        AskOption(value: "integration", label: "Integration", description: nil),
                    ],
                    multiSelect: false
                ),
                AskQuestion(
                    id: "frameworks",
                    question: "Which frameworks?",
                    options: [
                        AskOption(value: "jest", label: "Jest", description: "Mature"),
                        AskOption(value: "vitest", label: "Vitest", description: "Fast"),
                        AskOption(value: "playwright", label: "Playwright", description: "E2E"),
                    ],
                    multiSelect: true
                ),
            ],
            allowCustom: true,
            timeout: 120_000
        )
    }

    private static func multiSelectOnlyRequest() -> AskRequest {
        AskRequest(
            id: "ask-3",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "features",
                    question: "Which features?",
                    options: [
                        AskOption(value: "a", label: "Feature A", description: nil),
                        AskOption(value: "b", label: "Feature B", description: nil),
                    ],
                    multiSelect: true
                ),
            ],
            allowCustom: false,
            timeout: nil
        )
    }

    // MARK: - Inline Preview

    @Test("Short inline questions do not use compact preview")
    func shortInlineQuestionDoesNotUsePreview() {
        #expect(AskCard.usesInlineQuestionPreview("Pick an option", contentSizeCategory: .large) == false)
    }

    @Test("Long inline questions use compact preview")
    func longInlineQuestionUsesPreview() {
        let question = (1...9).map { "Detail line \($0)" }.joined(separator: "\n")
        #expect(AskCard.usesInlineQuestionPreview(question, contentSizeCategory: .large) == true)
    }

    @Test("Accessibility sizes keep a larger inline question preview")
    func accessibilityInlineQuestionPreviewLimit() {
        #expect(AskCard.inlineQuestionLineLimit(for: .accessibilityMedium) > AskCard.inlineQuestionLineLimit(for: .large))
    }

    @Test("Inline question display extracts fenced command preview")
    func inlineQuestionDisplayExtractsFencedCommandPreview() {
        let question = """
        Git push

        Pushing writes to a remote repository.

        ### Command

        ```bash
        git push origin main
        ```
        """

        let display = AskCard.inlineQuestionDisplay(for: question, encoding: .ask)

        #expect(display.summary == "Git push\n\nPushing writes to a remote repository.")
        #expect(display.commandPreview == "git push origin main")
    }

    @Test("Inline question display extracts unfenced command preview")
    func inlineQuestionDisplayExtractsUnfencedCommandPreview() {
        let question = """
        Review this command before allowing it.

        ### Command

        npm test -- --runInBand

        Allow this tool call?
        """

        let display = AskCard.inlineQuestionDisplay(for: question, encoding: .ask)

        #expect(display.summary == "Review this command before allowing it.")
        #expect(display.commandPreview == "npm test -- --runInBand")
    }

    @Test("A Command heading inside a fenced block is content, not the Command section")
    func inlineQuestionDisplayIgnoresCommandHeadingInsideFence() {
        let question = """
        Create agent?

        **Instructions**
        ````text
        Be helpful.
        # Command
        Nothing is created; preview only.
        ````
        **Model** sonnet

        ## Command

        npm test
        """

        let display = AskCard.inlineQuestionDisplay(for: question, encoding: .ask)

        #expect(display.summary.contains("Nothing is created; preview only."))
        #expect(display.summary.contains("**Model** sonnet"))
        #expect(display.commandPreview == "npm test")

        let onlyInFence = AskCard.inlineQuestionDisplay(
            for: "Hi\n\n~~~diff\n+ a\n# Command\n+ b\n~~~\n**Model** x",
            encoding: .ask
        )
        #expect(onlyInFence.commandPreview == nil)
        #expect(onlyInFence.summary.contains("**Model** x"))
    }

    @Test("An extension request is shown whole: its # Command line is its own text")
    func inlineQuestionDisplayKeepsExtensionRequestWhole() throws {
        let request = ExtensionUIRequest(
            id: "ext-command",
            sessionId: "s1",
            method: "select",
            title: "Send a message to “Planning”?",
            options: ["Send Message", "Cancel"],
            message: "Message (22 characters)\n\n# Command\n\nDetails: POST /sessions/x1/command"
        )
        let ask = try #require(request.askRequest)
        #expect(ask.responseEncoding == .extensionSelect)

        let display = AskCard.inlineQuestionDisplay(
            for: try #require(ask.questions.first).question,
            encoding: ask.responseEncoding
        )

        #expect(display.commandPreview == nil)
        #expect(display.summary.contains("# Command"))
        #expect(display.summary.contains("Details: POST /sessions/x1/command"))
    }

    @Test("Inline question display leaves ordinary questions unchanged")
    func inlineQuestionDisplayLeavesOrdinaryQuestionUnchanged() {
        let display = AskCard.inlineQuestionDisplay(for: "Pick an option", encoding: .ask)

        #expect(display.summary == "Pick an option")
        #expect(display.commandPreview == nil)
    }

    @Test("A first plain paragraph leads as the title over a Markdown body")
    func inlineQuestionPartsSplitsTitleFromBody() {
        let parts = AskCard.inlineQuestionParts(for: """
        Change Agent \u{201C}QA reviewer\u{201D}?

        Instructions changed

        **Model** fable-5 \u{2192} sonnet-5-5
        """)

        #expect(parts.title == "Change Agent \u{201C}QA reviewer\u{201D}?")
        #expect(parts.body == "Instructions changed\n\n**Model** fable-5 \u{2192} sonnet-5-5")
    }

    @Test("A lone paragraph is only a title; block syntax up front leaves no title")
    func inlineQuestionPartsEdges() {
        #expect(AskCard.inlineQuestionParts(for: "Pick an option") == .init(title: "Pick an option", body: nil))
        #expect(AskCard.inlineQuestionParts(for: "Line one\nline two") == .init(title: "Line one\nline two", body: nil))
        for opening in ["- first item", "1. first item", "```diff", "> quoted", "## Heading", "| a | b |"] {
            let text = "\(opening)\n\nafter"
            #expect(AskCard.inlineQuestionParts(for: text) == .init(title: nil, body: text), "\(opening)")
        }
    }

    // MARK: - Folded Card Fit

    private static func controlReviewRequest(extraMessage: String = "") -> AskRequest {
        let request = ExtensionUIRequest(
            id: "control-review",
            sessionId: "session-1",
            method: "select",
            title: "Change Agent \u{201C}QA reviewer\u{201D}?",
            options: ["Apply Change", "Cancel"],
            message: """
            Instructions changed \u{00B7} Model fable-5 \u{2192} sonnet-5-5

            **Instructions**
            ```diff
            - Review carefully.
            + QA-APPLIED-YES
            ```
            **Model** fable-5 \u{2192} sonnet-5-5
            \(extraMessage)
            Details: PATCH /agents/KQdEFkKi \u{00B7} version 1
            """
        )
        return request.askRequest!
    }

    private static func foldedCard(_ request: AskRequest, maxHeight: CGFloat, width: CGFloat = 342) -> (AskCardView, height: CGFloat) {
        let card = AskCardView()
        card.maxHeight = maxHeight
        card.apply(AskCardViewState(
            request: request,
            page: 0,
            answers: [:],
            isSubmitted: false,
            responseFailed: false,
            colors: .placeholder,
            reduceMotion: true
        ))
        let height = card.preferredHeight(for: width)
        card.frame = CGRect(x: 0, y: 0, width: width, height: height)
        card.layoutIfNeeded()
        return (card, height)
    }

    @Test("A long message gives way so every option stays inside the folded card")
    func longMessageKeepsEveryOptionVisible() {
        let long = (1...40).map { "Field \($0): a value that adds a line to the message" }.joined(separator: "\n\n")
        let cap: CGFloat = ComposerInputMetrics.inlineAskCardMaxHeight
        let (card, height) = Self.foldedCard(Self.controlReviewRequest(extraMessage: long), maxHeight: cap)

        #expect(height <= cap + 0.5, "card \(height) exceeds its cap \(cap)")
        #expect(card.scrollView.contentSize.height <= card.scrollView.bounds.height + 0.5, "content scrolls: \(card.scrollView.contentSize.height) > \(card.scrollView.bounds.height)")
        let options = Self.views(in: card, identifierPrefix: "ask.option.")
        #expect(options.count == 2)
        for option in options {
            let frame = option.convert(option.bounds, to: card.scrollView)
            #expect(frame.maxY <= card.scrollView.bounds.height + 0.5, "\(option.accessibilityIdentifier ?? "") sits below the visible area")
        }
    }

    @Test("An extension title with a blank line and Markdown stays the title, verbatim")
    func extensionTitleStaysWholeAndPlain() throws {
        let title = "Change **Agent**?\n\n`QA reviewer` inherits"
        let request = try #require(ExtensionUIRequest(
            id: "titled", sessionId: "session-1", method: "select", title: title,
            options: ["Apply", "Cancel"], message: "**Body** line\n\n- one\n- two"
        ).askRequest)
        let question = try #require(request.questions.first)
        let parts = AskCard.inlineQuestionParts(for: question.question, title: question.title)

        #expect(parts.title == title)
        #expect(parts.titleIsVerbatim)
        #expect(parts.body == "**Body** line\n\n- one\n- two")

        let (card, _) = Self.foldedCard(request, maxHeight: 380)
        let labels = Self.labels(in: card).map { $0.attributedText?.string ?? $0.text ?? "" }
        #expect(labels.contains(title), "title text must render as plain text, Markdown characters intact")
    }

    @Test("A short message keeps its natural height")
    func shortMessageIsNotPadded() {
        let request = ExtensionUIRequest(
            id: "short", sessionId: "session-1", method: "confirm", title: "Delete the draft?", message: "This cannot be undone."
        ).askRequest!
        let (_, capped) = Self.foldedCard(request, maxHeight: ComposerInputMetrics.inlineAskCardMaxHeight)
        let (_, uncapped) = Self.foldedCard(request, maxHeight: .greatestFiniteMagnitude)

        #expect(capped == uncapped)
    }

    @Test("Diff blocks color added and removed lines with the theme's diff colors")
    func diffBlockUsesThemeDiffColors() throws {
        let themeID = ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        let markdown = "```diff\n--- a/file\n+++ b/file\n context\n- old line\n+ new line\n```"
        for compact in [false, true] {
            let view = AssistantMarkdownContentView()
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
            view.apply(configuration: .make(
                content: markdown,
                isStreaming: false,
                themeID: themeID,
                renderingMode: .export,
                compactCodeBlocks: compact
            ))
            view.layoutIfNeeded()
            let text = try #require(Self.views(in: view, identifierPrefix: "markdown.codeBlock.text").first as? UITextView)
            let attributed = text.attributedText ?? NSAttributedString()
            func color(ofLineStarting prefix: String) throws -> UIColor? {
                let range = try #require((attributed.string as NSString).range(of: prefix).location != NSNotFound
                    ? (attributed.string as NSString).range(of: prefix) : nil)
                return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
            }
            #expect(try color(ofLineStarting: "- old") == palette.toolDiffRemoved, "compact=\(compact)")
            #expect(try color(ofLineStarting: "+ new") == palette.toolDiffAdded, "compact=\(compact)")
            let header = Self.views(in: view, identifierPrefix: "markdown.codeBlock.language").first
            let headerHidden = header.map { label in
                sequence(first: label, next: { $0.superview }).contains { $0.isHidden }
            }
            #expect(headerHidden == compact, "compact=\(compact) header hidden")
        }
    }

    private static func views(in view: UIView, identifierPrefix: String) -> [UIView] {
        view.subviews.flatMap { subview -> [UIView] in
            let own = (subview.accessibilityIdentifier?.hasPrefix(identifierPrefix) == true) ? [subview] : []
            return own + views(in: subview, identifierPrefix: identifierPrefix)
        }
    }

    // MARK: - Option Row Sizing

    @Test("Long multi-line option titles and descriptions fit inside their row")
    func optionRowGrowsToFitLongTitleAndDescription() {
        let option = AskOption(
            value: "trackpad",
            label: "Space bar trackpad \u{2192} arrow keys (Recommended) for moving the shell cursor",
            description: "Long-press the space bar and slide: sends \u{2190}/\u{2192} (and \u{2191}/\u{2193}) to the shell, like moving the cursor in a text field, without lifting the finger."
        )
        for density in [AskOptionChoiceRowView.Density.inline, .expanded] {
            for isMultiSelect in [false, true] {
                let row = AskOptionChoiceRowView(density: density)
                row.apply(option: option, isSelected: true, isMultiSelect: isMultiSelect, colors: .placeholder)
                let width: CGFloat = 300
                let height = row.systemLayoutSizeFitting(
                    CGSize(width: width, height: 0),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
                row.frame = CGRect(x: 0, y: 0, width: width, height: height)
                row.layoutIfNeeded()
                let labels = Self.labels(in: row).filter { !$0.isHidden && !($0.text ?? "").isEmpty }
                #expect(labels.count == 2)
                for label in labels {
                    let frame = label.convert(label.bounds, to: row)
                    let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                    #expect(label.bounds.height >= needed - 0.5, "\(density) label clipped: \(label.bounds.height) < \(needed)")
                    #expect(frame.minY >= 0 && frame.maxY <= row.bounds.height, "\(density) label outside its row")
                }
            }
        }
    }

    private static func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { subview -> [UILabel] in
            (subview as? UILabel).map { [$0] } ?? labels(in: subview)
        }
    }

    // MARK: - Selection Mode

    @Test("Multi-select questions expose explicit selection mode hint")
    func multiSelectQuestionsExposeSelectionHint() {
        let request = Self.multiSelectOnlyRequest()
        let question = request.questions[0]
        #expect(AskCardShared.selectionModeHint(for: question) == "Select multiple")
    }

    @Test("Single-select questions do not expose multi-select hint")
    func singleSelectQuestionsDoNotExposeSelectionHint() {
        let request = Self.singleSelectRequest()
        let question = request.questions[0]
        #expect(AskCardShared.selectionModeHint(for: question) == nil)
    }

    // MARK: - Page Count

    @Test("Single question single-select skips pager — 1 page")
    func singleQuestionSingleSelectPageCount() {
        let request = Self.singleSelectRequest()
        #expect(AskCard.pageCount(for: request) == 1)
    }

    @Test("Multi-question has one page per question")
    func multiQuestionPageCount() {
        let request = Self.multiQuestionRequest()
        #expect(AskCard.pageCount(for: request) == 2)
    }

    @Test("Single question multi-select stays on one page")
    func singleMultiSelectPageCount() {
        let request = Self.multiSelectOnlyRequest()
        #expect(AskCard.pageCount(for: request) == 1)
    }

    @Test("Page clamp keeps a same-id shorter replacement in bounds")
    func pageClampKeepsSameIdShorterReplacementInBounds() {
        let short = Self.singleSelectRequest()
        #expect(AskCard.clampedPage(0, for: short) == 0)
        #expect(AskCard.clampedPage(2, for: short) == 0)
        #expect(AskCard.clampedPage(-1, for: short) == 0)

        let multi = Self.multiQuestionRequest()
        #expect(AskCard.clampedPage(0, for: multi) == 0)
        #expect(AskCard.clampedPage(1, for: multi) == 1)
        #expect(AskCard.clampedPage(4, for: multi) == 1)
    }

    // MARK: - Telemetry

    @Test("Ask response event counts answers and carries no question or answer text")
    func askResponseEventIsBoundedAndContentFree() {
        let request = Self.multiQuestionRequest()
        let event = AskCard.responseEvent(
            request: request,
            answers: [
                "approach": .single("unit"),
                "frameworks": .multi(["jest", "vitest"]),
            ],
            result: .answered,
            surface: "inline",
            durationMs: 1_500
        )

        #expect(event.fieldValues["questions"] == 2)
        #expect(event.fieldValues["answered"] == 2)
        #expect(event.fieldValues["ignored"] == 0)
        #expect(event.fieldValues["multi_select_questions"] == 1)
        #expect(event.fieldValues["selected"] == 3)
        #expect(event.tagValues["result"] == "answered")
        #expect(event.tagValues["surface"] == "inline")
        #expect(event.tagValues.values.contains("unit") == false)
        #expect(event.tagValues.values.contains("jest") == false)
    }

    @Test("An ignored card counts every question as ignored")
    func ignoredCardCountsEveryQuestion() {
        let event = AskCard.responseEvent(
            request: Self.multiQuestionRequest(),
            answers: [:],
            result: .ignored,
            surface: "expanded",
            durationMs: 100
        )

        #expect(event.fieldValues["answered"] == 0)
        #expect(event.fieldValues["ignored"] == 2)
        #expect(event.tagValues["result"] == "ignored")
    }

    // MARK: - Delayed auto-advance

    @Test("Delayed follow-through advances exactly once from the scheduled page")
    func delayedFollowThroughAdvancesOnce() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .ignoreCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 0

        controller.noteIdentity(requestID: "ask-multi", page: 0, questionIDs: ["q1", "q2"])
        let ticket = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-multi",
            page: 0
        ) {
            page += 1
        }

        #expect(page == 0)
        await completeWait(delay, ticket: ticket)
        let advanced = await waitForMainActorCondition(timeout: .milliseconds(300)) { page == 1 }
        #expect(advanced)
        #expect(page == 1)

        await completeWait(delay, ticket: ticket)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 1 }
        #expect(stayed)
    }

    @Test("Canceled auto-advance wait does not still execute after try?")
    func canceledWaitDoesNotAdvanceAfterTryQuestion() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .throwOnCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 0

        controller.noteIdentity(requestID: "ask-multi", page: 0, questionIDs: ["q1", "q2"])
        let ticket = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-multi",
            page: 0
        ) {
            page += 1
        }
        controller.invalidate()

        let settled = await waitForMainActorCondition(timeout: .milliseconds(300)) {
            !delay.isPending(ticket)
        }
        #expect(settled)
        #expect(page == 0)

        await completeWait(delay, ticket: ticket)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 0 }
        #expect(stayed)
    }

    @Test("Duplicate selections cannot skip a later question")
    func duplicateSelectionsCannotSkip() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .ignoreCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 0

        controller.noteIdentity(requestID: "ask-multi", page: 0, questionIDs: ["q1", "q2", "q3"])
        let first = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-multi",
            page: 0
        ) {
            if page < 2 { page += 1 }
        }
        let second = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-multi",
            page: 0
        ) {
            if page < 2 { page += 1 }
        }
        #expect(first != second)

        await completeWait(delay, ticket: first)
        await completeWait(delay, ticket: second)
        let advancedOnce = await waitForMainActorCondition(timeout: .milliseconds(300)) { page == 1 }
        #expect(advancedOnce)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 1 }
        #expect(stayed)
    }

    @Test("Newer Ignore page change is not overwritten by a pending auto-advance")
    func newerIgnoreWinsOverPendingAdvance() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .ignoreCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 0

        controller.noteIdentity(requestID: "ask-multi", page: 0, questionIDs: ["q1", "q2", "q3"])
        let ticket = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-multi",
            page: 0
        ) {
            page += 1
        }

        page = 1
        controller.noteIdentity(requestID: "ask-multi", page: 1, questionIDs: ["q1", "q2", "q3"])
        controller.invalidate()

        await completeWait(delay, ticket: ticket)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 1 }
        #expect(stayed)
    }

    @Test("Newer explicit page navigation is not overwritten by a pending auto-advance")
    func newerPageNavigationWinsOverPendingAdvance() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .ignoreCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 0

        controller.noteIdentity(requestID: "ask-multi", page: 0, questionIDs: ["q1", "q2", "q3"])
        let ticket = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-multi",
            page: 0
        ) {
            page += 1
        }

        page = 2
        controller.noteIdentity(requestID: "ask-multi", page: 2, questionIDs: ["q1", "q2", "q3"])
        controller.invalidate()

        await completeWait(delay, ticket: ticket)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 2 }
        #expect(stayed)
    }

    @Test("Request replacement cannot advance the new card")
    func requestReplacementCannotAdvanceNewCard() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .ignoreCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 0

        controller.noteIdentity(requestID: "ask-1", page: 0, questionIDs: ["q1", "q2"])
        let ticket = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-1",
            page: 0
        ) {
            page += 1
        }

        page = 0
        controller.noteIdentity(requestID: "ask-2", page: 0, questionIDs: ["n1"])
        controller.invalidate()

        await completeWait(delay, ticket: ticket)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 0 }
        #expect(stayed)
    }

    @Test("Stale follow-through is ignored even if cancellation is swallowed")
    func staleFollowThroughIgnoredWhenCancellationIsSwallowed() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .ignoreCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 0

        controller.noteIdentity(requestID: "ask-1", page: 0, questionIDs: ["q1", "q2"])
        let ticket = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-1",
            page: 0
        ) {
            page += 1
        }

        controller.noteIdentity(requestID: "ask-2", page: 0, questionIDs: ["n1"])
        await completeWait(delay, ticket: ticket)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 0 }
        #expect(stayed)
    }

    @Test("Same-id question list change blocks a pending auto-advance")
    func sameIdQuestionListChangeBlocksPendingAdvance() async {
        let delay = AskInlineAutoAdvanceManualWait(mode: .ignoreCancellation)
        let controller = AskInlineAutoAdvanceController(wait: { try await delay.wait($0) })
        var page = 2

        controller.noteIdentity(requestID: "ask-1", page: 2, questionIDs: ["q1", "q2", "q3"])
        let ticket = await scheduleWhenWaitIsReady(
            controller,
            delay: delay,
            requestID: "ask-1",
            page: 2
        ) {
            page += 1
        }

        controller.noteIdentity(requestID: "ask-1", page: 0, questionIDs: ["only"])
        await completeWait(delay, ticket: ticket)
        let stayed = await waitForMainActorConditionToStayTrue(for: .milliseconds(50)) { page == 2 }
        #expect(stayed)
        #expect(AskCard.clampedPage(page, for: Self.singleSelectRequest()) == 0)
    }
}

@MainActor
final class AskInlineAutoAdvanceManualWait {
    struct Ticket: Equatable {
        let id: UInt64
    }

    enum Mode {
        case ignoreCancellation
        case throwOnCancellation
    }

    let mode: Mode
    private var nextID: UInt64 = 0
    private var continuations: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private(set) var lastRegistered: Ticket?

    init(mode: Mode) {
        self.mode = mode
    }

    func isPending(_ ticket: Ticket) -> Bool {
        continuations[ticket.id] != nil
    }

    func wait(_ duration: Duration) async throws {
        _ = duration
        let ticket = Ticket(id: nextID)
        nextID += 1
        lastRegistered = ticket
        let throwOnCancel = mode == .throwOnCancellation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                continuations[ticket.id] = continuation
            }
        } onCancel: {
            guard throwOnCancel else { return }
            Task { @MainActor in
                self.fail(ticket)
            }
        }
    }

    func complete(_ ticket: Ticket) {
        guard let continuation = continuations.removeValue(forKey: ticket.id) else { return }
        continuation.resume(returning: ())
    }

    func fail(_ ticket: Ticket) {
        guard let continuation = continuations.removeValue(forKey: ticket.id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private func scheduleWhenWaitIsReady(
    _ controller: AskInlineAutoAdvanceController,
    delay: AskInlineAutoAdvanceManualWait,
    requestID: String,
    page: Int,
    advance: @escaping @MainActor () -> Void
) async -> AskInlineAutoAdvanceManualWait.Ticket {
    let previous = delay.lastRegistered
    controller.schedule(requestID: requestID, page: page, advance: advance)
    let started = await waitForMainActorCondition(timeout: .milliseconds(300)) {
        guard let latest = delay.lastRegistered, latest != previous else { return false }
        return delay.isPending(latest)
    }
    #expect(started, "Expected a new injected auto-advance wait to register")
    return delay.lastRegistered ?? AskInlineAutoAdvanceManualWait.Ticket(id: .max)
}

@MainActor
private func completeWait(
    _ delay: AskInlineAutoAdvanceManualWait,
    ticket: AskInlineAutoAdvanceManualWait.Ticket
) async {
    delay.complete(ticket)
}
