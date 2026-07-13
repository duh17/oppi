import Combine
import SwiftUI

extension Notification.Name {
    static let navigateToTab = Notification.Name("OppiMac.navigateToTab")
}

struct MainWindowView: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let permissionState: TCCPermissionState
    let sessionMonitor: MacSessionMonitor
    let checkForUpdates: @MainActor () -> Void

    @State private var selectedSection: MacSidebarSection = .workspaces
    @State private var selectedWorkspaceID: String?
    @State private var selectedSessionID: String?
    @State private var searchText = ""
    @State private var workspaceStore = MacWorkspaceSnapshotStore()
    @State private var sessionTraceStore = MacSessionTraceStore()
    @State private var remoteServerStore = MacRemoteServerStore()

    init(
        processManager: ServerProcessManager,
        healthMonitor: ServerHealthMonitor,
        permissionState: TCCPermissionState,
        sessionMonitor: MacSessionMonitor,
        checkForUpdates: @escaping @MainActor () -> Void
    ) {
        self.processManager = processManager
        self.healthMonitor = healthMonitor
        self.permissionState = permissionState
        self.sessionMonitor = sessionMonitor
        self.checkForUpdates = checkForUpdates
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            contentList
        } detail: {
            detailPane
        }
        .navigationTitle(windowTitle)
        .searchable(text: $searchText, prompt: "Search workspaces and sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                serverStatusLabel
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .task {
            await refreshWorkspaceCatalogAndSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTab)) { note in
            if let section = note.object as? MacSidebarSection {
                selectedSection = section
            }
        }
    }

    private var windowTitle: String {
        switch selectedSection {
        case .workspaces:
            return "Workspaces"
        case .sessions:
            return "Sessions"
        default:
            return selectedSection.title
        }
    }

    private var filteredActiveSessions: [StatsActiveSession] {
        let sessions = sessionMonitor.stats?.activeSessions ?? []
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(trimmed)
                || (session.workspaceName?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || (session.model?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var filteredSessionTargets: [MacSelectedSessionTarget] {
        let targets = workspaceStore.sessionTargets
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return targets }
        return targets.filter { target in
            let session = target.summary.session
            return session.displayTitle.localizedCaseInsensitiveContains(trimmed)
                || (session.workspaceName?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || (session.model?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || target.workspaceId.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var firstWorkspaceSessionError: String? {
        workspaceStore.sessionTargets.isEmpty
            ? workspaceStore.sessionErrors.values.first
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

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedSection) {
            ForEach(MacSidebarGroup.allCases) { group in
                Section(group.title) {
                    ForEach(MacSidebarSection.allCases.filter { $0.group == group }) { section in
                        Label(section.title, systemImage: section.icon)
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
                }
            )
        case .sessions:
            SessionShellList(
                targets: filteredSessionTargets,
                runtimeSessions: filteredActiveSessions,
                isLoadingWorkspaceSessions: workspaceStore.isLoadingAnySessions,
                workspaceSessionError: firstWorkspaceSessionError,
                sessionActionError: { workspaceStore.sessionActionError(for: $0) },
                isStoppingSession: { workspaceStore.isStoppingSession($0) },
                isDeletingSession: { workspaceStore.isDeletingSession($0) },
                selectedSessionID: $selectedSessionID,
                refresh: { await workspaceStore.loadRecentSessionsForLoadedWorkspacesFromLocalConfig() },
                stopTarget: stopSessionTarget,
                deleteTarget: deleteSessionTarget,
                selectTarget: selectSessionTarget
            )
        case .localServer:
            LocalServerShellList(
                processManager: processManager,
                healthMonitor: healthMonitor,
                permissionState: permissionState
            )
        case .remoteServers:
            RemoteServersShellList(
                processManager: processManager,
                healthMonitor: healthMonitor,
                store: remoteServerStore
            )
        case .pairDevices:
            MacToolSummaryList(
                title: "Pair Devices",
                rows: [
                    MacToolSummaryRow(
                        title: "Companion pairing",
                        subtitle: "Generate QR and nearby invites for iPhone or iPad. Optional for Mac use.",
                        systemImage: "qrcode"
                    )
                ]
            )
        case .permissions:
            MacToolSummaryList(
                title: "Permissions",
                rows: permissionState.permissions.map { permission in
                    MacToolSummaryRow(
                        title: permission.name,
                        subtitle: permission.description,
                        systemImage: permission.status == .granted ? "checkmark.circle" : "lock.shield"
                    )
                }
            )
        case .logs:
            MacToolSummaryList(
                title: "Logs",
                rows: [
                    MacToolSummaryRow(
                        title: "Server log stream",
                        subtitle: "\(processManager.logBuffer.count) buffered lines from the local server process.",
                        systemImage: "doc.text"
                    )
                ]
            )
        case .doctor:
            MacToolSummaryList(
                title: "Doctor",
                rows: [
                    MacToolSummaryRow(
                        title: "Local diagnostics",
                        subtitle: "Run server CLI checks for runtime, paths, and process health.",
                        systemImage: "stethoscope"
                    )
                ]
            )
        case .settings:
            MacToolSummaryList(
                title: "Settings",
                rows: [
                    MacToolSummaryRow(
                        title: "Launch and updates",
                        subtitle: "Configure login item behavior, server dependencies, and app updates.",
                        systemImage: "gear"
                    ),
                    MacToolSummaryRow(
                        title: "Runtime paths",
                        subtitle: "Inspect the local Node.js and Oppi server CLI paths.",
                        systemImage: "terminal"
                    )
                ]
            )
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
                    refreshSessions: { await workspaceStore.loadSessionsFromLocalConfig(workspaceId: workspace.id) },
                    createSession: { prompt in
                        if let target = await workspaceStore.createSessionFromLocalConfig(
                            workspaceId: workspace.id,
                            prompt: prompt
                        ) {
                            selectSessionTarget(target)
                        }
                    },
                    updateWorkspace: { draft in
                        await workspaceStore.updateWorkspaceFromLocalConfig(id: workspace.id, draft: draft)
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
                    message: "Workspaces now load from the local server via shared OppiCore DTOs. Session rows are the next snapshot path.",
                    systemImage: "folder"
                )
            }
        case .sessions:
            if let selectedTarget = sessionTraceStore.selectedTarget {
                SessionTraceShellDetail(
                    store: sessionTraceStore,
                    isStoppingSession: workspaceStore.isStoppingSession(selectedTarget.sessionId),
                    stopSession: { await stopSessionTarget(selectedTarget) }
                )
            } else if let selectedSession = filteredActiveSessions.first(where: { $0.id == selectedSessionID }) {
                SessionShellDetail(session: selectedSession)
            } else {
                MacShellEmptyDetail(
                    title: "Select a session",
                    message: "Choose a workspace session to load its trace through shared TimelineReducer state.",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        case .localServer:
            StatusView(
                processManager: processManager,
                healthMonitor: healthMonitor,
                sessionMonitor: sessionMonitor
            )
        case .remoteServers:
            RemoteServersDetail(
                processManager: processManager,
                healthMonitor: healthMonitor,
                store: remoteServerStore
            )
        case .pairDevices:
            PairView()
        case .permissions:
            PermissionsView(permissionState: permissionState)
        case .logs:
            LogsView(processManager: processManager)
        case .doctor:
            DoctorView()
        case .settings:
            SettingsView(
                processManager: processManager,
                checkForUpdates: checkForUpdates
            )
        }
    }

    @ViewBuilder
    private var serverStatusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(serverStatusColor)
                .frame(width: 8, height: 8)
            Text(serverStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Server status: \(serverStatusText)")
    }

    private var serverStatusText: String {
        switch processManager.state {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return processManager.processOwner == .externalProcess ? "Attached" : "Running"
        case .stopping:
            return "Stopping"
        case .failed:
            return "Failed"
        }
    }

    private var serverStatusColor: Color {
        switch processManager.state {
        case .running:
            return .green
        case .starting, .stopping:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func selectSessionTarget(_ target: MacSelectedSessionTarget) {
        sessionTraceStore.select(target)
        selectedSessionID = target.sessionId
        selectedSection = .sessions
    }

    private func stopSessionTarget(_ target: MacSelectedSessionTarget) async {
        if let updatedTarget = await workspaceStore.stopSessionFromLocalConfig(
            workspaceId: target.workspaceId,
            sessionId: target.sessionId
        ) {
            sessionTraceStore.select(updatedTarget)
            await sessionTraceStore.loadSelectedFromLocalConfig()
        }
    }

    private func deleteSessionTarget(_ target: MacSelectedSessionTarget) async {
        let didDelete = await workspaceStore.deleteSessionFromLocalConfig(
            workspaceId: target.workspaceId,
            sessionId: target.sessionId
        )
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
}
