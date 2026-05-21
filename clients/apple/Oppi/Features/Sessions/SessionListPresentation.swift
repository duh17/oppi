import Foundation

/// Shared active-session sectioning used by the top-level Sessions page and
/// workspace-scoped session lists.
enum SessionListActiveSectionKind: Equatable {
    case yourTurn
    case working
}

struct SessionListAttentionCounts: Equatable, Sendable {
    var permissionCount: Int
    var askCount: Int

    static let none = SessionListAttentionCounts(permissionCount: 0, askCount: 0)

    var hasAttention: Bool {
        permissionCount > 0 || askCount > 0
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

enum SessionsHomeServerLabel {
    static func runtimeLabel(from value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let base: String
        if isIPv4Address(value) {
            base = value
        } else {
            base = value.split(separator: ".").first.map(String.init) ?? value
        }
        let label = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return label.lowercased()
    }

    static func displayLabel(
        runtimeLabel: String?,
        pairedLabel: String?,
        fallbackServerId: String
    ) -> String {
        if let runtimeLabel = runtimeLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimeLabel.isEmpty {
            return runtimeLabel
        }
        if let pairedLabel = pairedLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pairedLabel.isEmpty {
            return pairedLabel
        }
        return String(fallbackServerId.prefix(8))
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let octet = Int(part) else {
                return false
            }
            return (0...255).contains(octet)
        }
    }
}

enum SessionListPresentation {
    static func activeSectionKind(
        for session: Session,
        attention: SessionListAttentionCounts = .none,
        hasWorkingDescendant: Bool = false
    ) -> SessionListActiveSectionKind? {
        if session.status == .stopped { return nil }
        if attention.hasAttention { return .yourTurn }
        if session.isAwaitingFirstPrompt { return .yourTurn }
        if hasWorkingDescendant { return .working }

        switch session.status {
        case .ready, .error:
            return .yourTurn
        case .busy, .starting, .stopping:
            return .working
        case .stopped:
            return nil
        }
    }

    static func sortYourTurn(
        _ sessions: [Session],
        attention: (String) -> SessionListAttentionCounts
    ) -> [Session] {
        sessions.sorted { lhs, rhs in
            compareYourTurn(lhs, rhs, attention: attention)
        }
    }

    static func compareYourTurn(
        _ lhs: Session,
        _ rhs: Session,
        attention: (String) -> SessionListAttentionCounts
    ) -> Bool {
        compareYourTurn(
            lhs,
            lhsAttention: attention(lhs.id),
            rhs,
            rhsAttention: attention(rhs.id)
        )
    }

    static func compareYourTurn(
        _ lhs: Session,
        lhsAttention: SessionListAttentionCounts,
        _ rhs: Session,
        rhsAttention: SessionListAttentionCounts
    ) -> Bool {
        let lhsPermPending = lhsAttention.permissionCount > 0
        let rhsPermPending = rhsAttention.permissionCount > 0
        if lhsPermPending != rhsPermPending { return lhsPermPending }

        let lhsAskPending = lhsAttention.askCount > 0
        let rhsAskPending = rhsAttention.askCount > 0
        if lhsAskPending != rhsAskPending { return lhsAskPending }

        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity < rhs.lastActivity }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    static func sortWorking(_ sessions: [Session]) -> [Session] {
        sessions.sorted(by: compareWorking)
    }

    static func compareWorking(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        return lhs.id < rhs.id
    }
}
