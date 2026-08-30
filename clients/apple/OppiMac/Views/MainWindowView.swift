import SwiftUI

private struct MacSidebarLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.themeFg)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.themeFg)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MainWindowView: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState
    let sessionMonitor: MacSessionMonitor
    let checkForUpdates: @MainActor () -> Void
    @Binding var pendingSessionDeepLinkURL: URL?

    @State private var selectedSection = MacSidebarSection.defaultSection
    @State private var columnVisibility = MacShellColumnVisibility.launch
    @State private var selectedSettingsPane: MacSettingsPane = .app
    @State private var selectedWorkspaceID: String?
    @State private var selectedSessionID: String?
    @State private var resolvingSessionDeepLinkURL: URL?
    @State private var sessionDeepLinkResolutionGeneration: UInt = 0
    @State private var searchText = ""
    @State private var searchStore = SessionSearchStore()
    @State private var workspacesExpanded = false
    @State private var workspaceStore = MacWorkspaceSnapshotStore()
    @State private var sessionTraceStore = MacSessionTraceStore()
    @State private var remoteServerStore = MacRemoteServerStore()
    @Bindable private var catalogStore = MacCatalogStore.shared

    init(
        processManager: ServerProcessManager,
        healthMonitor: ServerHealthMonitor,
        permissionState: TCCPermissionState,
        sessionMonitor: MacSessionMonitor,
        pendingSessionDeepLinkURL: Binding<URL?>,
        checkForUpdates: @escaping @MainActor () -> Void
    ) {
        self.processManager = processManager
        self.healthMonitor = healthMonitor
        self.permissionState = permissionState
        self.sessionMonitor = sessionMonitor
        self.checkForUpdates = checkForUpdates
        _pendingSessionDeepLinkURL = pendingSessionDeepLinkURL
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            contentList
                .themedListSurface()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            detailPane
                .themedScrollSurface()
        }
        .navigationTitle(windowTitle)
        .background {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()
        }
        .frame(minWidth: 980, minHeight: 620)
        .task {
            wireAttentionNotifications()
            await refreshWorkspaceCatalogAndSessions()
            await consumePendingSessionDeepLink()
            await workspaceStore.runAppEventStreamFromLocalConfig()
        }
        .onChange(of: selectedSessionID) { _, _ in
            publishVisibleAttentionSession()
        }
        .onChange(of: pendingSessionDeepLinkURL) { _, _ in
            Task { await consumePendingSessionDeepLink() }
        }
        .onChange(of: processManager.state) { _, state in
            guard MacSessionDeepLinkNavigation.shouldRetryAfterServerBecameReady(
                state: state,
                hasPendingSessionDeepLink: pendingSessionDeepLinkURL != nil
            ) else { return }
            Task {
                await refreshWorkspaceCatalogAndSessions()
                await consumePendingSessionDeepLink()
            }
        }
        .onChange(of: workspaceStore.sessionTargets.map(\.sessionId)) { _, _ in
            bindHomeTraceIfCatalogHit()
            Task { await consumePendingSessionDeepLink() }
        }
        .onChange(of: searchText) { _, newValue in
            updateSessionSearch(newValue)
        }
        .onChange(of: selectedSection) { _, _ in
            publishVisibleAttentionSession()
            updateSessionSearch(searchText)
        }
        .onDisappear {
            publishVisibleAttentionSession(isMainWindowPresented: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .revealMacHostTool)) { note in
            guard let pane = MacHostToolReveal.pane(from: note) else { return }
            let revealed = MacHostToolReveal.selection(for: pane)
            selectedSection = revealed.section
            selectedSettingsPane = revealed.pane
        }
        .sheet(isPresented: controlLaunchPresented) {
            MacControlSessionLaunchSheet(store: catalogStore) { target in
                workspaceStore.noteOpenedSession(target)
                selectSessionTarget(target)
            }
        }
    }

    private var controlLaunchPresented: Binding<Bool> {
        Binding(
            get: { catalogStore.controlLaunchDraft != nil },
            set: { isPresented in
                if !isPresented {
                    catalogStore.cancelControlSessionLaunch()
                }
            }
        )
    }

    private var windowTitle: String {
        if selectedSection == .sessionHome, selectedSessionID != nil {
            if let session = sessionTraceStore.session {
                return session.displayTitle
            }
            if let target = sessionTraceStore.selectedTarget {
                return target.summary.session.displayTitle
            }
            if let selectedSessionID,
               let runtime = sessionMonitor.stats?.activeSessions.first(where: {
                   $0.id == selectedSessionID
               }) {
                return runtime.displayTitle
            }
        }
        return selectedSection.title
    }

    private var homeSearchMatches: [MacSessionSearchPresentation.Match]? {
        MacSessionSearchPresentation.matches(
            localTargets: workspaceStore.sessionTargets,
            query: searchText,
            serverResults: searchStore.results,
            completedServerQuery: searchStore.completedServerQuery,
            activeServerQuery: searchStore.activeServerQuery,
            snippetsBySessionId: searchStore.snippetsBySessionId
        )
    }

    private var homeSessionTargets: [MacSelectedSessionTarget] {
        homeSearchMatches?.map(\.target) ?? workspaceStore.sessionTargets
    }

    private var filteredActiveSessions: [StatsActiveSession] {
        MacSessionSearchPresentation.matchingRuntimeSessions(
            sessionMonitor.stats?.activeSessions ?? [],
            query: searchText
        )
    }

    private var firstWorkspaceSessionError: String? {
        workspaceStore.sessionTargets.isEmpty
            ? (workspaceStore.recentSessionsError ?? workspaceStore.sessionErrors.values.first)
            : nil
    }

    private var filteredWorkspaces: [Workspace] {
        let workspaces = workspaceStore.workspaces
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return workspaces }
        return workspaces.filter { workspace in
            workspace.name.localizedCaseInsensitiveContains(trimmed)
                || (workspace.hostMount?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || (workspace.description?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var sidebarSelection: Binding<MacSidebarSelection> {
        Binding(
            get: {
                MacSidebarSelection.from(
                    section: selectedSection,
                    workspaceID: selectedWorkspaceID
                )
            },
            set: { newValue in
                let (section, workspaceID) = newValue.applied(
                    to: selectedSection,
                    workspaceID: selectedWorkspaceID
                )
                selectedSection = section
                selectedWorkspaceID = workspaceID
            }
        )
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                MacSidebarLabel(
                    title: MacSidebarHomeAffordance.home.title,
                    systemImage: MacSidebarHomeAffordance.home.icon
                )
                    .tag(MacSidebarSelection.section(MacSidebarHomeAffordance.home.destination))
                    .help("Show sessions")
                    .accessibilityLabel("Home")
                    .accessibilityHint("Shows the session list")

                ForEach(MacSidebarSection.primaryDestinations.filter { !$0.isDisclosure }) { section in
                    MacSidebarLabel(title: section.title, systemImage: section.icon)
                        .tag(MacSidebarSelection.section(section))
                }
            }

            Section {
                DisclosureGroup(isExpanded: $workspacesExpanded) {
                    MacSidebarLabel(title: "All Workspaces", systemImage: "rectangle.stack")
                        .tag(MacSidebarSelection.section(.workspaces))

                    ForEach(workspaceStore.workspaces) { workspace in
                        MacSidebarLabel(title: workspace.name, systemImage: "folder")
                            .tag(MacSidebarSelection.workspace(workspace.id))
                    }
                } label: {
                    MacSidebarLabel(
                        title: MacSidebarSection.workspaces.title,
                        systemImage: MacSidebarSection.workspaces.icon
                    )
                }
            }

            Section {
                MacSidebarLabel(
                    title: MacSidebarSection.settings.title,
                    systemImage: MacSidebarSection.settings.icon
                )
                    .tag(MacSidebarSelection.section(.settings))
            }
        }
        .listStyle(.sidebar)
        .themedListSurface()
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
    }

    @ViewBuilder
    private var contentList: some View {
        switch selectedSection {
        case .workspaces:
            WorkspaceShellList(
                workspaces: filteredWorkspaces,
                summaries: workspaceStore.summaries,
                isLoading: workspaceStore.isLoading,
                isCreatingWorkspace: workspaceStore.isCreatingWorkspace,
                lastError: workspaceStore.lastError,
                createWorkspaceError: workspaceStore.createWorkspaceError,
                selectedWorkspaceID: $selectedWorkspaceID,
                refresh: { await workspaceStore.loadFromLocalConfig() },
                createWorkspace: { draft in
                    await workspaceStore.createWorkspaceFromLocalConfig(draft)
                },
                beginCreateControlSession: {
                    await catalogStore.beginCreateWorkspaceControlSession()
                }
            )
            .searchable(text: $searchText, prompt: "Search workspaces")
        case .agents, .schedules, .skills, .extensions:
            MacSidebarUtilityList(section: selectedSection)
        case .sessionHome:
            MacHomeSessionList(
                targets: homeSessionTargets,
                searchQuery: $searchText,
                isSearching: searchStore.isSearching,
                searchMatches: homeSearchMatches,
                runtimeSessions: MacHomeSessionSelection.runtimeActivity(
                    targets: workspaceStore.sessionTargets,
                    runtimeSessions: filteredActiveSessions
                ),
                isLoadingWorkspaceSessions: workspaceStore.isLoadingAnySessions,
                workspaceSessionError: firstWorkspaceSessionError,
                sessionActionError: { workspaceStore.sessionActionError(for: $0) },
                isStoppingSession: { workspaceStore.isStoppingSession($0) },
                isDeletingSession: { workspaceStore.isDeletingSession($0) },
                selectedSessionID: homeSelectedSessionID,
                refresh: { await workspaceStore.loadRecentSessionsForLoadedWorkspacesFromLocalConfig() },
                stopTarget: stopSessionTarget,
                deleteTarget: deleteSessionTarget,
                selectTarget: selectSessionTarget
            )
        case .settings:
            MacSettingsList(selection: $selectedSettingsPane)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedSection {
        case .workspaces:
            if let workspace = filteredWorkspaces.first(where: { $0.id == selectedWorkspaceID }) {
                WorkspaceShellDetail(
                    workspace: workspace,
                    summary: workspaceStore.summary(for: workspace.id),
                    sessions: workspaceStore.sessions(for: workspace.id),
                    isLoadingSessions: workspaceStore.isLoadingSessions(for: workspace.id),
                    isCreatingSession: workspaceStore.isCreatingSession,
                    isSavingWorkspace: workspaceStore.isCreatingWorkspace,
                    isDeletingWorkspace: workspaceStore.isDeletingWorkspace(workspace.id),
                    sessionError: workspaceStore.sessionError(for: workspace.id),
                    createSessionError: workspaceStore.createSessionError,
                    editWorkspaceError: workspaceStore.editWorkspaceError,
                    workspaceActionError: workspaceStore.workspaceActionError(for: workspace.id),
                    sessionActionError: { workspaceStore.sessionActionError(for: $0) },
                    isStoppingSession: { workspaceStore.isStoppingSession($0) },
                    isDeletingSession: { workspaceStore.isDeletingSession($0) },
                    refreshSessions: { worktreeId in
                        await workspaceStore.loadSessionsFromLocalConfig(
                            workspaceId: workspace.id,
                            worktreeId: worktreeId
                        )
                    },
                    createSession: { prompt, worktreeId in
                        if let target = await workspaceStore.createSessionFromLocalConfig(
                            workspaceId: workspace.id,
                            prompt: prompt,
                            worktreeId: worktreeId
                        ) {
                            selectSessionTarget(target)
                        }
                    },
                    updateWorkspace: { draft in
                        await workspaceStore.updateWorkspaceFromLocalConfig(id: workspace.id, draft: draft)
                    },
                    beginReviseControlSession: {
                        await catalogStore.beginReviseWorkspaceControlSession(workspace)
                    },
                    deleteWorkspace: {
                        if await workspaceStore.deleteWorkspaceFromLocalConfig(id: workspace.id) {
                            if selectedWorkspaceID == workspace.id {
                                selectedWorkspaceID = nil
                            }
                            if sessionTraceStore.selectedTarget?.workspaceId == workspace.id {
                                selectedSessionID = nil
                                sessionTraceStore.clearSelection()
                            }
                        }
                    },
                    stopSession: { summary in
                        await stopSessionTarget(
                            MacSelectedSessionTarget(
                                workspaceId: workspace.id,
                                sessionId: summary.id,
                                summary: summary
                            )
                        )
                    },
                    deleteSession: { summary in
                        await deleteSessionTarget(
                            MacSelectedSessionTarget(
                                workspaceId: workspace.id,
                                sessionId: summary.id,
                                summary: summary
                            )
                        )
                    },
                    selectSession: { summary in
                        selectSessionTarget(
                            MacSelectedSessionTarget(
                                workspaceId: workspace.id,
                                sessionId: summary.id,
                                summary: summary
                            )
                        )
                    }
                )
            } else {
                MacShellEmptyDetail(
                    title: "Select a workspace",
                    message: "Choose a workspace to see its sessions and files.",
                    systemImage: "folder"
                )
            }
        case .sessionHome:
            switch homeSessionDetail {
            case .trace(let target):
                SessionTraceShellDetail(
                    store: sessionTraceStore,
                    workspace: workspaceStore.workspaces.first(where: {
                        $0.id == target.workspaceId
                    }),
                    isStoppingSession: workspaceStore.isStoppingSession(target.sessionId),
                    stopSession: { await stopSessionTarget(target) }
                )
                .id(target.sessionId)
            case .statsOnly(let selectedSession):
                SessionShellDetail(session: selectedSession)
            case .none:
                MacShellEmptyDetail(
                    title: "Select a session",
                    message: "Choose a session to open the conversation.",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        case .agents, .schedules, .skills, .extensions:
            MacSidebarUtilityDetail(section: selectedSection)
        case .settings:
            SettingsView(
                pane: selectedSettingsPane,
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState,
                sessionMonitor: sessionMonitor,
                remoteServerStore: remoteServerStore,
                checkForUpdates: checkForUpdates
            )
        }
    }

    private var homeSelectedSessionID: Binding<String?> {
        Binding(
            get: { selectedSessionID },
            set: { newValue in
                selectedSessionID = newValue
                applyHomeListSelection(newValue)
            }
        )
    }

    private var homeSelectionTargets: [MacSelectedSessionTarget] {
        let catalog = workspaceStore.sessionTargets
        guard let matches = homeSearchMatches else { return catalog }
        var seen = Set(catalog.map(\.sessionId))
        var combined = catalog
        for match in matches where seen.insert(match.target.sessionId).inserted {
            combined.append(match.target)
        }
        return combined
    }

    private var homeSessionDetail: MacHomeSessionSelection {
        MacHomeSessionSelection.resolve(
            selectedSessionID: selectedSessionID,
            targets: homeSelectionTargets,
            runtimeSessions: sessionMonitor.stats?.activeSessions ?? []
        )
    }

    private func applyHomeListSelection(_ sessionID: String?) {
        switch MacHomeSessionSelection.resolve(
            selectedSessionID: sessionID,
            targets: homeSelectionTargets,
            runtimeSessions: sessionMonitor.stats?.activeSessions ?? []
        ) {
        case .trace(let target):
            sessionTraceStore.select(target)
            selectedSection = .sessionHome
        case .statsOnly:
            sessionTraceStore.clearSelection()
        case .none:
            break
        }
    }

    private func bindHomeTraceIfCatalogHit() {
        guard let target = MacHomeSessionSelection.unboundTraceTarget(
            selectedSessionID: selectedSessionID,
            targets: homeSelectionTargets,
            runtimeSessions: sessionMonitor.stats?.activeSessions ?? [],
            boundSessionID: sessionTraceStore.selectedTarget?.sessionId
        ) else {
            return
        }
        sessionTraceStore.select(target)
        selectedSection = .sessionHome
    }

    private func wireAttentionNotifications() {
        MacAttentionNotificationService.shared.configureForLaunch()
        publishVisibleAttentionSession()
    }

    private func publishVisibleAttentionSession(isMainWindowPresented: Bool = true) {
        MacAttentionNotificationService.shared.activeSessionId = MacAttentionVisibleSession.id(
            section: selectedSection,
            selectedSessionID: selectedSessionID,
            isMainWindowPresented: isMainWindowPresented
        )
    }

    @MainActor
    private func consumePendingSessionDeepLink() async {
        guard let url = pendingSessionDeepLinkURL else { return }
        if let resolvingSessionDeepLinkURL, resolvingSessionDeepLinkURL != url {
            invalidateSessionDeepLinkResolution()
        }

        let sessionID = MacSessionDeepLink.sessionId(from: url)
        let knownIDs = Set(workspaceStore.sessionTargets.map(\.sessionId))
            .union((sessionMonitor.stats?.activeSessions ?? []).map(\.id))
        let destination = MacSessionDeepLinkNavigation.destination(
            sessionId: sessionID,
            knownSessionIDs: knownIDs,
            catalogReady: workspaceStore.hasLoaded && !workspaceStore.isLoadingRecentSessions
        )

        guard destination == .showWorkspaces, let sessionID else {
            if destination != .park {
                invalidateSessionDeepLinkResolution()
            }
            applyPendingSessionDeepLinkDestination(destination)
            return
        }
        guard resolvingSessionDeepLinkURL != url else { return }
        guard let client = MacWorkspaceClient.localOwner() else {
            applyPendingSessionDeepLinkDestination(.showWorkspaces)
            return
        }

        sessionDeepLinkResolutionGeneration &+= 1
        let generation = sessionDeepLinkResolutionGeneration
        resolvingSessionDeepLinkURL = url
        let fetchedDestination = await MacSessionDeepLinkNavigation.fetchedDestination(
            sessionId: sessionID,
            isCurrentRequest: {
                sessionDeepLinkResolutionGeneration == generation
                    && pendingSessionDeepLinkURL == url
            },
            fetchSession: { try await client.getSessionRecord(sessionId: $0) }
        )
        guard sessionDeepLinkResolutionGeneration == generation,
              resolvingSessionDeepLinkURL == url,
              pendingSessionDeepLinkURL == url else {
            return
        }
        resolvingSessionDeepLinkURL = nil
        applyPendingSessionDeepLinkDestination(fetchedDestination)
    }

    private func invalidateSessionDeepLinkResolution() {
        sessionDeepLinkResolutionGeneration &+= 1
        resolvingSessionDeepLinkURL = nil
    }

    private func applyPendingSessionDeepLinkDestination(
        _ destination: MacSessionDeepLinkNavigation.Destination
    ) {
        switch destination {
        case .selectSession(let sessionID):
            pendingSessionDeepLinkURL = nil
            if let target = workspaceStore.target(for: sessionID) {
                selectSessionTarget(target)
            } else {
                selectedSessionID = sessionID
                selectedSection = .sessionHome
                applyHomeListSelection(sessionID)
            }
        case .selectTarget(let target):
            pendingSessionDeepLinkURL = nil
            workspaceStore.noteOpenedSession(target)
            selectSessionTarget(target)
        case .showWorkspaces:
            pendingSessionDeepLinkURL = nil
            selectedSection = .workspaces
            selectedWorkspaceID = nil
            selectedSessionID = nil
            sessionTraceStore.clearSelection()
        case .park:
            break
        case .ignore:
            pendingSessionDeepLinkURL = nil
        }
    }

    private func selectSessionTarget(_ target: MacSelectedSessionTarget) {
        sessionTraceStore.select(target)
        selectedSessionID = target.sessionId
        selectedSection = .sessionHome
    }

    private func stopSessionTarget(_ target: MacSelectedSessionTarget) async {
        if let updatedTarget = await workspaceStore.stopSessionFromLocalConfig(target) {
            sessionTraceStore.select(updatedTarget)
            await sessionTraceStore.loadSelectedFromLocalConfig()
        }
    }

    private func deleteSessionTarget(_ target: MacSelectedSessionTarget) async {
        let didDelete = await workspaceStore.deleteSessionFromLocalConfig(target)
        guard didDelete else { return }
        if selectedSessionID == target.sessionId {
            selectedSessionID = nil
        }
        if sessionTraceStore.selectedTarget?.sessionId == target.sessionId {
            sessionTraceStore.clearSelection()
        }
    }

    private func refreshWorkspaceCatalogAndSessions() async {
        await workspaceStore.loadFromLocalConfig()
        await workspaceStore.loadRecentSessionsForLoadedWorkspacesFromLocalConfig()
    }

    private func updateSessionSearch(_ query: String) {
        guard selectedSection == .sessionHome else {
            searchStore.clear()
            return
        }
        searchStore.search(
            query: query,
            apiClient: MacWorkspaceClient.localOwner()
        )
    }
}
