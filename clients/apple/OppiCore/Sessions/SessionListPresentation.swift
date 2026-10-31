import Foundation

/// Shared active-session sectioning used by iOS and Mac session lists.
enum SessionListActiveSectionKind: Equatable {
    case yourTurn
    case working
}

/// What the list says about one row, resolved without this device's seen state: the section it lists in
/// and the status it reads.
struct SessionListClassification: Equatable, Sendable {
    /// The section the row lists in. Nil exactly when the row is stopped, so it sits behind a thread's
    /// stopped fold whatever its settled outcome reads.
    let section: SessionListActiveSectionKind?
    let status: SessionStatusKind

    /// Whether the row waits on the person: a blocked status on a row that lists live. A stopped row never
    /// does, however a lingering ask resolves it (`SessionStatusKind.resolve` leads with pending asks).
    var isBlocked: Bool { section != nil && status.isBlocked }

    /// What a thread strip calls the row: a row with no section reads stopped, and a settled outcome reads
    /// idle, since the strip has no Done. The strip's counts (`SessionThreadStripSummary.Bucket`) and its
    /// headline both read this, so they agree on what a member is.
    var settledKind: SessionStatusKind {
        guard section != nil else { return .stopped }
        return status == .done ? .idle : status
    }
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
    /// The list's classification of a row: Working = working. Your Turn = blocked, done, error, and idle.
    /// A stopped session is in neither, whatever its settled outcome was. Whether a done or error outcome
    /// is seen does not move a row, so no seen state is needed; every summary that says what a set of rows
    /// holds reads this, so they all answer the same question.
    static func classify(
        _ session: Session,
        attention: SessionListAttentionCounts = .none
    ) -> SessionListClassification {
        let status = SessionStatusKind.resolve(session: session, pendingAskCount: attention.askCount, seenAt: nil)
        return SessionListClassification(section: section(for: session, status: status), status: status)
    }

    /// A stopped session is stopped however its program status reads: that is the fold's own test.
    private static func section(for session: Session, status: SessionStatusKind) -> SessionListActiveSectionKind? {
        if session.status == .stopped { return nil }
        switch status {
        case .working: return .working
        case .stopped: return nil
        case .needsApproval, .question, .signIn, .error, .done, .idle: return .yourTurn
        }
    }

    static func activeSectionKind(
        for session: Session,
        attention: SessionListAttentionCounts = .none
    ) -> SessionListActiveSectionKind? {
        classify(session, attention: attention).section
    }

    /// Whether the session waits on the person (any blocked kind, while it lists live). Server program status
    /// owns this; `attention` covers a missing program status.
    static func isBlocked(_ session: Session, attention: SessionListAttentionCounts = .none) -> Bool {
        classify(session, attention: attention).isBlocked
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
