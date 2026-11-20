// Pure value types the workspace sidebar presents. The sidebar itself is
// `WorkspaceSidebarViewController`; its workspace row is in
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

/// A sidebar row above the workspaces: a place, built in or a server plugin's
/// entry. Picking it makes `place` the main pane's root (`SceneNavigation.openPlace`).
struct WorkspaceSidebarPlace: Equatable {
    let place: NavigationPlace
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let accessibilityHint: String?
    /// Its place among the sidebar's rows, on the scale plugin entries use (`order`).
    var order: Double = 0
    /// A logo asset drawn instead of `systemImage`, at a symbol's size (`SymbolSizedLogo`).
    var logo: String?
}

enum WorkspaceSidebarPlaces {
    /// The built-in places. All Sessions is home, first whatever a plugin's order.
    static let builtIn: [WorkspaceSidebarPlace] = [
        .init(
            place: .allSessions,
            title: "All Sessions",
            systemImage: "tray.full",
            accessibilityLabel: "All Sessions",
            accessibilityIdentifier: "workspace.allSessions.open",
            accessibilityHint: "Lists every session on this server",
            order: -.infinity
        ),
        .init(
            place: .utility(.pinned),
            title: "Pinned",
            systemImage: "pin",
            accessibilityLabel: "Pinned",
            accessibilityIdentifier: "workspace.pinned.open",
            accessibilityHint: "Opens your pinned sessions, folders, and files",
            order: 5
        ),
        .init(
            place: .utility(.agents),
            title: "Agents",
            systemImage: "person.crop.circle",
            accessibilityLabel: "Agents",
            accessibilityIdentifier: "workspace.agents.open",
            accessibilityHint: nil,
            order: 10
        ),
        .init(
            place: .utility(.schedules),
            title: "Schedules",
            systemImage: "clock",
            accessibilityLabel: "Schedules",
            accessibilityIdentifier: "workspace.schedules.open",
            accessibilityHint: nil,
            order: 20
        ),
        .init(
            place: .utility(.extensions),
            title: "Extensions",
            systemImage: "shippingbox",
            accessibilityLabel: "Open Extensions",
            accessibilityIdentifier: "workspace.extensions.open",
            accessibilityHint: nil,
            order: 40
        ),
        .init(
            place: .utility(.sshTerminal),
            title: "Terminal",
            systemImage: "terminal",
            accessibilityLabel: "Open Terminal",
            accessibilityIdentifier: "workspace.terminal.open",
            accessibilityHint: "Opens your saved hosts",
            order: 60
        ),
        .init(
            place: .utility(.rex),
            title: "Rex",
            systemImage: "rectangle.split.3x1",
            accessibilityLabel: "Open Rex",
            accessibilityIdentifier: "workspace.rex.open",
            accessibilityHint: "Opens your Rex sessions",
            order: 62,
            logo: "rex-logo"
        ),
    ]

    /// The sidebar's places, in `order`: the built-in ones this window's server offers (`offers`,
    /// its feature switches) and its plugin entries that have a sidebar row; an entry sorts after
    /// a built-in place of the same order. The server lists only plugin entries whose feature is
    /// on. Pinned needs a server that keeps pins (`ServerConnection.pinsAvailable`), and Rex this
    /// device's Rex experiment.
    static func items(
        plugins: [PluginScreenSidebarEntry],
        pinsAvailable: Bool,
        rexExperiment: Bool = SSHTerminalExperimentAccess.current.rex,
        offers: (ServerFeature) -> Bool
    ) -> [WorkspaceSidebarPlace] {
        func isOffered(_ place: NavigationPlace) -> Bool {
            guard case .utility(let utility) = place else { return true }
            switch utility {
            case .pinned: return pinsAvailable
            case .rex: return rexExperiment && offers(.rex)
            default: return utility.serverFeature.map(offers) ?? true
            }
        }
        let native = builtIn.filter { isOffered($0.place) }.map { (rank: 0, item: $0) }
        let added = plugins.filter { $0.scopes.contains("server") }.map { entry in
            (rank: 1, item: WorkspaceSidebarPlace(
                place: .utility(.pluginScreen(entry.id)),
                title: entry.title,
                systemImage: entry.icon,
                accessibilityLabel: "Open \(entry.title)",
                accessibilityIdentifier: "workspace.plugin.\(entry.id).open",
                accessibilityHint: nil,
                order: entry.order
            ))
        }
        return (native + added).sorted { ($0.item.order, $0.rank) < ($1.item.order, $1.rank) }.map(\.item)
    }

    /// Pinned below New Workspace, outside the scrolling places.
    static let appSettings = WorkspaceSidebarPlace(
        place: .utility(.appSettings),
        title: "App Settings",
        systemImage: "gear",
        accessibilityLabel: "App Settings",
        accessibilityIdentifier: "workspace.settings.open",
        accessibilityHint: nil
    )
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
