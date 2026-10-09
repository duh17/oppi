import Foundation
import GhosttyVt

/// OSC 7501 records as the shared session-status vocabulary.
///
/// Ghostty keeps the C enums. This maps them into `SessionStatusKind` and rolls
/// a terminal's record tree up with `SessionStatusRollup`. Terminal record ids
/// are not session ids: seen state stays in a terminal-local `SessionSeenLedger`
/// and is never written to `SessionStore`.
enum SSHTerminalProgramStatusPresentation {
    /// While the terminal view is on screen, every record is seen. That is the
    /// same rule as an open session chat, which reports distant future from
    /// `SessionStore.seenAt`. The ledger is the record of it for a terminal
    /// that is not on screen; this view is on screen whenever the pill can show.
    static func seenAt(id: String, ledger: SessionSeenLedger, terminalVisible: Bool) -> Date {
        terminalVisible ? .distantFuture : ledger.seenAt(for: id)
    }

    static func programState(_ state: GhosttyProgramStatusState) -> ProgramStatusState? {
        switch state {
        case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: .idle
        case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: .working
        case GHOSTTY_PROGRAM_STATUS_STATE_DONE: .done
        case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: .blocked
        case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: .error
        default: nil
        }
    }

    /// Known blocked kinds. `none` is absent. Anything else is an unknown kind,
    /// which `SessionStatusKind.blocked` reads as a question.
    static func programKind(_ kind: GhosttyProgramStatusKind) -> ProgramStatusKind? {
        switch kind {
        case GHOSTTY_PROGRAM_STATUS_KIND_NONE: nil
        case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: .permission
        case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: .question
        case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: .auth
        default: .unknown("kind")
        }
    }

    static func status(
        state: GhosttyProgramStatusState,
        kind: GhosttyProgramStatusKind = GHOSTTY_PROGRAM_STATUS_KIND_NONE,
        since: Date,
        isStopped: Bool = false,
        seenAt: Date?
    ) -> SessionStatusKind? {
        guard let programState = programState(state) else { return nil }
        let programKind = programState == .blocked ? programKind(kind) : nil
        return SessionStatusKind.resolve(
            state: programState,
            kind: programKind,
            since: since,
            isStopped: isStopped,
            seenAt: seenAt
        )
    }

    static func status(
        of record: SSHTerminalProgramStatusStore.Record,
        isStopped: Bool = false,
        seenAt: Date?
    ) -> SessionStatusKind? {
        status(
            state: record.state,
            kind: record.kind,
            since: record.since,
            isStopped: isStopped,
            seenAt: seenAt
        )
    }

    /// Nil when no program has reported. The root record is the roll-up root;
    /// every other record is a member, so the root is not counted twice.
    @MainActor
    static func rollup(
        store: SSHTerminalProgramStatusStore,
        isStopped: Bool,
        seenAt: Date?
    ) -> SessionStatusRollup? {
        let root = store.root.flatMap { status(of: $0, isStopped: isStopped, seenAt: seenAt) }
        let others = store.subtree().compactMap { status(of: $0, isStopped: isStopped, seenAt: seenAt) }
        guard root != nil || !others.isEmpty else { return nil }
        return SessionStatusRollup(root: root, others: others)
    }

    /// One blocked record's card copy. Remote text is title-grade; the host
    /// line is the saved profile, drawn by the card. Nil when nothing is blocked.
    @MainActor
    static func blockedNotice(
        store: SSHTerminalProgramStatusStore,
        isStopped: Bool,
        seenAt: Date?
    ) -> SSHTerminalBlockedNotice? {
        let blocked = store.records.values.compactMap { record -> (SSHTerminalProgramStatusStore.Record, SessionStatusKind)? in
            guard let kind = status(of: record, isStopped: isStopped, seenAt: seenAt), kind.isBlocked else { return nil }
            return (record, kind)
        }
        guard !blocked.isEmpty else { return nil }
        let kind = blockedKindOrder.first { candidate in blocked.contains { $0.1 == candidate } } ?? .question
        let pool = blocked.filter { $0.1 == kind }
        guard let chosen = pool.min(by: prefersBannerCopy) else { return nil }
        return SSHTerminalBlockedNotice(
            recordID: chosen.0.id,
            episode: chosen.0.episode,
            kind: kind,
            remoteText: remoteText(message: chosen.0.message, title: chosen.0.title)
        )
    }

    /// Message, else title, shortened to a title. Empty when the program sent neither.
    static func remoteText(message: String, title: String) -> String {
        let message = SSHTerminalDisplayText.sanitized(message, limit: SSHTerminalDisplayText.titleLimit)
        if !message.isEmpty { return message }
        return SSHTerminalDisplayText.sanitized(title, limit: SSHTerminalDisplayText.titleLimit)
    }

    /// Saved host name, never text from a report. Empty becomes a fixed Oppi phrase.
    static func hostCaption(_ hostLabel: String) -> String {
        let host = SSHTerminalDisplayText.sanitized(hostLabel, limit: SSHTerminalDisplayText.titleLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "Remote host" : host
    }

    /// Same blocked-kind order as the roll-up headline: permission, then sign-in, then question.
    private static let blockedKindOrder: [SessionStatusKind] = [.needsApproval, .signIn, .question]

    private static func prefersBannerCopy(
        _ lhs: (SSHTerminalProgramStatusStore.Record, SessionStatusKind),
        _ rhs: (SSHTerminalProgramStatusStore.Record, SessionStatusKind)
    ) -> Bool {
        let left = bannerRank(lhs.0)
        let right = bannerRank(rhs.0)
        if left != right { return left < right }
        return lhs.0.id < rhs.0.id
    }

    private static func bannerRank(_ record: SSHTerminalProgramStatusStore.Record) -> Int {
        if !record.message.isEmpty { return 0 }
        if !record.title.isEmpty { return 1 }
        return 2
    }
}

/// Blocked card copy. `kind` is Oppi's; `remoteText` is the program's.
///
/// Equality is the dismissal key: record, blocked episode, kind, and text,
/// never a redraw. A repeat of the same report keeps the episode and text, so
/// a dismissed card stays down. A new message, a new kind, another record, or
/// blocked again after another state is a different notice and shows.
struct SSHTerminalBlockedNotice: Hashable, Sendable {
    var recordID: String
    var episode: UInt64
    var kind: SessionStatusKind
    var remoteText: String
}
