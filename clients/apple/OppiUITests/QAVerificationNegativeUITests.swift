import Foundation
import XCTest

/// Running-UI proof that the strict executor refuses false passes.
/// Hang-harness queue store is in-memory; this lane is not paired-server E2E.
@MainActor
final class QAVerificationNegativeUITests: UIHarnessTestCase {
    private let unusedPostcondition = QAVerificationExecutor.Confirmation.exists(
        .id("qa.verification.unused-postcondition", role: .staticText)
    )

    func testStrictRejectsThreeAmbiguousMoveControlsAndLeavesQueueUnchanged() throws {
        launchQueueHarness()
        enqueueSteer(times: 3)
        expandQueue()
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 3, timeout: 4), 3)

        try wrapNegative(
            journeyId: "negative-ambiguous-target",
            subject: "Three duplicate move controls fail closed; queue unchanged",
            stepIds: ["tap-move"],
            requiredAssertionIds: ["rejected-ambiguous-3-matches", "queue-unchanged"],
            innerStatus: .fail
        ) { _, executor in
            try executor.tap(
                QAVerificationExecutor.Target.id("arrow.down.right", role: .button),
                timeout: 4,
                stepId: "tap-move",
                confirming: unusedPostcondition
            )
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "rejected-ambiguous-3-matches",
                status: reason.contains("3 matches") ? .pass : .fail,
                expected: "Ambiguous target ... (3 matches)",
                observed: reason
            )
            let count = tryPollDiagnostic("diag.queueSteeringCount", timeout: 1) ?? -1
            outer.recordAssertion(
                name: "queue-unchanged",
                status: count == 3 ? .pass : .fail,
                expected: "steering count remains 3",
                observed: "\(count)"
            )
        }
    }

    func testStrictMissingMoveDoesNotChangeQueue() throws {
        launchQueueHarness()
        enqueueSteer(times: 1)
        expandQueue()
        XCTAssertEqual(waitForDiagnostic("diag.queueSteeringCount", equals: 1, timeout: 4), 1)

        try wrapNegative(
            journeyId: "negative-missing-target",
            subject: "Missing move identifier fails closed; queue unchanged",
            stepIds: ["tap-missing"],
            requiredAssertionIds: ["rejected-missing-target", "queue-unchanged"],
            innerStatus: .fail
        ) { _, executor in
            try executor.tap(
                QAVerificationExecutor.Target.id("chat.messageQueue.item.missing.moveToFollowUp", role: .button),
                timeout: 2,
                stepId: "tap-missing",
                confirming: unusedPostcondition
            )
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "rejected-missing-target",
                status: reason.contains("Missing unique target") ? .pass : .fail,
                expected: "Missing unique target ...",
                observed: reason
            )
            let count = tryPollDiagnostic("diag.queueSteeringCount", timeout: 1) ?? -1
            outer.recordAssertion(
                name: "queue-unchanged",
                status: count == 1 ? .pass : .fail,
                expected: "steering count remains 1",
                observed: "\(count)"
            )
        }
    }

    func testMissingScopeDoesNotFallBackToApp() throws {
        launchQueueHarness()
        enqueueSteer(times: 1)
        expandQueue()

        try wrapNegative(
            journeyId: "negative-missing-scope",
            subject: "Missing scope does not fall back to the app",
            stepIds: ["tap-scoped"],
            requiredAssertionIds: ["rejected-missing-scope"],
            innerStatus: .fail
        ) { _, executor in
            try executor.tap(
                QAVerificationExecutor.Target.id(
                    "chat.messageQueue.refresh",
                    role: .button,
                    scope: "qa.verification.missing-scope"
                ),
                timeout: 2,
                stepId: "tap-scoped",
                confirming: unusedPostcondition
            )
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "rejected-missing-scope",
                status: reason.contains("Missing unique scope") ? .pass : .fail,
                expected: "Missing unique scope qa.verification.missing-scope",
                observed: reason
            )
        }
    }

    func testAmbiguousScopeDoesNotFallBackToApp() throws {
        launchQueueHarness()
        enqueueSteer(times: 3)
        expandQueue()

        try wrapNegative(
            journeyId: "negative-ambiguous-scope",
            subject: "Ambiguous scope does not fall back to the app",
            stepIds: ["tap-scoped"],
            requiredAssertionIds: ["rejected-ambiguous-scope"],
            innerStatus: .fail
        ) { _, executor in
            try executor.tap(
                QAVerificationExecutor.Target.id(
                    "chat.messageQueue.refresh",
                    role: .button,
                    scope: "arrow.down.right"
                ),
                timeout: 2,
                stepId: "tap-scoped",
                confirming: unusedPostcondition
            )
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "rejected-ambiguous-scope",
                status: reason.contains("Ambiguous scope") ? .pass : .fail,
                expected: "Ambiguous scope arrow.down.right",
                observed: reason
            )
        }
    }

    func testAbsentPostconditionDoesNotPass() throws {
        launchQueueHarness()
        try wrapNegative(
            journeyId: "negative-absent-postcondition",
            subject: "Absent postcondition does not pass",
            stepIds: ["wait-phantom"],
            requiredAssertionIds: ["rejected-absent-postcondition"],
            innerStatus: .fail
        ) { _, executor in
            try executor.waitExists(
                QAVerificationExecutor.Target.id("qa.verification.never-present", role: .staticText),
                timeout: 1,
                stepId: "wait-phantom"
            )
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "rejected-absent-postcondition",
                status: reason.contains("Missing unique target") ? .pass : .fail,
                expected: "Missing unique target qa.verification.never-present",
                observed: reason
            )
        }
    }

    func testUnconfirmedDispatchRefusesAnotherMutation() throws {
        launchQueueHarness()
        enqueueSteer(times: 1)
        expandQueue()

        try wrapNegative(
            journeyId: "negative-uncertain-dispatch",
            subject: "Unconfirmed dispatch refuses another mutation",
            stepIds: ["tap-move", "tap-again"],
            requiredAssertionIds: ["refused-second-mutation"],
            innerStatus: .unknown
        ) { _, executor in
            try executor.tap(
                QAVerificationExecutor.Target.id("arrow.down.right", role: .button),
                timeout: 4,
                stepId: "tap-move",
                confirming: .gone(.id("arrow.down.right", role: .button))
            )
            try executor.tap(
                QAVerificationExecutor.Target.id("chat.messageQueue.refresh", role: .button),
                timeout: 2,
                stepId: "tap-again",
                confirming: unusedPostcondition
            )
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "refused-second-mutation",
                status: reason.contains("unconfirmed") ? .pass : .fail,
                expected: "Previous dispatch is unconfirmed; refusing another mutation",
                observed: reason
            )
        }
    }

    func testUnrelatedWaitDoesNotConfirmDispatch() throws {
        launchQueueHarness()
        enqueueSteer(times: 1)
        expandQueue()
        let refresh = QAVerificationExecutor.Target.id("chat.messageQueue.refresh", role: .button)

        try wrapNegative(
            journeyId: "negative-unrelated-wait",
            subject: "Unrelated or already-present wait does not confirm another mutation",
            stepIds: ["tap-move", "wait-unrelated-refresh", "tap-again"],
            requiredAssertionIds: ["refused-after-unrelated-wait"],
            innerStatus: .unknown
        ) { _, executor in
            try executor.tap(
                QAVerificationExecutor.Target.id("arrow.down.right", role: .button),
                timeout: 4,
                stepId: "tap-move",
                confirming: .exists(.id("arrow.up.left", role: .button))
            )
            try executor.waitExists(refresh, timeout: 2, stepId: "wait-unrelated-refresh")
            try executor.tap(
                refresh,
                timeout: 2,
                stepId: "tap-again",
                confirming: unusedPostcondition
            )
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "refused-after-unrelated-wait",
                status: reason.contains("unconfirmed") ? .pass : .fail,
                expected: "Previous dispatch is unconfirmed; refusing another mutation",
                observed: reason
            )
        }
    }

    func testEvidenceFailureIsUnknownNotPass() throws {
        launchQueueHarness()
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("qa-verify-blocked-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocked.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: blocked) }

        try wrapNegative(
            journeyId: "negative-evidence-unknown",
            subject: "Evidence collection failure is unknown, never pass",
            stepIds: ["capture-evidence"],
            requiredAssertionIds: ["evidence-unknown"],
            innerStatus: .unknown
        ) { _, executor in
            try executor.captureEvidence(name: "blocked", directory: blocked, stepId: "capture-evidence")
        } assertions: { outer, innerFile, error in
            let reason = innerFile.failingStep?.reason ?? error?.localizedDescription ?? ""
            outer.recordAssertion(
                name: "evidence-unknown",
                status: innerFile.status == .unknown && innerFile.collector.health == "failed" ? .pass : .fail,
                expected: "inner unknown with collector failed",
                observed: "status=\(innerFile.status.rawValue) collector=\(innerFile.collector.health) reason=\(reason)"
            )
        }
    }

    private func wrapNegative(
        journeyId: String,
        subject: String,
        stepIds: [String],
        requiredAssertionIds: [String],
        innerStatus: QAVerificationStatus,
        attempt: (QAVerificationReceipt, QAVerificationExecutor) throws -> Void,
        assertions: (QAVerificationReceipt, QAVerificationReceiptFile, Error?) -> Void
    ) throws {
        let inner = QAVerificationReceipt(
            journeyId: "\(journeyId).inner",
            subject: subject,
            driver: "strict",
            requestedStepIds: stepIds,
            requiredAssertionIds: [],
            mockedBoundaries: ["hang-harness-in-memory-queue"]
        )
        let executor = QAVerificationExecutor(app: app, receipt: inner)
        var attemptError: Error?
        do {
            try attempt(inner, executor)
        } catch {
            attemptError = error
        }
        let innerFile = inner.makeFile()
        XCTAssertEqual(innerFile.status, innerStatus, "Inner attempt must remain \(innerStatus.rawValue)")
        XCTAssertNotEqual(innerFile.status, QAVerificationStatus.pass)

        let outer = QAVerificationReceipt(
            journeyId: journeyId,
            subject: subject,
            driver: "strict",
            requestedStepIds: ["inner-attempt"],
            requiredAssertionIds: requiredAssertionIds,
            mockedBoundaries: ["hang-harness-in-memory-queue"]
        )
        outer.innerAttempt = QAVerificationInnerAttempt(
            status: innerFile.status,
            journeyId: innerFile.journeyId,
            collectorHealth: innerFile.collector.health,
            failingReason: innerFile.failingStep?.reason
        )
        let now = Date()
        outer.stepRecords.append(
            QAVerificationStep(
                id: "inner-attempt",
                index: 0,
                op: "wrap",
                target: journeyId,
                status: .pass,
                startedAt: QAVerificationISO8601.string(now),
                endedAt: QAVerificationISO8601.string(now),
                durationMs: 0,
                detail: innerFile.failingStep?.reason
            )
        )
        assertions(outer, innerFile, attemptError)
        writeReceipt(outer)
        let written = outer.makeFile()
        XCTAssertEqual(written.status, .pass, written.failingStep?.reason ?? "outer negative proof failed")
    }

    private func launchQueueHarness() {
        launchHarness(
            noStream: true,
            includeVisualFixtures: false,
            mixedContent: false,
            queueHarness: true
        )
    }

    private func enqueueSteer(times: Int) {
        let clear = app.descendants(matching: .any)["harness.queue.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 4))
        clear.tap()
        let enqueue = app.descendants(matching: .any)["harness.queue.enqueueSteer"]
        XCTAssertTrue(enqueue.waitForExistence(timeout: 4))
        for _ in 0..<times {
            enqueue.tap()
        }
    }

    private func expandQueue() {
        let toggle = app.descendants(matching: .any)["chat.messageQueue.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        toggle.tap()
        let refresh = app.descendants(matching: .any)["chat.messageQueue.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 4), "Queue editor did not expand")
    }

    private func writeReceipt(_ receipt: QAVerificationReceipt) {
        do {
            _ = try receipt.write()
        } catch {
            XCTFail("Could not write QA receipt: \(error)")
        }
    }
}
