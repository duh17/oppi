import Foundation
import SwiftUI
import Testing

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
        #expect(AskCard.usesInlineQuestionPreview("Pick an option", dynamicTypeSize: .large) == false)
    }

    @Test("Long inline questions use compact preview")
    func longInlineQuestionUsesPreview() {
        let question = (1...9).map { "Detail line \($0)" }.joined(separator: "\n")
        #expect(AskCard.usesInlineQuestionPreview(question, dynamicTypeSize: .large) == true)
    }

    @Test("Accessibility sizes keep a larger inline question preview")
    func accessibilityInlineQuestionPreviewLimit() {
        #expect(AskCard.inlineQuestionLineLimit(for: .accessibility1) > AskCard.inlineQuestionLineLimit(for: .large))
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

        let display = AskCard.inlineQuestionDisplay(for: question)

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

        let display = AskCard.inlineQuestionDisplay(for: question)

        #expect(display.summary == "Review this command before allowing it.")
        #expect(display.commandPreview == "npm test -- --runInBand")
    }

    @Test("Inline question display leaves ordinary questions unchanged")
    func inlineQuestionDisplayLeavesOrdinaryQuestionUnchanged() {
        let display = AskCard.inlineQuestionDisplay(for: "Pick an option")

        #expect(display.summary == "Pick an option")
        #expect(display.commandPreview == nil)
    }

    // MARK: - Option Row Density

    @Test("Inline and expanded option padding keeps wrapping text inside the rounded fill")
    func optionRowPaddingKeepsWrappingTextInsideRoundedFill() {
        let densities: [AskOptionChoiceRow.Density] = [.inline, .expanded]
        for density in densities {
            #expect(density.verticalPadding >= density.cornerRadius)
            #expect(density.horizontalPadding >= density.cornerRadius)
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

    // MARK: - Telemetry Tags

    @Test("Ask response telemetry tags are bounded and content-free")
    func askResponseTelemetryTagsAreBoundedAndContentFree() {
        let request = Self.multiQuestionRequest()
        let tags = AskCard.responseMetricTags(
            request: request,
            answers: [
                "approach": .single("unit"),
                "frameworks": .multi(["jest", "vitest"]),
            ],
            outcome: "answered",
            surface: "inline"
        )

        #expect(tags["outcome"] == "answered")
        #expect(tags["surface"] == "inline")
        #expect(tags["question_count"] == "2")
        #expect(tags["answered_count"] == "2")
        #expect(tags["ignored_count"] == "0")
        #expect(tags["multi_select"] == "1")
        #expect(tags["selected_count"] == "3")
        #expect(tags.values.contains("unit") == false)
        #expect(tags.values.contains("jest") == false)
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
