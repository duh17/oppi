import SwiftUI

private struct SessionInboxItem: Identifiable {
    let serverId: String
    let connection: ServerConnection
    let session: Session
    let workspace: Workspace?

    var id: String { "\(serverId):\(session.id)" }
}

private struct SessionInboxViewData {
    let yourTurn: [SessionInboxItem]
    let working: [SessionInboxItem]
    let done: [SessionInboxItem]
    let isEmpty: Bool
}

private struct SessionInboxPendingDelete: Identifiable {
    let serverId: String
    let workspaceId: String
    let session: Session

    var id: String { "\(serverId):\(workspaceId):\(session.id)" }
}

enum WorkspaceCatalogAvailability: Equatable {
    case loading
    case unavailable
    case empty
    case available

    init(hasWorkspaces: Bool, isLoaded: Bool, isSyncing: Bool, lastSyncFailed: Bool) {
        if hasWorkspaces {
            self = .available
        } else if isSyncing {
            self = .loading
        } else if lastSyncFailed {
            self = .unavailable
        } else if isLoaded {
            self = .empty
        } else {
            self = .loading
        }
    }
}

/// Sessions-first home surface.
///
/// The workspace sidebar owns project selection. This view keeps the main
/// content focused on session rows and uses small row context instead of a
/// workspace header card.
struct SessionInboxView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation

    let onOpenSidebar: (() -> Void)?
    let isSidebarPresented: Bool

    @State private var searchText = ""
    @State private var error: String?
    @State private var isCreating = false
    @State private var pendingDelete: SessionInboxPendingDelete?
    @State private var hasAutoOpenedE2EWorkspace = false
    @State private var hasAutoCreatedE2ESession = false
    @State private var hasAutoOpenedE2ESession = false

    init(onOpenSidebar: (() -> Void)? = nil, isSidebarPresented: Bool = false) {
        self.onOpenSidebar = onOpenSidebar
        self.isSidebarPresented = isSidebarPresented
    }

    private var activeServerId: String? {
        coordinator.activeServerId
    }

    private var activeConnection: ServerConnection? {
        activeServerId.flatMap { coordinator.connection(for: $0) }
    }

    private var selectedWorkspace: WorkspaceNavTarget? {
        guard navigation.workspaceNavigationPresentation == .split,
              let activeServerId,
              let filter = navigation.selectedWorkspaceFilter,
              filter.serverId == activeServerId else { return nil }
        return filter
    }

    private var servers: [PairedServer] {
        serverStore.servers
    }

    private var selectedServer: PairedServer? {
        if let activeServerId,
           let server = servers.first(where: { $0.id == activeServerId }) {
            return server
        }
        return servers.first
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var viewData: SessionInboxViewData {
        let items = sessionItems().filter(matchesSearch)
        var yourTurn: [SessionInboxItem] = []
        var working: [SessionInboxItem] = []
        var done: [SessionInboxItem] = []

        for item in items {
            let attention = attentionCounts(for: item)
            switch SessionListPresentation.activeSectionKind(for: item.session, attention: attention) {
            case .yourTurn:
                yourTurn.append(item)
            case .working:
                working.append(item)
            case nil:
                done.append(item)
            }
        }

        yourTurn.sort { lhs, rhs in
            SessionListPresentation.compareYourTurn(
                lhs.session,
                lhsAttention: attentionCounts(for: lhs),
                rhs.session,
                rhsAttention: attentionCounts(for: rhs)
            )
        }
        working.sort { SessionListPresentation.compareWorking($0.session, $1.session) }
        done.sort {
            if $0.session.lastActivity != $1.session.lastActivity {
                return $0.session.lastActivity > $1.session.lastActivity
            }
            return $0.session.id < $1.session.id
        }

        let visibleDone = selectedWorkspace == nil ? [] : done
        return SessionInboxViewData(
            yourTurn: yourTurn,
            working: working,
            done: visibleDone,
            isEmpty: yourTurn.isEmpty && working.isEmpty && visibleDone.isEmpty
        )
    }

    var body: some View {
        let data = viewData

        List {
            if selectedServerRefreshFailed, !data.isEmpty, let selectedServer {
                Section {
                    Label(
                        "Showing cached server data for \(selectedServer.name). Pull to retry.",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.themeOrange)
                    .listRowBackground(Color.themeBg)
                    .accessibilityIdentifier("workspace.sessionList.cachedWarning")
                }
            }

            if !data.yourTurn.isEmpty {
                sessionSection("Your Turn", items: data.yourTurn)
            }

            if !data.working.isEmpty {
                sessionSection("Working", items: data.working)
            }

            if !data.done.isEmpty {
                sessionSection("Done", items: data.done)
            }

            if data.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.themeBg)
                }
            }
        }
        .accessibilityIdentifier("workspace.sessionList")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle(inboxNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbarVisibility(isSidebarPresented ? .hidden : .automatic, for: .navigationBar)
        .toolbarVisibility(isSidebarPresented ? .hidden : .automatic, for: .bottomBar)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search sessions")
        .toolbar { toolbarContent }
        .refreshable {
            await refreshVisibleServer()
        }
        .task(id: activeServerId) {
            await refreshVisibleServer()
            await applyE2ELaunchHintsIfNeeded()
        }
        .task(id: selectedWorkspace?.workspace.id) {
            await applyE2ELaunchHintsIfNeeded()
        }
        .overlay {
            if isCreating {
                ProgressView("Creating session…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                Button("Delete Session", role: .destructive) {
                    let context = pendingDelete
                    self.pendingDelete = nil
                    Task { await deleteSession(context) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let pendingDelete {
                Text(SessionDeleteConfirmationPolicy.deleteMessage(for: pendingDelete.session))
            }
        }
        .navigationDestination(for: WorkspaceSessionNavTarget.self) { target in
            WorkspaceSessionScopedDestinationView(target: target)
        }
        .navigationDestination(for: WorkspaceLinkedFileNavTarget.self) { target in
            WorkspaceLinkedFileDestinationView(target: target)
        }
        .navigationDestination(for: FileBrowserNavTarget.self) { target in
            WorkspaceFileBrowserDestinationView(target: target)
        }
        .navigationDestination(for: WorkspaceConfigurationNavTarget.self) { target in
            WorkspaceConfigurationScopedDestinationView(target: target.workspaceTarget)
        }
        .navigationDestination(for: WorkspaceUtilityNavTarget.self) { target in
            if target.isReleaseEnabled {
                switch target {
                case .schedules:
                    ScheduleManagementView()
                case .agents:
                    AgentManagementView()
                case .manageServers:
                    ServerView()
                case .appSettings:
                    SettingsView()
                }
            } else {
                EmptyView()
            }
        }
    }

    private var inboxNavigationTitle: String {
        selectedWorkspace?.workspace.name ?? "All Sessions"
    }

    @ViewBuilder
    private var inboxTitle: some View {
        if let selectedWorkspace {
            HStack(spacing: 7) {
                WorkspaceRuntimeIcon(workspace: selectedWorkspace.workspace, size: 17, frameSize: 22)
                Text(selectedWorkspace.workspace.name)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.themeFg)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workspace sessions: \(selectedWorkspace.workspace.name)")
            .accessibilityIdentifier("workspace.inbox.title")
        } else {
            Text("All Sessions")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("All Sessions")
                .accessibilityIdentifier("workspace.inbox.title")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            inboxTitle
        }

        ToolbarItem(placement: .topBarLeading) {
            if selectedWorkspace == nil, let onOpenSidebar {
                Button {
                    onOpenSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel("Show workspaces")
                .accessibilityIdentifier("workspace.sidebar.open")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if let selectedWorkspace {
                workspaceConfigurationButton(selectedWorkspace)
            } else if let selectedServer {
                serverSwitcher(selectedServer)
            }
        }

        if let selectedWorkspace {
            ToolbarItem(placement: .bottomBar) {
                workspaceFilesButton(selectedWorkspace)
            }
        }

        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }

        ToolbarItem(placement: .bottomBar) {
            newSessionButton
        }
    }

    private func serverSwitcher(_ current: PairedServer) -> some View {
        Menu {
            ForEach(servers) { server in
                Button {
                    switchVisibleServer(to: server)
                } label: {
                    Label(
                        serverMenuTitle(server),
                        systemImage: server.id == current.id ? "checkmark.circle.fill" : server.resolvedBadgeIcon.symbolName
                    )
                }
                .accessibilityValue(serverBadgeConnectionState(for: server).title)
            }

            Divider()

            Button {
                navigation.openWorkspaceUtility(.manageServers)
            } label: {
                Label("Manage Servers", systemImage: "server.rack")
            }

            Button {
                navigation.openWorkspaceUtility(.appSettings)
            } label: {
                Label("App Settings", systemImage: "gear")
            }
        } label: {
            ServerSwitcherPill(
                server: current,
                connectionState: serverBadgeConnectionState(for: current)
            )
        }
        .accessibilityLabel("Current server: \(current.name)")
        .accessibilityValue(serverBadgeConnectionState(for: current).title)
    }

    private func switchVisibleServer(to server: PairedServer) {
        guard coordinator.switchToServer(server) else { return }
        searchText = ""
        error = nil
        navigation.showAllWorkspaceSessions()
    }

    private func refreshVisibleServer() async {
        guard let activeServerId else { return }
        await coordinator.refreshServer(activeServerId, force: true)
    }

    private func serverMenuTitle(_ server: PairedServer) -> String {
        let state = serverBadgeConnectionState(for: server)
        guard state != .connected else { return server.name }
        return "\(server.name) — \(state.title)"
    }

    private func serverBadgeConnectionState(for server: PairedServer) -> ServerBadgeConnectionState {
        guard let connection = coordinator.connection(for: server.id) else {
            return ServerBadgeConnectionState(serverStatusPresentation(for: server))
        }
        return ServerBadgeConnectionState(
            serverStatusPresentation(for: server),
            hasSyncFailure: connection.workspaceStore.lastSyncFailed
                || connection.sessionStore.lastSyncFailed
        )
    }

    private func serverStatusPresentation(for server: PairedServer) -> WorkspaceServerStatusPresentation {
        if let serverConn = coordinator.connection(for: server.id) {
            return WorkspaceServerStatusPresentation.derive(
                health: serverConn.serverHealth(forServer: server.id)
            )
        }

        return WorkspaceServerStatusPresentation.derive(
            health: ServerHealth.derive(
                freshnessState: .offline,
                freshnessLabel: "Offline",
                transportStates: [.disconnected],
                hasCachedCatalog: !(coordinator.connection(for: server.id)?.workspaceStore.workspaces ?? []).isEmpty
            )
        )
    }

    private var selectedServerRefreshFailed: Bool {
        guard let activeConnection else { return false }
        return activeConnection.workspaceStore.lastSyncFailed
            || activeConnection.sessionStore.lastSyncFailed
    }

    private var selectedServerIsSyncing: Bool {
        activeConnection?.workspaceStore.isSyncing == true
            || activeConnection?.sessionStore.isSyncing == true
    }

    @ViewBuilder
    private var emptyState: some View {
        if activeServerId == nil {
            ContentUnavailableView(
                "No Servers",
                systemImage: "server.rack",
                description: Text("Pair with a server to get started.")
            )
        } else if selectedServerIsSyncing, let selectedServer {
            ContentUnavailableView(
                "Loading Sessions",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("Refreshing \(selectedServer.name)…")
            )
        } else if selectedServerRefreshFailed, let selectedServer {
            ContentUnavailableView {
                Label("Server Data Unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("\(selectedServer.name) couldn't refresh its workspace or session data.")
            } actions: {
                Button("Retry") {
                    Task { await refreshVisibleServer() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let selectedWorkspace {
            ContentUnavailableView(
                "No Sessions",
                systemImage: "terminal",
                description: Text("Start a new session in \(selectedWorkspace.workspace.name).")
            )
        } else {
            ContentUnavailableView(
                "No Active Sessions",
                systemImage: "text.bubble",
                description: Text("No active sessions on \(selectedServer?.name ?? "this server"). Start a quick session or choose a workspace from the sidebar.")
            )
        }
    }

    private func sessionSection(_ title: String, items: [SessionInboxItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                Button {
                    openSession(item)
                } label: {
                    SessionRow(presentation: rowPresentation(for: item))
                }
                .accessibilityIdentifier("session.nav.\(item.session.id)")
                .accessibilityValue(sessionRowAccessibilityValue(for: item))
                .buttonStyle(.plain)
                .listRowBackground(Color.themeBg)
                .swipeActions(edge: .trailing) {
                    sessionSwipeActions(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionSwipeActions(for item: SessionInboxItem) -> some View {
        if item.session.status == .stopped {
            Button {
                Task { await resumeSession(item) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .tint(.themeGreen)

            if let workspaceId = item.session.workspaceId, !workspaceId.isEmpty {
                Button(role: SessionDeleteConfirmationPolicy.swipeButtonRole) {
                    pendingDelete = SessionInboxPendingDelete(
                        serverId: item.serverId,
                        workspaceId: workspaceId,
                        session: item.session
                    )
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.themeRed)
            }
        } else {
            Button {
                Task { await stopSession(item) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.themeOrange)
        }
    }

    private func sessionItems() -> [SessionInboxItem] {
        guard let activeServerId,
              let connection = activeConnection else { return [] }

        let workspaceFilterId = selectedWorkspace?.workspace.id
        return connection.sessionStore.listProjectionSessions.compactMap { session in
            if let workspaceFilterId, session.workspaceId != workspaceFilterId {
                return nil
            }

            let workspace = session.workspaceId.flatMap { workspaceId in
                connection.workspaceStore.workspaces.first { $0.id == workspaceId }
            }
            return SessionInboxItem(
                serverId: activeServerId,
                connection: connection,
                session: session,
                workspace: workspace
            )
        }
    }

    private func matchesSearch(_ item: SessionInboxItem) -> Bool {
        guard !normalizedSearchText.isEmpty else { return true }
        let candidates = [
            item.session.displayTitle,
            item.session.workspaceName,
            item.workspace?.name,
            item.session.model,
            item.session.id,
        ].compactMap { $0?.lowercased() }

        return candidates.contains { $0.localizedStandardContains(normalizedSearchText) }
    }

    private func attentionCounts(for item: SessionInboxItem) -> SessionListAttentionCounts {
        SessionRowPresentationBuilder.attentionCounts(
            sessionId: item.session.id,
            pendingAskCountForSession: { pendingAskCount(for: $0, connection: item.connection) }
        )
    }

    private func pendingAskCount(for sessionId: String, connection: ServerConnection) -> Int {
        SessionListAttentionMerger.askCount(
            listCount: connection.sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: connection.askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    private func rowPresentation(for item: SessionInboxItem) -> SessionRowPresentation {
        let attention = attentionCounts(for: item)
        return SessionRowPresentationBuilder.make(
            session: item.session,
            pendingAskCount: attention.askCount,
            pendingAsk: item.connection.askRequestStore.pending(for: item.session.id),
            workspaceContext: workspaceContext(for: item),
            unreadCompletionAt: item.connection.sessionStore.unreadCompletionDate(for: item.session.id)
        )
    }

    private func workspaceContext(for item: SessionInboxItem) -> String? {
        guard selectedWorkspace == nil else { return nil }
        return item.session.workspaceName ?? item.workspace?.name
    }

    private func sessionRowAccessibilityValue(for item: SessionInboxItem) -> String {
        pendingAskCount(for: item.session.id, connection: item.connection) > 0 ? "Question pending" : ""
    }

    private func openSession(_ item: SessionInboxItem) {
        var normalized = item.session
        if normalized.workspaceId == nil || normalized.workspaceId?.isEmpty == true {
            normalized.workspaceId = item.workspace?.id ?? selectedWorkspace?.workspace.id
        }
        if normalized.workspaceName == nil || normalized.workspaceName?.isEmpty == true {
            normalized.workspaceName = item.workspace?.name ?? selectedWorkspace?.workspace.name
        }
        item.connection.sessionStore.cacheSessionForNavigation(normalized)

        let workspaceTarget = item.workspace.map { WorkspaceNavTarget(serverId: item.serverId, workspace: $0) }
            ?? selectedWorkspace
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: item.serverId,
                sessionId: item.session.id,
                workspaceId: normalized.workspaceId
            ),
            workspace: workspaceTarget
        )
    }

    private func stopSession(_ item: SessionInboxItem) async {
        guard let api = item.connection.apiClient,
              let workspaceId = item.session.workspaceId else { return }
        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspaceId, sessionId: item.session.id)
            item.connection.sessionStore.upsert(updated)
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func resumeSession(_ item: SessionInboxItem) async {
        guard let api = item.connection.apiClient,
              let workspaceId = item.session.workspaceId else { return }
        do {
            let updated = try await api.resumeWorkspaceSession(workspaceId: workspaceId, sessionId: item.session.id)
            item.connection.sessionStore.upsert(updated)
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ pending: SessionInboxPendingDelete) async {
        guard let connection = coordinator.connection(for: pending.serverId),
              let api = connection.apiClient else { return }
        connection.sessionStore.remove(id: pending.session.id)
        await TimelineCache.shared.removeTrace(pending.session.id)
        do {
            try await api.deleteWorkspaceSession(workspaceId: pending.workspaceId, sessionId: pending.session.id)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 { /* ok */ } else {
                self.error = "Delete failed: \(apiError.localizedDescription)"
            }
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
        }
    }

    private var newSessionButton: some View {
        Button {
            if let selectedWorkspace {
                Task { await createSession(in: selectedWorkspace) }
            } else {
                navigation.showQuickSession = true
            }
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .foregroundStyle(.themeFg)
        .accessibilityLabel(selectedWorkspace == nil ? "Start Quick Session" : "New Session")
        .accessibilityIdentifier(selectedWorkspace == nil ? "workspace.quickSession.start" : "workspace.newSession")
        .disabled(isCreating)
        .opacity(isCreating ? 0.55 : 1)
    }

    private func applyE2ELaunchHintsIfNeeded() async {
        autoOpenE2EWorkspaceIfRequested()
        autoOpenE2ESessionIfRequested()
        await autoCreateE2ESessionIfRequested()
    }

    private func autoOpenE2EWorkspaceIfRequested() {
        guard !hasAutoOpenedE2EWorkspace,
              navigation.workspacePath.count == 0,
              let workspaceName = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              !workspaceName.isEmpty,
              let activeServerId,
              let connection = activeConnection,
              let workspace = connection.workspaceStore.workspaces.first(where: { $0.name == workspaceName })
        else { return }

        hasAutoOpenedE2EWorkspace = true
        navigation.openWorkspace(WorkspaceNavTarget(serverId: activeServerId, workspace: workspace))
    }

    private func autoOpenE2ESessionIfRequested() {
        guard !hasAutoOpenedE2ESession,
              let sessionId = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"],
              !sessionId.isEmpty,
              selectedWorkspace?.workspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              let item = sessionItems().first(where: { $0.session.id == sessionId })
        else { return }

        hasAutoOpenedE2ESession = true
        openSession(item)
    }

    private func autoCreateE2ESessionIfRequested() async {
        guard !hasAutoCreatedE2ESession,
              (ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"] ?? "").isEmpty,
              ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_CREATE_SESSION"] == "1",
              selectedWorkspace?.workspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"],
              let selectedWorkspace
        else { return }

        hasAutoCreatedE2ESession = true
        await createSession(in: selectedWorkspace)
    }

    private func createSession(in workspaceTarget: WorkspaceNavTarget) async {
        guard let connection = coordinator.connection(for: workspaceTarget.serverId),
              let api = connection.apiClient else {
            error = "Server is offline — reconnecting in background"
            return
        }

        isCreating = true
        error = nil
        do {
            let response = try await api.createWorkspaceSession(workspaceId: workspaceTarget.workspace.id)
            connection.sessionStore.upsert(response.session)
            isCreating = false
            navigation.openWorkspaceSession(
                WorkspaceSessionNavTarget(
                    serverId: workspaceTarget.serverId,
                    sessionId: response.session.id,
                    workspaceId: workspaceTarget.workspace.id
                ),
                workspace: workspaceTarget
            )
        } catch {
            isCreating = false
            self.error = error.localizedDescription
        }
    }

    private func workspaceFilesButton(_ workspaceTarget: WorkspaceNavTarget) -> some View {
        let target = FileBrowserNavTarget(
            serverId: workspaceTarget.serverId,
            workspaceId: workspaceTarget.workspace.id,
            path: ""
        )

        return Button {
            navigation.openWorkspaceFileBrowser(target, workspace: workspaceTarget)
        } label: {
            Image(systemName: "folder")
        }
        .foregroundStyle(.themeFg)
        .accessibilityIdentifier("workspace.files.open")
        .accessibilityLabel("Open workspace files")
    }

    private func workspaceConfigurationButton(_ workspaceTarget: WorkspaceNavTarget) -> some View {
        Button {
            navigation.openWorkspaceConfiguration(workspaceTarget)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .symbolRenderingMode(.monochrome)
        }
        .foregroundStyle(.themeFg)
        .accessibilityLabel("Edit workspace")
        .accessibilityIdentifier("workspace.edit.open")
    }
}

private struct WorkspaceConfigurationScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    let target: WorkspaceNavTarget

    @State private var scopedConnection: ServerConnection?

    private var resolvedConnection: ServerConnection? {
        scopedConnection ?? coordinator.connection(for: target.serverId)
    }

    var body: some View {
        Group {
            if let connection = resolvedConnection {
                WorkspaceEditView(workspace: target.workspace) {
                    dismissConfiguration()
                }
                .withServerScopedEnvironment(connection)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismissConfiguration)
                            .accessibilityIdentifier("workspace.edit.done")
                    }
                }
            } else {
                ProgressView("Connecting…")
            }
        }
        .onAppear(perform: activateTargetServer)
        .task(id: target.serverId) {
            activateTargetServer()
        }
    }

    @MainActor
    private func activateTargetServer() {
        guard coordinator.switchToServer(target.serverId) else { return }
        scopedConnection = coordinator.connection(for: target.serverId)
    }

    private func dismissConfiguration() {
        guard navigation.workspacePath.count > 0 else { return }
        navigation.workspacePath.removeLast()
    }
}

struct WorkspaceSessionInboxStackRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSidebarOpen = false

    var body: some View {
        let sidebarWidth = min(UIScreen.main.bounds.width * 0.86, 360)

        ZStack(alignment: .leading) {
            SessionInboxView(
                onOpenSidebar: { isSidebarOpen = true },
                isSidebarPresented: isSidebarOpen
            )
            .disabled(isSidebarOpen)
            .accessibilityHidden(isSidebarOpen)
            .navigationDestination(for: WorkspaceNavTarget.self) { target in
                WorkspaceScopedDestinationView(target: target)
            }

            if !isSidebarOpen {
                Color.clear
                    .frame(width: 32)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(sidebarOpenGesture)
                    .accessibilityHidden(true)
                    .zIndex(1)
            }

            if isSidebarOpen {
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .onTapGesture { isSidebarOpen = false }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("workspace.sidebar.scrim")
                    .zIndex(1)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.themeBg)
                        .ignoresSafeArea()

                    WorkspaceSidebarView(
                        onSelect: { isSidebarOpen = false },
                        onDismiss: { isSidebarOpen = false }
                    )
                }
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .shadow(color: .black.opacity(0.35), radius: 24, x: 8, y: 0)
                .transition(ThemeMotion.move(edge: .leading, reduceMotion: reduceMotion))
                .simultaneousGesture(sidebarDismissGesture)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { isSidebarOpen = false }
                .zIndex(2)
            }
        }
        .animation(
            ThemeMotion.easeInOut(duration: 0.22, reduceMotion: reduceMotion),
            value: isSidebarOpen
        )
    }

    private var sidebarOpenGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard horizontal > 70, horizontal > vertical * 1.25 else { return }
                isSidebarOpen = true
            }
    }

    private var sidebarDismissGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard horizontal < -70, abs(horizontal) > vertical * 1.25 else { return }
                isSidebarOpen = false
            }
    }
}

struct WorkspaceSidebarView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @Environment(AppNavigation.self) private var navigation

    var onSelect: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var createSheetContext: WorkspaceCreateSheetContext?
    @State private var pendingCreatedWorkspaceTarget: WorkspaceNavTarget?

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
                    if let selectedServer {
                        let serverId = selectedServer.id
                        let connection = coordinator.connection(for: serverId)
                        let workspaceStore = connection?.workspaceStore
                        let summaries = workspaceStore?.workspaceSummaries(forServer: serverId) ?? [:]
                        let workspaces = sortedWorkspaces(workspacesForServer(serverId), summaries: summaries)
                        let availability = WorkspaceCatalogAvailability(
                            hasWorkspaces: !workspaces.isEmpty,
                            isLoaded: workspaceStore?.isLoaded ?? false,
                            isSyncing: workspaceStore?.isSyncing ?? false,
                            lastSyncFailed: workspaceStore?.lastSyncFailed ?? false
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
                                    Task { await coordinator.refreshServer(serverId, force: true) }
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
                            ForEach(workspaces) { workspace in
                                let target = WorkspaceNavTarget(serverId: serverId, workspace: workspace)
                                let status = workspaceSessionStatus(
                                    workspaceId: workspace.id,
                                    connection: connection
                                )
                                Button {
                                    navigation.openWorkspace(target)
                                    onSelect?()
                                } label: {
                                    WorkspaceSidebarRow(
                                        workspace: workspace,
                                        status: status,
                                        isSelected: navigation.selectedWorkspaceFilter == target
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(WorkspaceHomeView.workspaceOpenAccessibilityIdentifier(workspaceName: workspace.name))
                                .accessibilityLabel("Open \(workspace.name)")
                                .accessibilityValue(status.accessibilityValue)
                            }
                        }
                    } else {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.themeBg.ignoresSafeArea())
        .sheet(item: $createSheetContext, onDismiss: handleCreateSheetDismissed) { context in
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
            Text("Workspaces")
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

    private func newWorkspaceButton(_ selectedServer: PairedServer) -> some View {
        Button {
            presentCreateWorkspace(on: selectedServer)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.themeBlue)

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
            }
        )
    }

    private func sortedWorkspaces(
        _ workspaces: [Workspace],
        summaries: [String: WorkspaceListSummary]
    ) -> [Workspace] {
        workspaces.sorted { lhs, rhs in
            let lhsSummary = summaryForWorkspace(lhs.id, in: summaries)
            let rhsSummary = summaryForWorkspace(rhs.id, in: summaries)

            if lhsSummary.hasAttention != rhsSummary.hasAttention {
                return lhsSummary.hasAttention
            }
            if (lhsSummary.activeCount > 0) != (rhsSummary.activeCount > 0) {
                return lhsSummary.activeCount > 0
            }

            let lhsLatest = lhsSummary.latestActivity ?? .distantPast
            let rhsLatest = rhsSummary.latestActivity ?? .distantPast
            if lhsLatest != rhsLatest {
                return lhsLatest > rhsLatest
            }

            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private func summaryForWorkspace(
        _ workspaceId: String,
        in summaries: [String: WorkspaceListSummary]
    ) -> WorkspaceListSummary {
        summaries[workspaceId] ?? WorkspaceListSummary(
            workspaceId: workspaceId,
            activeCount: 0,
            stoppedCount: 0,
            hasAttention: false
        )
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
    let questionCount: Int
    let errorCount: Int
    let workingCount: Int
    let doneCount: Int

    init(
        sessions: [Session],
        pendingAskCountForSession: (String) -> Int = { _ in 0 }
    ) {
        var questionCount = 0
        var errorCount = 0
        var workingCount = 0
        var doneCount = 0

        for session in sessions {
            switch SessionPillVariant.from(
                session: session,
                pendingAskCount: pendingAskCountForSession(session.id)
            ) {
            case .question:
                questionCount += 1
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

        self.questionCount = questionCount
        self.errorCount = errorCount
        self.workingCount = workingCount
        self.doneCount = doneCount
    }

    var attentionCount: Int {
        questionCount + errorCount
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
            sessionAttentionLabel(questionCount, state: "needs attention", pluralState: "need attention"),
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

private struct WorkspaceSidebarRow: View {
    let workspace: Workspace
    let status: WorkspaceSidebarSessionStatus
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            WorkspaceRuntimeIcon(workspace: workspace, size: 26, frameSize: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)

                if let desc = workspace.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if status.isVisible {
                WorkspaceSidebarSessionStatusIndicator(status: status)
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.themeFg.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
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

    private func metric(symbol: String, count: Int, tint: Color) -> some View {
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
