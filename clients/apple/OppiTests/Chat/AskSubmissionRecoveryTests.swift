import SwiftUI
import Testing

@testable import Oppi

@Suite("Ask submission recovery")
@MainActor
struct AskSubmissionRecoveryTests {
    @Test func rapidMixedActionsForwardOnceAndSuccessStaysClosed() {
        let card = AskResponseSubmission()
        let composer = AskResponseSubmission()
        var callbacks: [AskResponseSubmission.Completion] = []
        var forwarded = 0
        let deliver: AskResponseSubmission.Delivery = { done in
            forwarded += 1
            callbacks.append(done)
        }
        for _ in 0..<3 {
            card.submit(requestID: "ask") { done in
                composer.submit(requestID: "ask", deliver: deliver, completion: done)
            }
            composer.submit(requestID: "ask", deliver: deliver)
        }
        #expect(forwarded == 1)
        #expect(card.phase == .inFlight("ask"))
        #expect(composer.phase == .inFlight("ask"))
        callbacks.first?(.completed)
        #expect(card.phase == .completed("ask"))
        #expect(composer.phase == .completed("ask"))
        card.submit(requestID: "ask", deliver: deliver)
        composer.submit(requestID: "ask", deliver: deliver)
        #expect(forwarded == 1)
    }

    @Test func confirmedFailureReleasesBothClaimsAndRetryCanSucceed() throws {
        let card = AskResponseSubmission()
        let composer = AskResponseSubmission()
        var callbacks: [AskResponseSubmission.Completion] = []
        var forwarded = 0
        func tap() {
            card.submit(requestID: "ask") { done in
                composer.submit(requestID: "ask", deliver: { delivered in
                    forwarded += 1
                    callbacks.append(delivered)
                }, completion: done)
            }
        }
        tap()
        callbacks[0](.retryableFailure)
        #expect(card.phase == .failed("ask"))
        #expect(composer.phase == .failed("ask"))
        #expect(!card.blocksResponse(to: "ask"))
        #expect(!composer.blocksResponse(to: "ask"))
        tap()
        tap()
        #expect(forwarded == 2)
        try #require(callbacks.count == 2)
        callbacks[1](.completed)
        tap()
        #expect(forwarded == 2)
        #expect(card.phase == .completed("ask"))
        #expect(composer.phase == .completed("ask"))
    }

    @Test func staleAttemptCompletionCannotReleaseRetry() throws {
        let submission = AskResponseSubmission()
        var callbacks: [AskResponseSubmission.Completion] = []
        let deliver: AskResponseSubmission.Delivery = { callbacks.append($0) }
        submission.submit(requestID: "ask", deliver: deliver)
        callbacks[0](.retryableFailure)
        submission.submit(requestID: "ask", deliver: deliver)
        callbacks[0](.completed)
        callbacks[0](.retryableFailure)
        #expect(submission.phase == .inFlight("ask"))
        try #require(callbacks.count == 2)
        callbacks[1](.completed)
        #expect(submission.phase == .completed("ask"))
    }

    @Test(arguments: [AskResponseSubmission.Result.completed, .retryableFailure])
    func replacementIgnoresOldCompletion(result: AskResponseSubmission.Result) {
        let card = AskResponseSubmission()
        let composer = AskResponseSubmission()
        var oldCompletion: AskResponseSubmission.Completion?
        card.submit(requestID: "old") { done in
            composer.submit(requestID: "old", deliver: { oldCompletion = $0 }, completion: done)
        }
        card.applyRequestIDChange("new")
        composer.applyRequestIDChange("new")
        card.submit(requestID: "new") { done in
            composer.submit(requestID: "new", deliver: { _ in }, completion: done)
        }
        oldCompletion?(result)
        #expect(card.phase == .inFlight("new"))
        #expect(composer.phase == .inFlight("new"))
    }

    @Test func staleActionAfterRequestReplacementCannotClaimTheNewRequest() {
        let submission = AskResponseSubmission()
        submission.submit(requestID: "old") { _ in }
        submission.applyRequestIDChange("new")
        submission.submit(requestID: "old") { _ in Issue.record("Stale action must not deliver") }
        #expect(submission.phase == .idle)
        submission.submit(requestID: "new") { _ in }
        submission.submit(requestID: "old") { _ in Issue.record("Stale action must not replace new flight") }
        #expect(submission.phase == .inFlight("new"))
    }

    @Test func composerFirstThenCardTapSharesFailureAndReleasesBoth() {
        let card = AskResponseSubmission()
        let composer = AskResponseSubmission()
        var done: AskResponseSubmission.Completion?
        var forwarded = 0
        composer.submit(requestID: "ask") { done = $0; forwarded += 1 }
        card.submit(requestID: "ask") { complete in
            composer.submit(requestID: "ask", deliver: { _ in forwarded += 1 }, completion: complete)
        }
        #expect(forwarded == 1)
        done?(.retryableFailure)
        #expect(card.phase == .failed("ask"))
        #expect(composer.phase == .failed("ask"))
    }

    @Test func transportFailureReconcilesBeforeReleasingBothClaimsAndRetrySucceeds() async {
        let card = AskResponseSubmission()
        let composer = AskResponseSubmission()
        var done: AskResponseSubmission.Completion?
        func tap() {
            card.submit(requestID: "ask") { complete in
                composer.submit(requestID: "ask", deliver: { done = $0 }, completion: complete)
            }
        }
        tap()
        var events: [String] = []
        let failure = await ChatView.deliverAskResponse(
            send: { events.append("send"); throw DeliveryFailure.offline },
            reconcile: {
                events.append("reconcile")
                #expect(card.phase == .inFlight("ask"))
                #expect(composer.phase == .inFlight("ask"))
            },
            isPending: { events.append("pending"); return true },
            showFailure: { _ in events.append("failure") }
        )
        done?(failure)
        #expect(events == ["send", "reconcile", "pending", "failure"])
        #expect(card.phase == .failed("ask"))
        #expect(composer.phase == .failed("ask"))
        tap()
        let success = await ChatView.deliverAskResponse(
            send: { events.append("retry") },
            reconcile: { Issue.record("Success must not hydrate dialogs") },
            isPending: { true },
            showFailure: { _ in Issue.record("Success must not show a failure") }
        )
        done?(success)
        #expect(card.phase == .completed("ask"))
        #expect(composer.phase == .completed("ask"))
        #expect(events.last == "retry")
    }

    @Test func lostAcknowledgementWithSettledSnapshotDoesNotOfferRetry() async {
        let submission = AskResponseSubmission()
        var done: AskResponseSubmission.Completion?
        var pending = true
        submission.submit(requestID: "ask") { done = $0 }
        let result = await ChatView.deliverAskResponse(
            send: { throw DeliveryFailure.offline },
            reconcile: { pending = false },
            isPending: { pending },
            showFailure: { _ in Issue.record("Settled requests are not retryable failures") }
        )
        done?(result)
        #expect(submission.phase == .completed("ask"))
        submission.submit(requestID: "ask") { _ in Issue.record("Must not send again") }
    }

    @Test func unavailableReconciliationKeepsSameIdentityRetryable() async {
        let result = await ChatView.deliverAskResponse(
            send: { throw DeliveryFailure.offline },
            reconcile: { /* Existing hydration leaves the pending projection unchanged on failure. */ },
            isPending: { true },
            showFailure: { _ in }
        )
        #expect(result == .retryableFailure)
    }

    private enum DeliveryFailure: Error { case offline }

    @Test func settlementBeforeFailureDoesNotRearmMountedRequest() {
        let submission = AskResponseSubmission()
        var done: AskResponseSubmission.Completion?
        submission.submit(requestID: "ask") { done = $0 }
        submission.applyRequestIDChange(nil)
        done?(.retryableFailure)
        #expect(submission.phase == .completed("ask"))
        #expect(submission.blocksResponse(to: "ask"))
    }

    @Test func failureRestoresCustomDraftAndPreservesPage() {
        var state = AskComposerClearingState(currentPage: 1, draftAnswers: ["q": .custom("keep this")])
        let request = AskRequest(id: "ask", sessionId: "s", questions: [
            AskQuestion(id: "first", question: "First", options: [], multiSelect: false),
            AskQuestion(id: "q", question: "Last", options: [], multiSelect: false),
        ], allowCustom: true, timeout: nil)
        var done: AskResponseSubmission.Completion?
        state.submission.submit(requestID: request.id) { done = $0 }
        #expect(state.submittedRequestID == request.id)
        done?(.retryableFailure)
        #expect(state.submittedRequestID == nil)
        #expect(state.currentPage == 1)
        #expect(ChatInputBar<EmptyView>.composerTextForActiveAskQuestion(
            request: request, activeQuestionID: "q", draftAnswers: state.draftAnswers,
            keepComposerClearedForSubmittedRequestID: state.submittedRequestID
        ) == "keep this")
        state.applyRequestIDChange("next")
        #expect(state.draftAnswers.isEmpty)
    }
}
