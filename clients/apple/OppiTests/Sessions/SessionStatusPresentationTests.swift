import Foundation
import Testing
@testable import Oppi

/// The outcome began at `outcomeSince`; a device that last saw the session before it has not seen it.
private let outcomeSince = Date(timeIntervalSince1970: 1_000)
private let seenBefore = Date(timeIntervalSince1970: 500)
private let seenAfter = Date(timeIntervalSince1970: 1_500)

@Suite("SessionStatusKind")
struct SessionStatusPresentationTests {

    /// A session that has had a conversation, so it is not a blank draft.
    private func session(
        _ lifecycle: SessionStatus,
        program: ProgramStatus? = nil,
        messageCount: Int = 3
    ) -> Session {
        makeTestSession(
            status: lifecycle,
            lastActivity: outcomeSince,
            programStatus: program,
            messageCount: messageCount,
            firstMessage: messageCount > 0 ? "hello" : nil
        )
    }

    private func program(
        _ state: ProgramStatusState,
        kind: ProgramStatusKind? = nil
    ) -> ProgramStatus {
        ProgramStatus(state: state, kind: kind, since: outcomeSince)
    }

    // MARK: Program status

    @Test(arguments: [
        (ProgramStatusKind.permission as ProgramStatusKind?, SessionStatusKind.needsApproval),
        (.question, .question),
        (.auth, .signIn),
        (.unknown("device-flow"), .question),
        (nil, .question),
    ])
    func blockedKindsSplitAndUnknownKindsReadAsQuestion(
        kind: ProgramStatusKind?,
        expected: SessionStatusKind
    ) {
        for lifecycle in [SessionStatus.busy, .ready] {
            let status = SessionStatusKind.resolve(
                session: session(lifecycle, program: program(.blocked, kind: kind)),
                seenAt: seenAfter
            )
            #expect(status == expected)
            #expect(status.isBlocked)
        }
    }

    @Test(arguments: [
        // done and error show only while unseen; once seen they are Idle, or Stopped for a stopped session.
        (ProgramStatusState.done, SessionStatus.ready, Date?.some(seenBefore), SessionStatusKind.done),
        (.done, .ready, seenAfter, .idle),
        (.done, .ready, nil, .done),
        (.done, .stopped, seenBefore, .done),
        (.done, .stopped, seenAfter, .stopped),
        (.error, .ready, seenBefore, .error),
        (.error, .ready, seenAfter, .idle),
        (.error, .error, seenBefore, .error),
        (.error, .error, seenAfter, .idle),
        (.error, .stopped, seenBefore, .error),
        (.error, .stopped, seenAfter, .stopped),
        // idle is at rest whatever was seen.
        (.idle, .ready, seenBefore, .idle),
        (.idle, .stopped, seenBefore, .stopped),
        // working follows the program through stopping; a busy session with a stale outcome is still working.
        (.working, .busy, seenAfter, .working),
        (.working, .starting, seenAfter, .working),
        (.working, .stopping, seenAfter, .working),
        (.done, .busy, seenBefore, .working),
        (.error, .busy, seenBefore, .working),
        (.idle, .busy, seenBefore, .working),
    ])
    func outcomeShowsWhileUnseen(
        state: ProgramStatusState,
        lifecycle: SessionStatus,
        seenAt: Date?,
        expected: SessionStatusKind
    ) {
        #expect(SessionStatusKind.resolve(session: session(lifecycle, program: program(state)), seenAt: seenAt) == expected)
    }

    @Test func outcomeSeenExactlyAtItsStartIsSeen() {
        let done = session(.ready, program: program(.done))
        #expect(SessionStatusKind.resolve(session: done, seenAt: outcomeSince) == .idle)
        #expect(SessionStatusKind.resolve(session: done, seenAt: outcomeSince.addingTimeInterval(-0.001)) == .done)
    }

    @Test func aBlankDraftThatIsStartingStaysIdleDespiteAPriorOutcome() {
        let draft = session(.starting, program: program(.idle), messageCount: 0)
        #expect(SessionStatusKind.resolve(session: draft, seenAt: nil) == .idle)
    }

    @Test(arguments: [SessionStatus.ready, .error])
    func workingOnASettledSessionIsAStaleLocalHint(lifecycle: SessionStatus) {
        // A local agent_settled update flips lifecycle before the server's summary arrives.
        let status = SessionStatusKind.resolve(
            session: session(lifecycle, program: program(.working)),
            seenAt: seenAfter
        )
        #expect(status != .working)
    }

    @Test func aStoppedSessionIsNeverWorkingOrBlocked() {
        for state in [ProgramStatusState.working, .blocked] {
            let stopped = session(.stopped, program: program(state, kind: .permission))
            #expect(SessionStatusKind.resolve(session: stopped, seenAt: nil) == .stopped)
        }
    }

    @Test func aFailedLifecycleKeepsReadingAsErrorUnlessTheProgramIsBlocked() {
        #expect(SessionStatusKind.resolve(session: session(.error, program: program(.done)), seenAt: seenBefore) == .error)
        #expect(
            SessionStatusKind.resolve(
                session: session(.error, program: program(.blocked, kind: .auth)),
                seenAt: seenBefore
            ) == .signIn
        )
    }

    // MARK: Unknown and missing program status

    @Test(arguments: [
        (SessionStatus.busy, SessionStatusKind.working),
        (.starting, .working),
        (.ready, .done),
        (.stopped, .stopped),
        (.error, .error),
    ])
    func unknownFutureStateDerivesFromLifecycle(lifecycle: SessionStatus, expected: SessionStatusKind) {
        let unknown = ProgramStatus(state: .unknown("paused"), since: outcomeSince)
        #expect(SessionStatusKind.resolve(session: session(lifecycle, program: unknown), seenAt: nil) == expected)
    }

    @Test(arguments: [
        (SessionStatus.busy, 0, Date?.some(seenBefore), SessionStatusKind.working),
        (.starting, 0, seenBefore, .working),
        // Terminate broadcasts stopping for sessions that were not in a turn.
        (.stopping, 0, seenBefore, .idle),
        (.ready, 0, seenBefore, .done),
        (.ready, 0, nil, .done),
        (.ready, 0, seenAfter, .idle),
        (.stopped, 0, seenBefore, .stopped),
        (.error, 0, seenBefore, .error),
        (.error, 0, seenAfter, .idle),
        // Pending asks lead the way they do today, over any lifecycle.
        (.ready, 1, seenAfter, .question),
        (.busy, 2, seenBefore, .question),
    ])
    func missingProgramStatusMapsFromLifecycleAndPendingAsks(
        lifecycle: SessionStatus,
        pendingAsks: Int,
        seenAt: Date?,
        expected: SessionStatusKind
    ) {
        #expect(
            SessionStatusKind.resolve(
                session: session(lifecycle),
                pendingAskCount: pendingAsks,
                seenAt: seenAt
            ) == expected
        )
    }

    @Test func missingProgramStatusTreatsAnInProgressStopAsWorking() {
        var stopping = session(.stopping)
        stopping.currentTurnStartedAt = outcomeSince
        #expect(SessionStatusKind.resolve(session: stopping, seenAt: seenBefore) == .working)
    }

    @Test func missingProgramStatusKeepsABlankDraftIdle() {
        for lifecycle in [SessionStatus.ready, .starting] {
            #expect(SessionStatusKind.resolve(session: session(lifecycle, messageCount: 0), seenAt: nil) == .idle)
        }
    }

    @Test func pendingAsksDoNotOverrideProgramStatus() {
        let done = session(.ready, program: program(.done))
        #expect(SessionStatusKind.resolve(session: done, pendingAskCount: 3, seenAt: nil) == .done)
        let blocked = session(.ready, program: program(.blocked, kind: .permission))
        #expect(SessionStatusKind.resolve(session: blocked, pendingAskCount: 0, seenAt: nil) == .needsApproval)
    }

    // MARK: Terminal records

    @Test func programStatusRecordsResolveWithoutALifecycle() {
        #expect(SessionStatusKind.resolve(programStatus: program(.working), seenAt: nil) == .working)
        #expect(SessionStatusKind.resolve(programStatus: program(.done), isStopped: true, seenAt: seenAfter) == .stopped)
        #expect(SessionStatusKind.resolve(programStatus: program(.error), seenAt: nil) == .error)
        #expect(SessionStatusKind.resolve(programStatus: ProgramStatus(state: .unknown("x"), since: outcomeSince), seenAt: nil) == nil)
    }

    @Test func labelsAndBlockedFlag() {
        #expect(SessionStatusKind.allCases.map(\.label) == [
            "Working", "Needs approval", "Question", "Sign-in", "Error", "Done", "Idle", "Stopped",
        ])
        #expect(SessionStatusKind.allCases.filter(\.isBlocked) == [.needsApproval, .question, .signIn])
    }
}
