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
    /// App-owned snapshot/catalog. This window must not create another copy.
    let workspaceStore: MacWorkspaceSnapshotStore
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
    @State private var paneCommands = MacSessionPaneCommandCenter(
        deck: MacSessionPaneDeck(
            persistence: MacSessionPaneLayoutPersistence(
                windowID: MacAttentionNotificationService.defaultWindowID
            ),
            unresolvedRestoredRoute: .lookup
        )
    )
    @State private var remoteServerStore = MacRemoteServerStore()
    @Bindable private var catalogStore = MacCatalogStore.shared

    init(
        processManager: ServerProcessManager,
        healthMonitor: ServerHealthMonitor,
        permissionState: TCCPermissionState,
        sessionMonitor: MacSessionMonitor,
        workspaceStore: MacWorkspaceSnapshotStore,
        pendingSessionDeepLinkURL: Binding<URL?>,
        checkForUpdates: @escaping @MainActor () -> Void
    ) {
        self.processManager = processManager
        self.healthMonitor = healthMonitor
        self.permissionState = permissionState
        self.sessionMonitor = sessionMonitor
        self.workspaceStore = workspaceStore
        self.checkForUpdates = checkForUpdates
        _pendingSessionDeepLinkURL = pendingSessionDeepLinkURL
    }

    private var paneDeck: MacSessionPaneDeck { paneCommands.deck }

    private var isPaneDeckDisplayed: Bool {
        MacSessionPaneCommandAvailability.isDeckDisplayed(
            section: selectedSection,
            homeDetail: homeSessionDetail
        )
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
            await resolvePendingRestoredSessions()
            await consumePendingSessionDeepLink()
        }
        .onChange(of: selectedSessionID) { _, _ in
            publishVisibleAttentionSession()
        }
        .onChange(of: paneDeck.visibleSessionIDs) { _, _ in
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
        .onChange(of: workspaceStore.sessionTargets.map { "\($0.sessionId):\($0.summary.pendingAskCount)" }) { _, _ in
            MacSessionRestorationCatalog.apply(workspaceStore, to: paneDeck)
            bindHomeTraceIfCatalogHit()
            Task { await consumePendingSessionDeepLink() }
        }
        .onChange(of: searchText) { _, newValue in
            updateSessionSearch(newValue)
        }
        .onChange(of: selectedSection) { _, section in
            if section != .sessionHome {
                paneDeck.cancelAllLiveDictation()
                paneDeck.suspendAllSessionRuntimes()
            }
            publishVisibleAttentionSession()
            updateSessionSearch(searchText)
        }
        .onChange(of: paneDeck.focusedSessionID) { _, sessionID in
            if let sessionID {
                selectedSessionID = sessionID
            }
            publishVisibleAttentionSession()
        }
        .focusedSceneValue(\.macSessionPaneCommands, isPaneDeckDisplayed ? paneCommands : nil)
        .onAppear {
            paneCommands.isDeckDisplayed = isPaneDeckDisplayed
        }
        .onChange(of: isPaneDeckDisplayed) { _, displayed in
            paneCommands.isDeckDisplayed = displayed
        }
        .onDisappear {
            paneDeck.cancelAllLiveDictation()
            paneDeck.suspendAllSessionRuntimes()
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
        .sheet(isPresented: Binding(
            get: { paneCommands.isCheatSheetPresented },
            set: { paneCommands.isCheatSheetPresented = $0 }
        )) {
            MacKeyboardCheatSheetView {
                paneCommands.isCheatSheetPresented = false
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
        if selectedSection == .sessionHome {
            if paneDeck.focusedRuntime?.isEmpty == true {
                return "New Session"
            }
            if let session = paneDeck.focusedRuntime?.traceStore.session {
                return session.displayTitle
            }
            if let target = paneDeck.focusedRuntime?.target {
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
                selectTarget: selectSessionTarget,
                splitRight: { splitSessionTarget($0, axis: .horizontal) },
                splitBelow: { splitSessionTarget($0, axis: .vertical) }
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
                            if paneDeck.remove(workspaceID: workspace.id) > 0 {
                                selectedSessionID = paneDeck.focusedSessionID
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
            if case .statsOnly(let selectedSession) = homeSessionDetail {
                SessionShellDetail(session: selectedSession)
            } else {
                MacSessionPaneDeckView(
                    deck: paneDeck,
                    workspaces: workspaceStore.workspaces,
                    isStoppingSession: { workspaceStore.isStoppingSession($0) },
                    stopTarget: { await stopSessionTarget($0) },
                    loadWorktrees: { workspaceId in
                        guard let client = MacWorkspaceClient.localOwner() else { return [] }
                        return (try? await client.listWorkspaceWorktrees(workspaceId: workspaceId)) ?? []
                    },
                    launchQuickSession: launchQuickSession(from:attempt:),
                    retryRestoration: { runtime in
                        await MacSessionRestorationCatalog.retryDisconnected(
                            paneID: runtime.id,
                            deck: paneDeck,
                            catalog: workspaceStore,
                            client: MacWorkspaceClient.localOwner()
                        )
                    }
                )
                .onDisappear {
                    paneDeck.cancelAllLiveDictation()
                    paneDeck.suspendAllSessionRuntimes()
                }
            }
        case .agents, .schedules, .skills, .extensions:
            MacSidebarUtilityDetail(section: selectedSection, onOpenSession: selectSessionTarget)
        case .settings:
            SettingsView(
                pane: selectedSettingsPane,
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState,
                sessionMonitor: sessionMonitor,
                remoteServerStore: remoteServerStore
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
            _ = paneDeck.openOrFocus(target)
            selectedSection = .sessionHome
        case .statsOnly:
            break
        case .none:
            break
        }
    }

    private func bindHomeTraceIfCatalogHit() {
        guard let target = MacHomeSessionSelection.unboundTraceTarget(
            selectedSessionID: selectedSessionID,
            targets: homeSelectionTargets,
            runtimeSessions: sessionMonitor.stats?.activeSessions ?? [],
            boundSessionID: paneDeck.focusedSessionID
        ) else {
            return
        }
        _ = paneDeck.openOrFocus(target)
        selectedSection = .sessionHome
    }

    private func wireAttentionNotifications() {
        MacAttentionNotificationService.shared.configureForLaunch()
        publishVisibleAttentionSession()
    }

    private func publishVisibleAttentionSession(isMainWindowPresented: Bool = true) {
        MacAttentionNotificationService.shared.publishVisibleSessions(
            windowID: MacAttentionNotificationService.defaultWindowID,
            sessionIDs: MacAttentionVisibleSession.ids(
                section: selectedSection,
                selectedSessionIDs: paneDeck.visibleSessionIDs,
                isMainWindowPresented: isMainWindowPresented
            )
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
        case .park:
            break
        case .ignore:
            pendingSessionDeepLinkURL = nil
        }
    }

    private func selectSessionTarget(_ target: MacSelectedSessionTarget) {
        _ = paneDeck.openOrFocus(target)
        selectedSessionID = target.sessionId
        selectedSection = .sessionHome
    }

    private func splitSessionTarget(_ target: MacSelectedSessionTarget, axis: MacSessionPaneSplitAxis) {
        selectedSection = .sessionHome
        if paneDeck.layout == nil {
            _ = paneDeck.openOrFocus(target)
            return
        }
        switch axis {
        case .horizontal:
            _ = paneDeck.splitFocusedRight(with: target)
        case .vertical:
            _ = paneDeck.splitFocusedBelow(with: target)
        }
        selectedSessionID = paneDeck.focusedSessionID ?? target.sessionId
    }

    private func launchQuickSession(
        from runtime: MacSessionPaneRuntime,
        attempt: MacQuickSessionLaunchAttempt
    ) async {
        guard let client = MacWorkspaceClient.localOwner() else {
            runtime.quickSession.errorMessage = "Local server config is not initialized yet."
            return
        }
        do {
            guard let target = try await MacQuickSessionLauncher.launchIntoOriginatingPane(
                attempt: attempt,
                originatingRuntime: runtime,
                deck: paneDeck,
                client: client
            ) else {
                return
            }
            workspaceStore.noteOpenedSession(target)
            selectedSessionID = paneDeck.focusedSessionID
        } catch {
            runtime.quickSession.errorMessage = error.localizedDescription
        }
    }

    private func stopSessionTarget(_ target: MacSelectedSessionTarget) async {
        if let updatedTarget = await workspaceStore.stopSessionFromLocalConfig(target) {
            _ = paneDeck.updateOpenTarget(updatedTarget)
            _ = await paneDeck.reloadOpenTarget(updatedTarget)
        }
    }

    private func deleteSessionTarget(_ target: MacSelectedSessionTarget) async {
        let didDelete = await workspaceStore.deleteSessionFromLocalConfig(target)
        guard didDelete else { return }
        _ = paneDeck.remove(sessionID: target.sessionId)
        if selectedSessionID == target.sessionId {
            selectedSessionID = paneDeck.focusedSessionID
        }
    }

    private func refreshWorkspaceCatalogAndSessions() async {
        await workspaceStore.loadFromLocalConfig()
        await workspaceStore.loadRecentSessionsForLoadedWorkspacesFromLocalConfig()
    }

    private func resolvePendingRestoredSessions() async {
        await MacSessionRestorationCatalog.resolvePending(
            deck: paneDeck,
            catalog: workspaceStore,
            client: MacWorkspaceClient.localOwner()
        )
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

/// Window-owned restoration/catalog composition. The record lookup is a read.
/// Each still-owned found result is published as the deck accepts it, before
/// a later pane lookup can suspend. The pane observer also applies independent
/// catalog refreshes.
@MainActor
enum MacSessionRestorationCatalog {
    static func lookup(
        route: MacSessionPaneRoute,
        catalog: MacWorkspaceSnapshotStore,
        client: MacWorkspaceClient?
    ) async -> MacSessionPaneRestoredLookup {
        if let target = catalog.target(for: route.sessionID) {
            return .found(target)
        }
        guard let client else { return .disconnected }
        return await MacSessionPaneRestoredLookup.fromSessionRecord {
            try await client.getSessionRecord(sessionId: route.sessionID)
        }
    }

    static func publishAccepted(
        _ targets: [MacSelectedSessionTarget],
        into catalog: MacWorkspaceSnapshotStore
    ) {
        for target in targets {
            catalog.noteOpenedSession(target)
        }
    }

    static func apply(
        _ catalog: MacWorkspaceSnapshotStore,
        to deck: MacSessionPaneDeck
    ) {
        for target in catalog.sessionTargets {
            _ = deck.updateOpenTarget(target)
        }
    }

    static func resolvePending(
        deck: MacSessionPaneDeck,
        catalog: MacWorkspaceSnapshotStore,
        client: MacWorkspaceClient?
    ) async {
        await deck.resolvePendingRestoredSessions(
            lookup: { route in
                await lookup(route: route, catalog: catalog, client: client)
            },
            onAccepted: { target in
                publishAccepted([target], into: catalog)
            }
        )
    }

    static func retryDisconnected(
        paneID: MacSessionPaneID,
        deck: MacSessionPaneDeck,
        catalog: MacWorkspaceSnapshotStore,
        client: MacWorkspaceClient?
    ) async {
        await deck.retryDisconnectedRestoration(
            paneID: paneID,
            lookup: { route in
                await lookup(route: route, catalog: catalog, client: client)
            },
            onAccepted: { target in
                publishAccepted([target], into: catalog)
            }
        )
    }
}
