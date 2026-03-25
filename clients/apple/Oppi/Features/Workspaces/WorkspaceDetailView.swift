import SwiftUI

/// Detail view for a workspace — shows its sessions with management actions.
///
/// Sessions are grouped into active (running/busy/ready) and stopped.
/// Supports creating new sessions, resuming stopped ones, and stopping active ones.
struct WorkspaceDetailView: View {
    let workspace: Workspace

    @Environment(\.apiClient) private var apiClient
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(GitStatusStore.self) private var gitStatusStore
    @Environment(AppNavigation.self) private var navigation

    @State private var isCreating = false
    @State private var error: String?
    @State private var lineageBySessionId: [String: SessionLineageSummary] = [:]
    @State private var sessionSearchText = ""
    @State private var expandedStoppedGroupIDs: Set<String> = []
    @State private var collapsedStoppedGroupIDs: Set<String> = []
    @State private var showEditWorkspace = false
    @State private var showWorkspacePolicy = false
    @State private var localSessions: [LocalSession] = []
    @State private var isImportingLocal = false
    @State private var navigateToSessionId: String?
    @State private var policyFallback: PolicyFallbackDecision = .allow
    @State private var contextBarCollapseToken = 0
    @State private var contextBarExpanded = false
    @State private var contextBarHeight: CGFloat = 0

    private struct SessionLineageSummary {
        let parentSessionName: String?
        let parentSessionStatus: SessionStatus?
        let childForkCount: Int
        let activeChildForkCount: Int
    }

    // MARK: - Computed

    private var normalizedSessionSearchQuery: String {
        sessionSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var hasSessionSearchQuery: Bool {
        !normalizedSessionSearchQuery.isEmpty
    }

    private var policyFallbackIconName: String {
        switch policyFallback {
        case .deny:
            return "lock.fill"
        case .ask:
            return "hand.raised.fill"
        case .allow:
            return "lock.open.fill"
        }
    }

    private var policyFallbackColor: Color {
        switch policyFallback {
        case .deny:
            return .themeRed
        case .ask:
            return .themeOrange
        case .allow:
            return .themeGreen
        }
    }

    /// Current workspace snapshot from the active server store.
    ///
    /// `WorkspaceDetailView` is pushed with a value copy, so without this
    /// lookup the screen can show stale fields after editing (name, icon,
    /// hostMount, model, etc.) until navigating away and back.
    private var currentWorkspace: Workspace {
        guard let currentServerId = workspaceStore.activeServerId,
              let latest = workspaceStore.workspacesByServer[currentServerId]?
                .first(where: { $0.id == workspace.id }) else {
            return workspace
        }
        return latest
    }

    private var workspaceSessions: [Session] {
        sessionStore.sessions.filter { $0.workspaceId == workspace.id }
    }

    private var activeSessions: [Session] {
        workspaceSessions.filter { $0.status != .stopped }
    }

    /// Whether any node in the subtree matches the current search query.
    private func treeMatchesSearch(_ node: SessionTreeHelper.TreeNode) -> Bool {
        if matchesSessionSearch(node.session) { return true }
        return node.children.contains { treeMatchesSearch($0) }
    }

    /// Local pi TUI sessions whose CWD matches this workspace's hostMount.
    ///
    /// The hostMount uses `~` (e.g. `~/workspace/oppi`) while CWD from the server
    /// is absolute (e.g. `/Users/chenda/workspace/oppi`). We match by checking if
    /// the CWD ends with the path after `~/`.
    private var filteredLocalSessions: [LocalSession] {
        guard let mount = currentWorkspace.hostMount, !mount.isEmpty else { return [] }

        // Extract the path suffix after ~/ for matching against absolute CWDs
        let suffix: String
        if mount.hasPrefix("~/") {
            suffix = String(mount.dropFirst(2))  // "workspace/oppi"
        } else if mount.hasPrefix("~") {
            suffix = String(mount.dropFirst(1))   // just "~" means home dir
        } else {
            suffix = mount  // Already absolute — match directly
        }

        return localSessions.filter { local in
            if hasSessionSearchQuery {
                guard FuzzyMatch.match(query: normalizedSessionSearchQuery, candidate: local.displayTitle) != nil else {
                    return false
                }
            }

            if suffix.isEmpty {
                // hostMount is "~" — match any CWD under user's home
                return true
            }

            // Check if CWD ends with the suffix (e.g. "/Users/chenda/workspace/oppi" ends with "workspace/oppi")
            // Also verify a path separator precedes the suffix to avoid partial matches
            if local.cwd == mount { return true }
            if local.cwd.hasSuffix("/" + suffix) { return true }
            if local.cwd.hasSuffix("/" + suffix + "/") { return true }
            // Check subdirectory
            if let range = local.cwd.range(of: "/" + suffix + "/") {
                return range.lowerBound < local.cwd.endIndex
            }
            return false
        }
    }

    // MARK: - Body

    private struct ViewData {
        let rootNodes: [SessionTreeHelper.TreeNode]
        let stopped: [Session]
        let stoppedRootNodesById: [String: SessionTreeHelper.TreeNode]
        let localFiltered: [LocalSession]
        let wsEmpty: Bool
    }

    private var viewData: ViewData {
        // Build tree from all active sessions, then filter roots by search.
        // Searching for a child name surfaces its parent root.
        let allTreeNodes = SessionTreeHelper.buildTree(from: activeSessions)
        let treeNodes = hasSessionSearchQuery
            ? allTreeNodes.filter { treeMatchesSearch($0) }
            : allTreeNodes
        let rootNodes = treeNodes.sorted { lhs, rhs in
            // Sessions with pending permissions (parent or child) float to top
            let lhsAttn = SessionTreeHelper.aggregatePendingCount(
                node: lhs, pendingForSession: { permissionStore.pending(for: $0).count }
            ) > 0
            let rhsAttn = SessionTreeHelper.aggregatePendingCount(
                node: rhs, pendingForSession: { permissionStore.pending(for: $0).count }
            ) > 0
            if lhsAttn != rhsAttn { return lhsAttn }
            let lhsSort = sessionStore.turnEndedDate(for: lhs.session.id) ?? lhs.session.createdAt
            let rhsSort = sessionStore.turnEndedDate(for: rhs.session.id) ?? rhs.session.createdAt
            return lhsSort > rhsSort
        }

        let allStoppedTreeNodes = SessionTreeHelper.buildTree(
            from: workspaceSessions.filter { $0.status == .stopped }
        )
        // Filter out stopped children whose parent exists in any workspace session
        // (active or stopped). Children are only accessible through the parent's chat view.
        let allWorkspaceIds = Set(workspaceSessions.map(\.id))
        let rootStoppedTreeNodes = allStoppedTreeNodes.filter { node in
            guard let parentId = node.session.parentSessionId else { return true }
            return !allWorkspaceIds.contains(parentId)
        }
        let matchingStoppedTreeNodes = hasSessionSearchQuery
            ? rootStoppedTreeNodes.filter { treeMatchesSearch($0) }
            : rootStoppedTreeNodes

        return ViewData(
            rootNodes: rootNodes,
            stopped: matchingStoppedTreeNodes
                .map(\.session)
                .sorted { $0.lastActivity > $1.lastActivity },
            stoppedRootNodesById: Dictionary(
                uniqueKeysWithValues: rootStoppedTreeNodes.map { ($0.session.id, $0) }
            ),
            localFiltered: filteredLocalSessions,
            wsEmpty: workspaceSessions.isEmpty
        )
    }

    var body: some View {
        let data = viewData

        List {
            if !data.rootNodes.isEmpty {
                Section("Active") {
                    ForEach(data.rootNodes) { node in
                        NavigationLink(value: node.session.id) {
                            SessionRow(
                                session: node.session,
                                pendingCount: SessionTreeHelper.aggregatePendingCount(
                                    node: node,
                                    pendingForSession: { permissionStore.pending(for: $0).count }
                                ),
                                children: node.hasChildren ? .init(
                                    childCount: SessionTreeHelper.countAllChildren(node),
                                    statusCounts: SessionTreeHelper.childStatusCounts(node),
                                    aggregateCost: SessionTreeHelper.aggregateCost(node)
                                ) : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.themeBg)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await stopSession(node.session) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.themeOrange)
                        }
                    }
                }
            }

            WorkspaceStoppedSessionsSection(
                stoppedSessions: data.stopped,
                localSessions: data.localFiltered,
                hasSearchQuery: hasSessionSearchQuery,
                isImportingLocal: isImportingLocal,
                lineageHint: { session in lineageHint(for: session) },
                childSummary: { session in
                    guard let node = data.stoppedRootNodesById[session.id], node.hasChildren else {
                        return nil
                    }
                    return .init(
                        childCount: SessionTreeHelper.countAllChildren(node),
                        statusCounts: SessionTreeHelper.childStatusCounts(node),
                        aggregateCost: SessionTreeHelper.aggregateCost(node)
                    )
                },
                onResumeSession: { session in
                    Task { await resumeSession(session) }
                },
                onDeleteSession: { session in
                    Task { await deleteSession(session) }
                },
                onImportLocal: { local in
                    Task { await importAndResumeLocal(local) }
                },
                expandedGroupIDs: $expandedStoppedGroupIDs,
                collapsedGroupIDs: $collapsedStoppedGroupIDs
            )

            if data.wsEmpty {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Tap + to start a new session in this workspace.")
                    )
                    .listRowBackground(Color.themeBg)
                }
            } else if hasSessionSearchQuery,
                      data.rootNodes.isEmpty,
                      data.stopped.isEmpty,
                      data.localFiltered.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Matching Sessions",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different session name.")
                    )
                    .listRowBackground(Color.themeBg)
                }
            }
        }
        .accessibilityIdentifier("workspace.sessionList")
        .listStyle(.insetGrouped)
        .themedListSurface()
        .contentMargins(.top, contextBarHeight, for: .scrollContent)
        .overlay {
            if contextBarExpanded {
                Color.themeBg.opacity(0.5)
                    .onTapGesture { contextBarCollapseToken &+= 1 }
            }
        }
        .overlay(alignment: .top) {
            if let gitStatus = gitStatusStore.gitStatus, gitStatus.isGitRepo, !gitStatus.isClean {
                WorkspaceContextBar(
                    gitStatus: gitStatus,
                    isLoading: false,
                    workspaceId: workspace.id,
                    collapseToken: contextBarCollapseToken,
                    onExpandedChanged: { contextBarExpanded = $0 }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contextBarHeight = $0 }
            }
        }
        .navigationTitle(currentWorkspace.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $sessionSearchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search session name")
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .navigationDestination(
            item: $navigateToSessionId
        ) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await createSession() }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("workspace.newSession")
                .disabled(isCreating)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                NavigationLink {
                    FileBrowserView(workspaceId: workspace.id, initialPath: "")
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(.themeComment)
                }
                Button { showEditWorkspace = true } label: {
                    HStack(spacing: 6) {
                        WorkspaceIcon(icon: currentWorkspace.icon, size: 16)
                            .frame(width: 24, height: 24)
                        if currentWorkspace.runtime == .sandbox {
                            Text("SANDBOX")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.themeOrange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.themeOrange.opacity(0.15), in: Capsule())
                        }
                        Text("\(currentWorkspace.skills.count) skills")
                            .font(.caption2)
                        if let model = currentWorkspace.defaultModel {
                            Text(model.split(separator: "/").last.map(String.init) ?? model)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.themeComment)
                }
                Spacer()
                Button { showWorkspacePolicy = true } label: {
                    Image(systemName: policyFallbackIconName)
                        .foregroundStyle(policyFallbackColor)
                }
            }
        }
        .refreshable {
            await refreshSessions()
            await refreshLocalSessions()
            await refreshPolicyFallback()
        }
        .task {
            await refreshLineage()
            await refreshLocalSessions()
            await refreshPolicyFallback()
            if let api = apiClient {
                gitStatusStore.loadInitial(
                    workspaceId: workspace.id,
                    apiClient: api,
                    gitStatusEnabled: currentWorkspace.gitStatusEnabled ?? true
                )
            }
        }
        .onAppear {
            // Consume pending quick session navigation — pushed by ContentView
            // onDismiss after the workspace target is in the path. We navigate
            // from here instead of a second path push to avoid racing with
            // navigationDestination registration.
            if let pendingId = navigation.quickSessionPendingSessionId {
                navigation.quickSessionPendingSessionId = nil
                navigateToSessionId = pendingId
            }
            Task {
                await refreshSessions()
                await refreshLocalSessions()
                await refreshPolicyFallback()
            }
        }
        .overlay {
            if isCreating || isImportingLocal {
                ProgressView(isImportingLocal ? "Resuming session..." : "Creating session...")
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
        .navigationDestination(isPresented: $showEditWorkspace) {
            WorkspaceEditView(workspace: currentWorkspace)
        }
        .navigationDestination(isPresented: $showWorkspacePolicy) {
            WorkspacePolicyView(workspace: currentWorkspace) { fallback in
                policyFallback = fallback
            }
        }
    }

    private func matchesSessionSearch(_ session: Session) -> Bool {
        guard hasSessionSearchQuery else {
            return true
        }

        return FuzzyMatch.match(query: normalizedSessionSearchQuery, candidate: sessionTitle(session)) != nil
    }

    private func lineageHint(for session: Session) -> String? {
        guard let summary = lineageBySessionId[session.id] else { return nil }

        var parts: [String] = []

        if let parentName = summary.parentSessionName {
            if let parentStatus = summary.parentSessionStatus {
                parts.append("Parent: \(parentName) (\(statusLabel(parentStatus)))")
            } else {
                parts.append("Parent: \(parentName)")
            }
        }

        if summary.childForkCount > 0 {
            let forkLabel = summary.childForkCount == 1 ? "Forks: 1" : "Forks: \(summary.childForkCount)"
            if summary.activeChildForkCount > 0 {
                let activeLabel = summary.activeChildForkCount == 1 ? "1 active" : "\(summary.activeChildForkCount) active"
                parts.append("\(forkLabel) (\(activeLabel))")
            } else {
                parts.append(forkLabel)
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func statusLabel(_ status: SessionStatus) -> String {
        switch status {
        case .starting: return "starting"
        case .ready: return "ready"
        case .busy: return "busy"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .error: return "error"
        }
    }

    private func sessionTitle(_ session: Session) -> String {
        session.displayTitle
    }

    private func refreshLineage() async {
        guard let api = apiClient else { return }

        let sessions = workspaceSessions
        guard !sessions.isEmpty else {
            lineageBySessionId = [:]
            return
        }

        do {
            let graph = try await api.getWorkspaceGraph(workspaceId: workspace.id)
            lineageBySessionId = buildLineageBySessionId(graph: graph, sessions: sessions)
        } catch {
            // Keep latest known lineage hints if graph fetch fails.
        }
    }

    private func buildLineageBySessionId(
        graph: WorkspaceGraphResponse,
        sessions: [Session]
    ) -> [String: SessionLineageSummary] {
        let sessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let nodesById = Dictionary(uniqueKeysWithValues: graph.sessionGraph.nodes.map { ($0.id, $0) })
        let childNodesByParent = Dictionary(grouping: graph.sessionGraph.nodes) { node in
            node.parentId ?? ""
        }

        func preferredSession(for node: WorkspaceGraphResponse.SessionGraph.Node) -> Session? {
            let candidates = node.attachedSessionIds.compactMap { sessionsById[$0] }
            return candidates.max { lhs, rhs in
                let lhsRunning = lhs.status != .stopped
                let rhsRunning = rhs.status != .stopped
                if lhsRunning != rhsRunning {
                    return !lhsRunning && rhsRunning
                }
                return lhs.lastActivity < rhs.lastActivity
            }
        }

        var result: [String: SessionLineageSummary] = [:]

        for node in graph.sessionGraph.nodes {
            let parentSession: Session? = {
                guard let parentId = node.parentId,
                      let parentNode = nodesById[parentId] else {
                    return nil
                }
                return preferredSession(for: parentNode)
            }()

            let childNodes = childNodesByParent[node.id] ?? []
            let childSessionIds = Set(childNodes.flatMap(\.attachedSessionIds))

            for sessionId in node.attachedSessionIds where sessionsById[sessionId] != nil {
                let effectiveParent: Session? = {
                    guard let parentSession else { return nil }
                    return parentSession.id == sessionId ? nil : parentSession
                }()

                let childSessions = childSessionIds
                    .filter { $0 != sessionId }
                    .compactMap { sessionsById[$0] }

                let activeChildForkCount = childSessions.filter { $0.status != .stopped }.count

                let summary = SessionLineageSummary(
                    parentSessionName: effectiveParent.map(sessionTitle),
                    parentSessionStatus: effectiveParent?.status,
                    childForkCount: childSessions.count,
                    activeChildForkCount: activeChildForkCount
                )

                result[sessionId] = summary
            }
        }

        return result
    }

    // MARK: - Actions

    /// Create a new session in this workspace.
    ///
    /// Sandbox VM errors (QEMU unavailable, VM start failure) return as
    /// standard API errors (500/503) and are caught and displayed in the
    /// error alert — no special handling needed.
    private func createSession() async {
        guard let api = apiClient else {
            error = "Server is offline — reconnecting in background"
            return
        }
        isCreating = true
        error = nil

        do {
            let response = try await api.createWorkspaceSession(workspaceId: workspace.id)
            sessionStore.upsert(response.session)
            await refreshLineage()
            isCreating = false
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }

    private func stopSession(_ session: Session) async {
        guard let api = apiClient else { return }
        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            sessionStore.upsert(updated)
            await refreshLineage()
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func resumeSession(_ session: Session) async {
        guard let api = apiClient else { return }
        do {
            let updated = try await api.resumeWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            sessionStore.upsert(updated)
            await refreshLineage()
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ session: Session) async {
        guard let api = apiClient else { return }
        sessionStore.remove(id: session.id)
        do {
            try await api.deleteWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
        } catch let apiError as APIError {
            // 404 means already deleted server-side — local removal above is sufficient.
            if case .server(let status, _) = apiError, status == 404 { /* ok */ } else {
                self.error = "Delete failed: \(apiError.localizedDescription)"
            }
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
        }
        await refreshLineage()
    }

    private func importAndResumeLocal(_ local: LocalSession) async {
        guard let api = apiClient else { return }
        isImportingLocal = true
        error = nil

        do {
            let session = try await api.createWorkspaceSessionFromLocal(
                workspaceId: workspace.id,
                piSessionFile: local.path
            )
            sessionStore.upsert(session)

            // Remove from local list immediately (server will also filter it on next fetch)
            localSessions.removeAll { $0.path == local.path }

            isImportingLocal = false
            navigateToSessionId = session.id
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
            isImportingLocal = false
        }
    }

    private func refreshSessions() async {
        guard let api = apiClient else { return }
        do {
            let sessions = try await api.listWorkspaceSessions(workspaceId: workspace.id)
            for session in sessions {
                sessionStore.upsert(session)
            }
            await refreshLineage()
        } catch {
            // Keep cached data
        }
    }

    private func refreshLocalSessions() async {
        guard let api = apiClient else { return }
        do {
            localSessions = try await api.listLocalSessions()
        } catch {
            // Non-fatal — local sessions are a nice-to-have
        }
    }

    private func refreshPolicyFallback() async {
        guard let api = apiClient else { return }
        do {
            policyFallback = try await api.getPolicyFallback()
        } catch {
            // Non-fatal — use cached/default icon state
        }
    }
}
