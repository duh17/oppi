import Foundation

/// The one status vocabulary for a session or a terminal program.
///
/// Computed from OSC 7501 program status (`Session.programStatus`), lifecycle
/// `Session.status`, and whether this device has seen the outcome. Lifecycle
/// only drives controls; every status surface reads this. Colors stay in the
/// platform paint layer: Working blue; blocked kinds orange; Error red and
/// Done green only while unseen; Idle neutral; Stopped tertiary.
enum SessionStatusKind: Equatable, Hashable, Sendable, CaseIterable {
    case working
    /// Blocked on a permission or confirmation.
    case needsApproval
    /// Blocked on an ask, select, input, or editor dialog. Also the safe reading of an unknown blocked kind.
    case question
    /// Blocked on a sign-in.
    case signIn
    /// The run ended in an error this device has not seen.
    case error
    /// The run settled and this device has not seen the result.
    case done
    /// At rest: nothing running, nothing unseen.
    case idle
    /// A stopped session whose outcome is seen or idle.
    case stopped

    var label: String {
        switch self {
        case .working: "Working"
        case .needsApproval: "Needs approval"
        case .question: "Question"
        case .signIn: "Sign-in"
        case .error: "Error"
        case .done: "Done"
        case .idle: "Idle"
        case .stopped: "Stopped"
        }
    }

    /// Waiting on the person. These sort first in Your Turn.
    var isBlocked: Bool {
        switch self {
        case .needsApproval, .question, .signIn: true
        case .working, .error, .done, .idle, .stopped: false
        }
    }
}

// MARK: - Program status

extension SessionStatusKind {
    /// Blocked kind for a program status kind. An unknown or missing kind reads as a question.
    static func blocked(_ kind: ProgramStatusKind?) -> SessionStatusKind {
        switch kind {
        case .permission: .needsApproval
        case .auth: .signIn
        case .question, .unknown, nil: .question
        }
    }

    /// Status of one program-status record, for sessions and for terminal record trees.
    ///
    /// `seenAt` is when this device last saw the program; done and error show only while
    /// `since` is newer. `isStopped` marks a program that is no longer running (a stopped
    /// session, a closed channel): its settled outcome shows as Stopped once seen.
    /// Returns nil for an unknown future state, so the caller derives from what it knows.
    static func resolve(
        state: ProgramStatusState,
        kind: ProgramStatusKind?,
        since: Date,
        isStopped: Bool = false,
        seenAt: Date?
    ) -> SessionStatusKind? {
        let unseen = since > (seenAt ?? .distantPast)
        let atRest: SessionStatusKind = isStopped ? .stopped : .idle
        switch state {
        case .working: return .working
        case .blocked: return blocked(kind)
        case .error: return unseen ? .error : atRest
        case .done: return unseen ? .done : atRest
        case .idle: return atRest
        case .unknown: return nil
        }
    }

    static func resolve(
        programStatus: ProgramStatus,
        isStopped: Bool = false,
        seenAt: Date?
    ) -> SessionStatusKind? {
        resolve(
            state: programStatus.state,
            kind: programStatus.kind,
            since: programStatus.since,
            isStopped: isStopped,
            seenAt: seenAt
        )
    }
}

// MARK: - Session

extension SessionStatusKind {
    /// Status of a session. `seenAt` is when this device last saw it (nil = never).
    ///
    /// Program status leads. Lifecycle corrects the cases where a local update ran ahead of
    /// the server's value, and covers a missing or unknown program status (older servers,
    /// rows from before the feature): a stopped session cannot be working or blocked; a
    /// starting or busy session is working unless it is blocked or still awaiting its first
    /// prompt; a `working` value on a settled session is a stale local hint.
    /// `pendingAskCount` only matters without program status.
    static func resolve(
        session: Session,
        pendingAskCount: Int = 0,
        seenAt: Date?
    ) -> SessionStatusKind {
        if let programStatus = session.programStatus,
           let kind = resolve(programStatus: programStatus, session: session, seenAt: seenAt) {
            return kind
        }
        return fromLifecycle(session: session, pendingAskCount: pendingAskCount, seenAt: seenAt)
    }

    private static func resolve(
        programStatus: ProgramStatus,
        session: Session,
        seenAt: Date?
    ) -> SessionStatusKind? {
        switch session.status {
        case .stopped:
            switch programStatus.state {
            case .working, .blocked: return .stopped
            case .idle, .done, .error, .unknown: break
            }
            return resolve(programStatus: programStatus, isStopped: true, seenAt: seenAt)
        case .starting, .busy:
            switch programStatus.state {
            case .working, .blocked:
                return resolve(programStatus: programStatus, seenAt: seenAt)
            case .idle, .done, .error:
                return session.isAwaitingFirstPrompt ? .idle : .working
            case .unknown:
                return nil
            }
        case .stopping:
            return resolve(programStatus: programStatus, seenAt: seenAt)
        case .ready:
            if programStatus.state == .working { return nil }
            return resolve(programStatus: programStatus, seenAt: seenAt)
        case .error:
            switch programStatus.state {
            case .error, .blocked: return resolve(programStatus: programStatus, seenAt: seenAt)
            case .working, .idle, .done, .unknown: return nil
            }
        }
    }

    private static func fromLifecycle(
        session: Session,
        pendingAskCount: Int,
        seenAt: Date?
    ) -> SessionStatusKind {
        if pendingAskCount > 0 { return .question }
        if session.isAwaitingFirstPrompt { return .idle }
        let seen = seenAt ?? .distantPast
        switch session.status {
        case .busy, .starting:
            return .working
        case .stopping:
            // Terminate broadcasts `stopping` for idle sessions too.
            return session.currentTurnStartedAt == nil ? .idle : .working
        case .ready:
            return (session.lastAgentReplyAt ?? session.lastActivity) > seen ? .done : .idle
        case .stopped:
            return .stopped
        case .error:
            return session.lastActivity > seen ? .error : .idle
        }
    }
}
