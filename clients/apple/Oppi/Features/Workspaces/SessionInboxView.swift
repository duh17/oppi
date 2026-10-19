import SwiftUI

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

enum SessionInboxTransportAvailability {
    static func isUnavailable(hasAPIClient: Bool, isPreparing: Bool) -> Bool {
        !hasAPIClient && !isPreparing
    }
}

struct WorkspaceSidebarPrimaryUtilityItem: Equatable {
    let target: WorkspaceUtilityNavTarget
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let minimumHitHeight: CGFloat
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
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .schedules,
            title: "Schedules",
            systemImage: "clock",
            accessibilityLabel: "Schedules",
            accessibilityIdentifier: "workspace.schedules.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .skills,
            title: "Skills",
            systemImage: "sparkles.rectangle.stack",
            accessibilityLabel: "Open Skills",
            accessibilityIdentifier: "workspace.skills.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .extensions,
            title: "Extensions",
            systemImage: "shippingbox",
            accessibilityLabel: "Open Extensions",
            accessibilityIdentifier: "workspace.extensions.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
        .init(
            target: .mcpServers,
            title: "MCP Servers",
            systemImage: "network",
            accessibilityLabel: "Open MCP Servers",
            accessibilityIdentifier: "workspace.mcpServers.open",
            minimumHitHeight: 44,
            accessibilityHint: nil
        ),
    ]

    static let desktopStill = WorkspaceSidebarPrimaryUtilityItem(
        target: .desktopStill,
        title: "Remote Screen",
        systemImage: "macwindow",
        accessibilityLabel: "Remote Screen",
        accessibilityIdentifier: "workspace.desktopStill.open",
        minimumHitHeight: 44,
        accessibilityHint: "Inspect the current remote screen"
    )

    /// The SSH inputs have no defaults: reading saved preferences here made tests depend on
    /// whatever a simulator's app container last persisted.
    static func items(
        for idiom: UIUserInterfaceIdiom,
        sshTerminalEnabled: Bool,
        hasSSHProfile: Bool,
        desktopLiveViewAvailable: Bool = false
    ) -> [WorkspaceSidebarPrimaryUtilityItem] {
        var result = items
        if sshTerminalEnabled && hasSSHProfile {
            result.append(.init(
                target: .sshTerminal, title: "Terminal", systemImage: "terminal",
                accessibilityLabel: "Open SSH Terminal", accessibilityIdentifier: "workspace.terminal.open",
                minimumHitHeight: 44, accessibilityHint: "Opens your saved SSH hosts"
            ))
        }
        if idiom == .phone, ReleaseFeatures.desktopStillEnabled || desktopLiveViewAvailable {
            result.append(desktopStill)
        }
        return result
    }
}

/// Inbox-local search and stopped-group expansion belong to the visible host.
/// Compact host jobs stay mounted over inbox, so a host change must reset these
/// without popping to All Sessions.
enum SessionInboxHostChange {
    @MainActor
    static func reset(
        searchText _: String,
        expandedStoppedGroupIDs _: Set<String>,
        collapsedStoppedGroupIDs _: Set<String>,
        searchStore: SessionSearchStore
    ) -> (searchText: String, expandedStoppedGroupIDs: Set<String>, collapsedStoppedGroupIDs: Set<String>) {
        searchStore.clear()
        return ("", [], [])
    }
}

enum SessionInboxSessionRouting {
    static func routeScope(for session: Session) -> SessionRouteScope? {
        session.routeScope
    }

    static func allSessionsContext(for session: Session, workspaceName: String?) -> String? {
        if session.isControlConversation { return "Oppi Control" }
        return SessionRowPresentationBuilder.allSessionsWorkspaceContext(
            for: session,
            workspaceName: workspaceName
        )
    }
}

struct WorkspaceSidebarView: View {
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var sshTerminalEnabled = false
    @AppStorage(AppPreferences.Experiments.desktopLiveViewKey) private var desktopLiveViewEnabled = false
    @AppStorage(SSHTerminalProfileStore.catalogKey) private var sshCatalogData = Data()
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme

    var onSelect: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var createSheetContext: WorkspaceCreateSheetContext?
    @State private var pendingCreatedWorkspaceTarget: WorkspaceNavTarget?
    @AppStorage(AppIdentifiers.workspaceSidebarExpandedKey)
    private var workspacesExpanded = WorkspaceSidebarDisclosurePolicy.defaultExpanded

    private var servers: [PairedServer] {
        serverStore.servers
    }

    private var selectedServer: PairedServer? {
        if let activeServerId = coordinator.activeServerId,
           let server = servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return servers.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    ForEach(
                        WorkspaceSidebarPrimaryUtilities.items(
                            for: UIDevice.current.userInterfaceIdiom,
                            sshTerminalEnabled: sshTerminalEnabled,
                            hasSSHProfile: SSHTerminalProfileStore.hasConfiguredHost(catalogData: sshCatalogData),
                            desktopLiveViewAvailable: DesktopLiveViewPlayground.isAvailable(
                                experimentEnabled: desktopLiveViewEnabled,
                                serverOffers: selectedServer
                                    .flatMap { coordinator.connection(for: $0.id) }?
                                    .desktopLiveViewAvailable == true
                            )
                        )
                            .filter { $0.target.isReleaseEnabled },
                        id: \.target
                    ) { item in
                        sidebarUtilityRow(item)
                    }

                    Button {
                        workspacesExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Workspaces")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 8)
                            Image(systemName: workspacesExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.themeComment)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .accessibilityLabel("Workspaces")
                    .accessibilityValue(workspacesExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(workspacesExpanded ? "Hides workspace rows" : "Shows workspace rows")
                    .accessibilityIdentifier("workspace.sidebar.disclosure")

                    if workspacesExpanded, let selectedServer {
                        let serverId = selectedServer.id
                        let connection = coordinator.connection(for: serverId)
                        let workspaceStore = connection?.workspaceStore
                        let summaries = workspaceStore?.workspaceSummaries(forServer: serverId) ?? [:]
                        let workspaces = sortedWorkspacesForList(
                            workspacesForServer(serverId),
                            summaries: summaries
                        )
                        let availability = WorkspaceCatalogAvailability(
                            hasWorkspaces: !workspaces.isEmpty,
                            isLoaded: workspaceStore?.isLoaded ?? false,
                            isSyncing: workspaceStore?.isSyncing ?? false,
                            lastSyncFailed: workspaceStore?.lastSyncFailed ?? false,
                            hasAPIClient: connection?.apiClient != nil,
                            isPreparing: coordinator.preparingServerIds.contains(serverId)
                        )

                        switch availability {
                        case .loading:
                            Label("Loading workspaces…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline)
                                .foregroundStyle(.themeComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 8)

                        case .unavailable:
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Workspaces unavailable", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.themeOrange)
                                Button("Retry") {
                                    Task {
                                        if connection?.apiClient == nil {
                                            await coordinator.retryServerConnection(serverId)
                                        } else {
                                            await coordinator.refreshServer(serverId, force: true)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)

                        case .empty:
                            Text("No workspaces")
                                .font(.subheadline)
                                .foregroundStyle(.themeComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 8)

                        case .available:
                            if connection == nil
                                || connection?.serverHealth(forServer: serverId).transportState == .disconnected
                                || workspaceStore?.lastSyncFailed == true {
                                Label("Saved workspaces may be out of date", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                    .font(.subheadline)
                                    .foregroundStyle(.themeOrange)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 8)
                            }
                            ForEach(workspaces) { workspace in
                                let target = WorkspaceNavTarget(serverId: serverId, workspace: workspace)
                                let status = workspaceSessionStatus(
                                    workspaceId: workspace.id,
                                    connection: connection
                                )
                                let gitSummary = workspaceGitSummary(
                                    summaries[workspace.id]?.gitSummary
                                )
                                Button {
                                    navigation.openWorkspace(target)
                                    onSelect?()
                                } label: {
                                    WorkspaceSidebarRow(
                                        workspace: workspace,
                                        status: status,
                                        gitSummary: gitSummary,
                                        isSelected: navigation.selectedWorkspaceFilter == target,
                                        lockBadge: ScopedLockService.shared.badge(
                                            .workspace(serverId: serverId, workspaceId: workspace.id)
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(WorkspaceHomeView.workspaceOpenAccessibilityIdentifier(workspaceName: workspace.name))
                                .accessibilityLabel("Open \(workspace.name)")
                                .accessibilityValue(workspaceAccessibilityValue(status: status, gitSummary: gitSummary))
                                .accessibilityAddTraits(
                                    navigation.selectedWorkspaceFilter == target ? .isSelected : []
                                )
                            }
                        }
                    } else if workspacesExpanded {
                        Text("No server selected")
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("workspace.sidebar.scroll")

            if let selectedServer {
                Divider()

                newWorkspaceButton(selectedServer)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            sidebarUtilityRow(.appSettings, title: "App Settings", systemImage: "gear")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg.primary.ignoresSafeArea())
        .routerModal(
            item: $createSheetContext,
            presentation: .sheet.inNavigation(),
            onDismiss: handleCreateSheetDismissed
        ) { context in
            WorkspaceCreateView(
                server: context.server,
                presentation: context.presentation,
                prefillName: context.prefillName,
                prefillPath: context.prefillPath,
                onCreate: { workspace in
                    guard context.openWorkspaceAfterCreate else { return }
                    pendingCreatedWorkspaceTarget = WorkspaceNavTarget(
                        serverId: context.server.id,
                        workspace: workspace
                    )
                }
            )
        }
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Oppi")
                .font(.title2.weight(.bold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeFg)
                .accessibilityLabel("Close workspaces")
                .accessibilityIdentifier("workspace.sidebar.close")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func sidebarUtilityRow(_ item: WorkspaceSidebarPrimaryUtilityItem) -> some View {
        sidebarUtilityRow(
            item.target,
            title: item.title,
            systemImage: item.systemImage,
            accessibilityLabel: item.accessibilityLabel,
            accessibilityIdentifier: item.accessibilityIdentifier,
            minimumHitHeight: item.minimumHitHeight,
            accessibilityHint: item.accessibilityHint
        )
    }

    private func sidebarUtilityRow(
        _ target: WorkspaceUtilityNavTarget,
        title: String,
        systemImage: String,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        minimumHitHeight: CGFloat = 44,
        accessibilityHint: String? = nil
    ) -> some View {
        let isSelected = navigation.workspaceNavigationPresentation == .split
            && navigation.splitDetailTarget == .utility(target)

        return Button {
            navigation.openWorkspaceUtility(target)
            onSelect?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .themeBlue : .themeFg)
                    .frame(width: 32, height: 32)

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? .themeBlue : .themeFg)

                Spacer(minLength: 8)
            }
            .frame(minHeight: minimumHitHeight)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.text.primary.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityHint(accessibilityHint ?? "Opens \(title.lowercased()) management")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            accessibilityIdentifier
                ?? (target == .appSettings ? "workspace.settings.open" : "workspace.\(title.lowercased()).open")
        )
    }

    private func newWorkspaceButton(_ selectedServer: PairedServer) -> some View {
        Button {
            presentCreateWorkspace(on: selectedServer)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.themeFg)

                Text("New Workspace")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.create.sidebar.open")
        .accessibilityLabel("Create New Workspace")
    }

    private func workspacesForServer(_ serverId: String) -> [Workspace] {
        coordinator.connection(for: serverId)?.workspaceStore.workspaces ?? []
    }

    private func workspaceSessionStatus(
        workspaceId: String,
        connection: ServerConnection?
    ) -> WorkspaceSidebarSessionStatus {
        guard let connection else {
            return WorkspaceSidebarSessionStatus(sessions: [])
        }

        return WorkspaceSidebarSessionStatus(
            sessions: connection.sessionStore.listProjectionSessions(workspaceId: workspaceId),
            pendingAskCountForSession: { sessionId in
                SessionListAttentionMerger.askCount(
                    listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
                    hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
                    hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
                )
            },
            seenAtForSession: { connection.sessionStore.seenAt(for: $0) }
        )
    }

    private func workspaceGitSummary(_ summary: WorkspaceGitSummary?) -> WorkspaceSidebarGitSummary? {
        guard let summary, summary.isGitRepo else { return nil }
        let sidebarSummary = WorkspaceSidebarGitSummary(
            changedCount: summary.changedCount,
            aheadCount: summary.ahead ?? 0,
            behindCount: summary.behind ?? 0
        )
        return sidebarSummary.isVisible ? sidebarSummary : nil
    }

    private func workspaceAccessibilityValue(
        status: WorkspaceSidebarSessionStatus,
        gitSummary: WorkspaceSidebarGitSummary?
    ) -> String {
        [status.accessibilityValue, gitSummary?.accessibilityValue]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }

    private func presentCreateWorkspace(
        on server: PairedServer,
        presentation: WorkspaceCreatePresentation = .standard,
        openWorkspaceAfterCreate: Bool = false,
        prefillName: String? = nil,
        prefillPath: String? = nil
    ) {
        createSheetContext = WorkspaceCreateSheetContext(
            server: server,
            presentation: presentation,
            openWorkspaceAfterCreate: openWorkspaceAfterCreate,
            prefillName: prefillName,
            prefillPath: prefillPath
        )
    }

    private func handleCreateSheetDismissed() {
        guard let target = pendingCreatedWorkspaceTarget else { return }
        pendingCreatedWorkspaceTarget = nil
        navigation.openWorkspace(target)
        onSelect?()
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

    /// Counts the sessions' statuses. Error and done are the unseen ones: once this device
    /// has seen an outcome the session is Idle and no longer counts.
    init(
        sessions: [Session],
        pendingAskCountForSession: (String) -> Int = { _ in 0 },
        seenAtForSession: (String) -> Date? = { _ in nil }
    ) {
        var blockedCount = 0
        var errorCount = 0
        var workingCount = 0
        var doneCount = 0

        for session in sessions {
            let status = SessionStatusKind.resolve(
                session: session,
                pendingAskCount: pendingAskCountForSession(session.id),
                seenAt: seenAtForSession(session.id)
            )
            switch status {
            case .needsApproval, .question, .signIn:
                blockedCount += 1
            case .error:
                errorCount += 1
            case .working:
                workingCount += 1
            case .done:
                doneCount += 1
            case .idle, .stopped:
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

struct WorkspaceSidebarRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID

    let workspace: Workspace
    let status: WorkspaceSidebarSessionStatus
    let gitSummary: WorkspaceSidebarGitSummary?
    let isSelected: Bool
    let lockBadge: ScopedLockState

    init(
        workspace: Workspace,
        status: WorkspaceSidebarSessionStatus,
        gitSummary: WorkspaceSidebarGitSummary? = nil,
        isSelected: Bool,
        lockBadge: ScopedLockState = .none
    ) {
        self.workspace = workspace
        self.status = status
        self.gitSummary = gitSummary
        self.isSelected = isSelected
        self.lockBadge = lockBadge
    }

    /// A locked workspace shows its name only.
    private var hidesDetails: Bool { lockBadge == .locked }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WorkspaceRuntimeIcon(workspace: workspace, size: 26, frameSize: 32)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(workspace.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)
                        LockBadge(state: lockBadge)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if status.isVisible, !hidesDetails {
                        WorkspaceSidebarSessionStatusIndicator(status: status)
                    }
                }

                if !hidesDetails, let description = workspace.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !hidesDetails, let gitSummary, gitSummary.isVisible {
                    WorkspaceSidebarGitStatusLine(summary: gitSummary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.text.primary.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
        .id(themeID)
    }
}

struct WorkspaceSidebarGitStatusLine: View {
    let summary: WorkspaceSidebarGitSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if summary.changedCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.changedCount)) changes",
                    symbol: "circle.fill",
                    tint: .themeOrange,
                    symbolScale: .small
                )
            }

            if summary.aheadCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.aheadCount))",
                    symbol: "arrow.up",
                    tint: .themeBlue
                )
            }

            if summary.behindCount > 0 {
                metric(
                    text: "\(SessionFormatting.compactCount(summary.behindCount))",
                    symbol: "arrow.down",
                    tint: .themeOrange
                )
            }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityValue)
    }

    private func metric(
        text: String,
        symbol: String,
        tint: ThemeShapeStyle,
        symbolScale: Image.Scale = .medium
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .imageScale(symbolScale)
            Text(text)
                .monospacedDigit()
        }
        .foregroundStyle(tint)
    }
}

struct WorkspaceSidebarSessionStatusIndicator: View {
    let status: WorkspaceSidebarSessionStatus

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            if status.attentionCount > 0 {
                metric(
                    symbol: "exclamationmark.triangle.fill",
                    count: status.attentionCount,
                    tint: status.errorCount > 0 ? .themeRed : .themeOrange
                )
            }

            if status.workingCount > 0 {
                metric(symbol: "bolt.fill", count: status.workingCount, tint: .themeBlue)
            }

            if status.showsDone {
                metric(symbol: "checkmark", count: status.doneCount, tint: .themeGreen)
            }
        }
        .font(.caption2.weight(.semibold))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private func metric(symbol: String, count: Int, tint: ThemeShapeStyle) -> some View {
        HStack(alignment: .center, spacing: 2) {
            Image(systemName: symbol)
                .imageScale(.small)

            Text(SessionFormatting.compactCount(count))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}
