import UIKit

// Pure value types the workspace sidebar presents. The sidebar itself is
// `WorkspaceSidebarViewController`; its SwiftUI workspace row is in
// `WorkspaceComponents.swift`.

enum WorkspaceCatalogAvailability: Equatable {
    case loading
    case unavailable
    case empty
    case available

    init(
        hasWorkspaces: Bool,
        isLoaded: Bool,
        isSyncing: Bool,
        lastSyncFailed: Bool,
        hasAPIClient: Bool = true,
        isPreparing: Bool = false
    ) {
        if hasWorkspaces {
            self = .available
        } else if isSyncing || isPreparing {
            self = .loading
        } else if lastSyncFailed || !hasAPIClient {
            self = .unavailable
        } else if isLoaded {
            self = .empty
        } else {
            self = .loading
        }
    }
}

enum WorkspaceSidebarDisclosurePolicy {
    static let defaultExpanded = true
}

struct WorkspaceSidebarPrimaryUtilityItem: Equatable {
    let target: WorkspaceUtilityNavTarget
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let accessibilityHint: String?
}

enum WorkspaceSidebarPrimaryUtilities {
    static let items: [WorkspaceSidebarPrimaryUtilityItem] = [
        .init(
            target: .agents,
            title: "Agents",
            systemImage: "person.crop.circle",
            accessibilityLabel: "Agents",
            accessibilityIdentifier: "workspace.agents.open",
            accessibilityHint: nil
        ),
        .init(
            target: .schedules,
            title: "Schedules",
            systemImage: "clock",
            accessibilityLabel: "Schedules",
            accessibilityIdentifier: "workspace.schedules.open",
            accessibilityHint: nil
        ),
        .init(
            target: .skills,
            title: "Skills",
            systemImage: "sparkles.rectangle.stack",
            accessibilityLabel: "Open Skills",
            accessibilityIdentifier: "workspace.skills.open",
            accessibilityHint: nil
        ),
        .init(
            target: .extensions,
            title: "Extensions",
            systemImage: "shippingbox",
            accessibilityLabel: "Open Extensions",
            accessibilityIdentifier: "workspace.extensions.open",
            accessibilityHint: nil
        ),
        .init(
            target: .mcpServers,
            title: "MCP Servers",
            systemImage: "network",
            accessibilityLabel: "Open MCP Servers",
            accessibilityIdentifier: "workspace.mcpServers.open",
            accessibilityHint: nil
        ),
    ]

    /// Pinned below New Workspace; not part of `items(for:…)`.
    static let appSettings = WorkspaceSidebarPrimaryUtilityItem(
        target: .appSettings,
        title: "App Settings",
        systemImage: "gear",
        accessibilityLabel: "App Settings",
        accessibilityIdentifier: "workspace.settings.open",
        accessibilityHint: nil
    )

    /// The SSH inputs have no defaults: reading saved preferences here made tests depend on
    /// whatever a simulator's app container last persisted.
    static func items(
        for idiom: UIUserInterfaceIdiom,
        sshTerminalEnabled: Bool,
        hasSSHProfile: Bool
    ) -> [WorkspaceSidebarPrimaryUtilityItem] {
        var result = items
        if sshTerminalEnabled && hasSSHProfile {
            result.append(.init(
                target: .sshTerminal, title: "Terminal", systemImage: "terminal",
                accessibilityLabel: "Open SSH Terminal", accessibilityIdentifier: "workspace.terminal.open",
                accessibilityHint: "Opens your saved SSH hosts"
            ))
        }
        return result
    }
}

/// Compact workspace aggregate using the same attention and status semantics as session rows.
struct WorkspaceSidebarSessionStatus: Equatable {
    /// Sessions waiting on the person, whatever they wait for.
    let blockedCount: Int
    let errorCount: Int
    let workingCount: Int
    let doneCount: Int

    init(
        blockedCount: Int = 0,
        errorCount: Int = 0,
        workingCount: Int = 0,
        doneCount: Int = 0
    ) {
        self.blockedCount = blockedCount
        self.errorCount = errorCount
        self.workingCount = workingCount
        self.doneCount = doneCount
    }

    /// Counts live sessions from server state, the same ones the session list puts in
    /// Working and Your Turn. Stopped sessions are history and never count, and nothing
    /// here depends on whether this device has opened a session: Done is every live
    /// session that finished its turn (a draft awaiting its first prompt is not one).
    init(
        sessions: [Session],
        pendingAskCountForSession: (String) -> Int = { _ in 0 }
    ) {
        var blockedCount = 0
        var errorCount = 0
        var workingCount = 0
        var doneCount = 0

        for session in sessions where session.status != .stopped {
            let status = SessionStatusKind.resolve(
                session: session,
                pendingAskCount: pendingAskCountForSession(session.id),
                seenAt: nil
            )
            switch status {
            case .needsApproval, .question, .signIn:
                blockedCount += 1
            case .error:
                errorCount += 1
            case .working:
                workingCount += 1
            case .done, .idle:
                if !session.isAwaitingFirstPrompt { doneCount += 1 }
            case .stopped:
                break
            }
        }

        self.blockedCount = blockedCount
        self.errorCount = errorCount
        self.workingCount = workingCount
        self.doneCount = doneCount
    }

    var attentionCount: Int {
        blockedCount + errorCount
    }

    var isVisible: Bool {
        attentionCount > 0 || workingCount > 0 || doneCount > 0
    }

    /// Attention replaces Done visually to keep the trailing cluster compact.
    var showsDone: Bool {
        attentionCount == 0 && doneCount > 0
    }

    var accessibilityValue: String {
        [
            sessionAttentionLabel(errorCount, state: "has an error", pluralState: "have errors"),
            sessionAttentionLabel(blockedCount, state: "needs attention", pluralState: "need attention"),
            sessionCountLabel(workingCount, state: "working"),
            sessionCountLabel(doneCount, state: "done"),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func sessionAttentionLabel(
        _ count: Int,
        state: String,
        pluralState: String
    ) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 session \(state)" : "\(count) sessions \(pluralState)"
    }

    private func sessionCountLabel(_ count: Int, state: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(state) \(count == 1 ? "session" : "sessions")"
    }
}

/// Compact git state for a workspace catalog row.
struct WorkspaceSidebarGitSummary: Equatable {
    let changedCount: Int
    let aheadCount: Int
    let behindCount: Int

    var isVisible: Bool {
        changedCount > 0 || aheadCount > 0 || behindCount > 0
    }

    var accessibilityValue: String {
        [
            countLabel(changedCount, singular: "changed file", plural: "changed files"),
            countLabel(aheadCount, singular: "commit not pushed", plural: "commits not pushed"),
            countLabel(behindCount, singular: "commit behind", plural: "commits behind"),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func countLabel(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}
