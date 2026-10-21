import UIKit

/// What the list's controls do: worktree selection, creating, stopping,
/// resuming, deleting, importing, and opening sessions, and the bar actions.
extension WorkspaceDetailViewController {
    func selectWorktree(_ worktree: WorkspaceWorktree) {
        guard state.selectedWorktreeId != worktree.id else { return }
        state.selectedWorktreeId = worktree.id
        resetWorktreeScopedState()
        refreshGitStatusContextBar()
        Task { await refreshWorkspaceData() }
    }

    func loadWorktrees() async {
        guard let api = connection?.apiClient else { return }
        state.isLoadingWorktrees = state.worktrees.isEmpty
        defer { state.isLoadingWorktrees = false }

        do {
            let fetched = try await api.listWorkspaceWorktrees(workspaceId: workspaceId)
            state.worktrees = fetched
            if !fetched.contains(where: { $0.id == state.selectedWorktreeId }) {
                state.selectedWorktreeId = fetched.first?.id ?? WorkspaceWorktree.mainId
                resetWorktreeScopedState()
            }
        } catch {
            // Worktree discovery is best-effort: older servers lack the route, and sandbox
            // workspaces answer 409. Keep the main checkout visible.
            if state.worktrees.isEmpty, let connection {
                state.worktrees = visibleWorktrees(currentWorkspace(connection))
            }
        }
    }

    func visibleWorktrees(_ workspace: Workspace) -> [WorkspaceWorktree] {
        guard state.worktrees.isEmpty else { return state.worktrees }
        return [
            WorkspaceWorktree(
                id: WorkspaceWorktree.mainId,
                name: "Main checkout",
                path: workspace.hostMount ?? "",
                branch: nil,
                headSha: nil,
                isMain: true,
                isGitRepo: false,
                sessionCount: nil
            ),
        ]
    }

    private func resetWorktreeScopedState() {
        state.workspaceRefreshGeneration &+= 1
        state.localSessions = []
        state.archiveBuckets = []
        state.archiveStoppedSessionsByBucketID = [:]
        state.archiveLocalSessionsByBucketID = [:]
        state.loadingArchiveBucketIDs = []
        state.expandedStoppedGroupIDs = []
        state.collapsedStoppedGroupIDs = []
        state.isRefreshingWorkspaceData = false
        state.workspaceLoad = nil
    }

    func autoOpenE2ESessionIfRequested() {
        guard !state.hasAutoOpenedE2ESession,
              let connection,
              let sessionId = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"],
              !sessionId.isEmpty,
              routeWorkspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"]
        else { return }

        state.hasAutoOpenedE2ESession = true
        if let session = workspaceSessions(connection).first(where: { $0.id == sessionId }) {
            openSession(session)
        } else {
            routeToSession(sessionId)
        }
    }

    /// Once per process. Split replaces this screen when a chat replaces the
    /// detail root, so a screen-local flag cannot remember the launch hint.
    @MainActor
    private enum E2EWorkspaceLaunchHintGate {
        static var didCreateSession = false
    }

    func autoCreateE2ESessionIfRequested() async {
        // Split replaces the detail root with the chat, so this screen is gone
        // when Back returns here. A screen-local flag would create and open
        // another session, and the chat would look like it never left.
        guard !E2EWorkspaceLaunchHintGate.didCreateSession,
              !state.hasAutoCreatedE2ESession,
              (ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"] ?? "").isEmpty,
              ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_CREATE_SESSION"] == "1",
              routeWorkspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"]
        else { return }

        E2EWorkspaceLaunchHintGate.didCreateSession = true
        state.hasAutoCreatedE2ESession = true
        await createSession()
    }

    /// Creates a session in this workspace and worktree. Sandbox VM errors
    /// (QEMU unavailable, VM start failure) arrive as standard API errors and
    /// show in the error alert.
    private func createSession() async {
        guard let connection, let api = connection.apiClient else {
            showError("Server is offline — reconnecting in background")
            return
        }
        state.isCreating = true
        clearError()

        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: workspaceId,
                worktreeId: state.selectedWorktreeId
            )
            connection.sessionStore.upsert(response.session)
            state.isCreating = false
            routeToSession(response.session.id)
        } catch {
            showError(error.localizedDescription)
            state.isCreating = false
        }
    }

    /// Stops or resumes; a resumed session leaves its older-history bucket.
    func setRunning(_ running: Bool, _ session: Session) async {
        guard let connection else { return }
        let succeeded = await SessionListLifecycle.setRunning(
            running, session, scope: .workspace(workspaceId), connection: connection
        ) { showError($0) }
        if running, succeeded {
            removeArchiveSession(session.id)
        }
    }

    func confirmDelete(_ session: Session) {
        let id = session.id
        let sourceView = list.cell(forFirstOf: [.session(id), .stoppedSession(id), .archiveSession(id)])
        SessionListAlerts.confirmDelete(session, from: self, sourceView: sourceView) { [weak self] in
            Task { await self?.deleteSession(session) }
        }
    }

    private func deleteSession(_ session: Session) async {
        guard let connection, connection.apiClient != nil else { return }
        removeArchiveSession(session.id)
        await SessionListLifecycle.delete(
            session,
            scope: .workspace(workspaceId),
            serverId: serverId,
            connection: connection,
            drafts: root.composerDraftStore
        ) { showError($0) }
    }

    func openSession(_ session: Session) {
        guard let connection else { return }
        applySearchNavigation(.willOpenDestination)
        let workspace = currentWorkspace(connection)
        var normalized = session
        if normalized.workspaceId == nil || normalized.workspaceId?.isEmpty == true {
            normalized.workspaceId = workspace.id
        }
        if normalized.workspaceName == nil || normalized.workspaceName?.isEmpty == true {
            normalized.workspaceName = workspace.name
        }
        connection.sessionStore.cacheSessionForNavigation(normalized)
        routeToSession(normalized.id)
    }

    func openThread(_ rootSession: Session) {
        applySearchNavigation(.willOpenDestination)
        navigation.openSessionThread(SessionThreadNavTarget(serverId: serverId, rootSessionId: rootSession.id))
    }

    /// Opens the session's chat through `AppNavigation`. The screen always
    /// has its server, so the hosted screen's server-less push of a chat on
    /// the current connection is gone.
    private func routeToSession(_ sessionId: String) {
        let workspace = connection.map { currentWorkspace($0) } ?? routeWorkspace
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: serverId, sessionId: sessionId, workspaceId: workspace.id),
            workspace: WorkspaceNavTarget(serverId: serverId, workspace: workspace)
        )
    }

    func importAndResumeLocal(_ local: LocalSession) async {
        guard let connection, let api = connection.apiClient, !state.isImportingLocal else { return }
        state.isImportingLocal = true
        clearError()

        do {
            let session = try await api.createWorkspaceSessionFromLocal(
                workspaceId: workspaceId,
                piSessionFile: local.path,
                worktreeId: state.selectedWorktreeId
            )
            connection.sessionStore.upsert(session)

            // Remove from local list immediately (server will also filter it on next fetch)
            state.localSessions.removeAll { $0.path == local.path }
            removeArchiveLocalSession(local.path)

            state.isImportingLocal = false
            applySearchNavigation(.willOpenDestination)
            routeToSession(session.id)
        } catch {
            showError("Resume failed: \(error.localizedDescription)")
            state.isImportingLocal = false
        }
    }

    func startQuickSession(dictate: Bool) {
        navigation.presentQuickSession(
            QuickSessionStart(
                context: QuickSessionLaunchContext(
                    serverId: serverId,
                    workspaceId: workspaceId,
                    worktreeId: state.selectedWorktreeId
                ),
                mode: dictate ? .dictation : .message
            ),
            from: .workspaceBar
        )
    }

    func openNowPlaying() {
        guard let player = connection?.audioPlayer else { return }
        SessionListHostedChrome.presentNowPlayingPlayer(player, from: self)
    }

    func openWorkspaceFiles() {
        let target = FileBrowserNavTarget(
            serverId: serverId,
            workspaceId: workspaceId,
            worktreeId: state.selectedWorktreeId,
            path: ""
        )
        ClientLog.info("FileBrowser", "Workspace files toolbar tapped", metadata: [
            "workspaceId": workspaceId,
            "serverId": serverId,
            "presentation": navigation.workspaceNavigationPresentation == .stack ? "stack" : "split",
            "workspaceStackDepth": String(navigation.workspaceStackRouteElements.count),
        ])
        switch navigation.workspaceNavigationPresentation {
        case .stack:
            navigation.openWorkspaceFileBrowser(target)
        case .split:
            let workspace = connection.map { currentWorkspace($0) } ?? routeWorkspace
            navigation.openWorkspaceFileBrowser(target, workspace: WorkspaceNavTarget(serverId: serverId, workspace: workspace))
        }
    }

    func openWorkspaceConfiguration() {
        let workspace = connection.map { currentWorkspace($0) } ?? routeWorkspace
        navigation.openWorkspaceConfiguration(WorkspaceNavTarget(serverId: serverId, workspace: workspace))
    }

    /// "Open Terminal here" from the workspace bar: the workspace's root folder
    /// on the saved SSH host that serves this workspace's server — inside the
    /// host's multiplexer when its Run on Connect command starts one.
    func openWorkspaceTerminal() {
        guard let connection else { return }
        let workspace = currentWorkspace(connection)
        let host = connection.credentials?.host
            ?? root.coordinator.serverStore.servers.first { $0.id == serverId }?.host
            ?? ""
        ClientLog.info("SSHTerminal", "Workspace terminal tapped", metadata: [
            "workspaceId": workspaceId,
            "serverId": serverId,
            "hasHostMount": String(workspace.hostMount != nil),
        ])
        SSHTerminalFolderEntry.open(
            SSHTerminalFolderTarget(
                serverHost: host,
                folder: SSHTerminalFolderTarget.workspace(workspace) ?? "",
                label: workspace.name
            ),
            from: self
        )
    }

    func pullToRefresh() {
        Task { [weak self] in
            guard let self else { return }
            await refreshWorkspaceData()
            list.refreshControl.endRefreshing()
        }
    }
}
