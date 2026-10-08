import Foundation

/// Shared active-session sectioning used by iOS and Mac session lists.
enum SessionListActiveSectionKind: Equatable {
    case yourTurn
    case working
}

struct SessionListAttentionCounts: Equatable, Sendable {
    var askCount: Int

    static let none = SessionListAttentionCounts(askCount: 0)

    var hasAttention: Bool {
        askCount > 0
    }
}

enum SessionListAttentionMerger {
    static func askCount(
        listCount: Int,
        hasPendingAsk: Bool,
        hasPendingExtensionDialog: Bool
    ) -> Int {
        // `pendingAskCount` drives the “Question” badge. Sheet-backed
        // extension dialogs are not necessarily questions; widget/status
        // surfaces and background agent UI must not make a row look like it is
        // waiting for a user answer.
        _ = hasPendingExtensionDialog
        return max(listCount, hasPendingAsk ? 1 : 0)
    }
}

struct SessionListRefreshPollingPolicy: Equatable {
    private(set) var gracePollsRemaining: Int = 0
    private var hadActiveWork = false
    let postTransitionGracePolls: Int

    init(postTransitionGracePolls: Int = 2) {
        self.postTransitionGracePolls = postTransitionGracePolls
    }

    mutating func shouldRefresh(hasActiveWork: Bool, hasAttention: Bool) -> Bool {
        if hasActiveWork {
            hadActiveWork = true
            gracePollsRemaining = postTransitionGracePolls
            return true
        }

        if hadActiveWork {
            hadActiveWork = false
            gracePollsRemaining = max(gracePollsRemaining, postTransitionGracePolls)
        }

        if hasAttention {
            return true
        }

        if gracePollsRemaining > 0 {
            gracePollsRemaining -= 1
            return true
        }

        return false
    }
}

enum SessionListPresentation {
    /// Working = working. Your Turn = blocked, done, error, and idle. A stopped session is in neither.
    /// Whether a done or error outcome is seen does not move a row, so no seen state is needed.
    static func activeSectionKind(
        for session: Session,
        attention: SessionListAttentionCounts = .none
    ) -> SessionListActiveSectionKind? {
        if session.status == .stopped { return nil }
        switch SessionStatusKind.resolve(session: session, pendingAskCount: attention.askCount, seenAt: nil) {
        case .working: return .working
        case .stopped: return nil
        case .needsApproval, .question, .signIn, .error, .done, .idle: return .yourTurn
        }
    }

    /// Whether the session waits on the person (any blocked kind). Server program status
    /// owns this; `attention` covers a missing program status.
    static func isBlocked(_ session: Session, attention: SessionListAttentionCounts = .none) -> Bool {
        SessionStatusKind.resolve(session: session, pendingAskCount: attention.askCount, seenAt: nil).isBlocked
    }

    /// Your Turn order: blocked first, then the oldest visible activity, the
    /// same timestamp the row shows.
    static func compareYourTurn(
        _ lhs: Session,
        lhsBlocked: Bool,
        _ rhs: Session,
        rhsBlocked: Bool
    ) -> Bool {
        if lhsBlocked != rhsBlocked { return lhsBlocked }

        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity < rhs.lastActivity }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    /// List matches `ForEach` ids across sections. Stopped rows must not reuse the
    /// live row id, or Stop flies the same cell from Your Turn / Working.
    static func stoppedRowID(_ rowID: String) -> String {
        "stopped:\(rowID)"
    }

    static func compareWorking(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        return lhs.id < rhs.id
    }
}
