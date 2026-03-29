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
    @Environment(SessionActivityStore.self) private var activityStore
    @Environment(AppNavigation.self) private var navigation

    @State private var isCreating = false
    @State private var error: String?

    @State private var sessionSearchText = ""
    @State private var searchStore = SessionSearchStore()
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

    /// Whether a root session or any of its descendants match the current search query.
    private func rootOrDescendantMatchesSearch(
        _ session: Session,
        using childIndex: SessionTreeHelper.ChildIndex
    ) -> Bool {
        if matchesSessionSearch(session) { return true }
        return childIndex.allDescendants(of: session.id)
            .contains { matchesSessionSearch($0) }
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
        let yourTurnRoots: [Session]
        let workingRoots: [Session]
        let stoppedRoots: [Session]
        let localFiltered: [LocalSession]
        let wsEmpty: Bool
        /// Pre-built child index for O(1) descendant lookups in row rendering.
        let childIndex: SessionTreeHelper.ChildIndex
    }

    /// Classify a root session into Your Turn / Working / Stopped.
    ///
    /// Priority:
    /// 1. `aggregatePendingCount > 0` → Your Turn (even if parent is busy)
    /// 2. Any descendant working → Working (tree still active)
    /// 3. status == .error → Your Turn
    /// 4. status == .ready → Your Turn
    /// 5. status == .busy / .starting / .stopping → Working
    /// 6. status == .stopped → Stopped
    private enum SessionSection {
        case yourTurn
        case working
        case stopped
    }

    private func classifySession(
        _ session: Session,
        using childIndex: SessionTreeHelper.ChildIndex
    ) -> SessionSection {
        if session.status == .stopped { return .stopped }

        let pendingCount = SessionTreeHelper.aggregatePendingCount(
            of: session.id, in: activeSessions,
            pendingForSession: { permissionStore.pending(for: $0).count }
        )
        if pendingCount > 0 { return .yourTurn }

        // Parent is idle but has working children → tree is still working.
        let descendants = childIndex.allDescendants(of: session.id)
        let workingCount = descendants.filter {
            switch $0.status {
            case .starting, .busy, .stopping: return true
            default: return false
            }
        }.count
        if workingCount > 0 { return .working }

        switch session.status {
        case .error, .ready:
            return .yourTurn
        case .busy, .starting, .stopping:
            return .working
        case .stopped:
            return .stopped
        }
    }

    private var viewData: ViewData {
        let startNs = SessionListPerf.timestampNs()

        let allWorkspaceIds = Set(workspaceSessions.map(\.id))

        // Build child index ONCE for all descendant lookups in this computation.
        // Previously allDescendants() rebuilt Dictionary(grouping:) per call — O(n*m).
        let activeChildIndex = SessionTreeHelper.ChildIndex(sessions: activeSessions)
        let allChildIndex = SessionTreeHelper.ChildIndex(sessions: workspaceSessions)

        // Filter to roots: children accessible through parent's chat view.
        // Searching for a child name surfaces its parent root.
        let allRoots = workspaceSessions.filter { session in
            guard let parentId = session.parentSessionId else { return true }
            return !allWorkspaceIds.contains(parentId)
        }

        // Partition roots into three sections
        var yourTurnUnfiltered: [Session] = []
        var workingUnfiltered: [Session] = []
        var stoppedUnfiltered: [Session] = []

        for root in allRoots {
            switch classifySession(root, using: activeChildIndex) {
            case .yourTurn: yourTurnUnfiltered.append(root)
            case .working: workingUnfiltered.append(root)
            case .stopped: stoppedUnfiltered.append(root)
            }
        }

        // Your Turn: apply search, sort by pending-first then oldest turnEndedDate (FIFO)
        let yourTurnRoots: [Session] = {
            let filtered = hasSessionSearchQuery
                ? yourTurnUnfiltered.filter { rootOrDescendantMatchesSearch($0, using: activeChildIndex) }
                : yourTurnUnfiltered
            return filtered.sorted { lhs, rhs in
                let lhsPending = SessionTreeHelper.aggregatePendingCount(
                    of: lhs.id, in: activeSessions,
                    pendingForSession: { permissionStore.pending(for: $0).count }
                ) > 0
                let rhsPending = SessionTreeHelper.aggregatePendingCount(
                    of: rhs.id, in: activeSessions,
                    pendingForSession: { permissionStore.pending(for: $0).count }
                ) > 0
                if lhsPending != rhsPending { return lhsPending }

                // Within same priority: oldest turnEndedDate first (FIFO queue)
                let lhsDate = sessionStore.turnEndedDate(for: lhs.id) ?? lhs.createdAt
                let rhsDate = sessionStore.turnEndedDate(for: rhs.id) ?? rhs.createdAt
                return lhsDate < rhsDate
            }
        }()

        // Working: apply search, sort newest first
        let workingRoots: [Session] = {
            let filtered = hasSessionSearchQuery
                ? workingUnfiltered.filter { rootOrDescendantMatchesSearch($0, using: activeChildIndex) }
                : workingUnfiltered
            return filtered.sorted { $0.createdAt > $1.createdAt }
        }()

        // Stopped: filter to true roots, apply search, most recently stopped first
        let stoppedSessions = workspaceSessions.filter { $0.status == .stopped }
        let stoppedChildIndex = SessionTreeHelper.ChildIndex(sessions: stoppedSessions)
        let stoppedRoots: [Session] = {
            let roots = stoppedSessions.filter { session in
                guard let parentId = session.parentSessionId else { return true }
                return !allWorkspaceIds.contains(parentId)
            }
            let filtered = hasSessionSearchQuery
                ? roots.filter { rootOrDescendantMatchesSearch($0, using: stoppedChildIndex) }
                : roots
            return filtered.sorted { $0.lastActivity > $1.lastActivity }
        }()

        let activeCount = yourTurnRoots.count + workingRoots.count
        SessionListPerf.recordViewDataCompute(
            startNs: startNs,
            activeCount: activeCount,
            stoppedCount: stoppedRoots.count,
            workspaceId: workspace.id
        )

        return ViewData(
            yourTurnRoots: yourTurnRoots,
            workingRoots: workingRoots,
            stoppedRoots: stoppedRoots,
            localFiltered: filteredLocalSessions,
            wsEmpty: workspaceSessions.isEmpty,
            childIndex: allChildIndex
        )
    }

    var body: some View {
        let data = viewData

        List {
            if !data.yourTurnRoots.isEmpty {
                Section("Your Turn") {
                    ForEach(data.yourTurnRoots) { session in
                        NavigationLink(value: session.id) {
                            sessionRow(for: session, using: data.childIndex)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.themeBg)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await stopSession(session) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.themeOrange)
                        }
                    }
                }
            }

            if !data.workingRoots.isEmpty {
                Section("Working") {
                    ForEach(data.workingRoots) { session in
                        NavigationLink(value: session.id) {
                            sessionRow(for: session, using: data.childIndex)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.themeBg)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await stopSession(session) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.themeOrange)
                        }
                    }
                }
            }

            WorkspaceStoppedSessionsSection(
                stoppedSessions: data.stoppedRoots,
                localSessions: data.localFiltered,
                hasSearchQuery: hasSessionSearchQuery,
                isImportingLocal: isImportingLocal,
                lineageHint: { _ in nil },
                childSummary: { session in
                    childSummary(for: session.id, using: data.childIndex)
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
                      data.yourTurnRoots.isEmpty,
                      data.workingRoots.isEmpty,
                      data.stoppedRoots.isEmpty,
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
        .searchable(text: $sessionSearchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search sessions")
        .onChange(of: sessionSearchText) { _, newValue in
            searchStore.search(
                query: newValue,
                workspaceId: workspace.id,
                apiClient: apiClient
            )
        }
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .navigationDestination(for: FileBrowserNavTarget.self) { target in
            FileBrowserView(workspaceId: target.workspaceId, initialPath: target.path)
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
                NavigationLink(value: FileBrowserNavTarget(workspaceId: workspace.id, path: "")) {
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

    /// Build a SessionRow with computed activity summary for the given session.
    @ViewBuilder
    private func sessionRow(for session: Session, using childIndex: SessionTreeHelper.ChildIndex) -> some View {
        let rowStartNs = SessionListPerf.timestampNs()
        let pending = SessionTreeHelper.aggregatePendingCount(
            of: session.id, in: activeSessions,
            pendingForSession: { permissionStore.pending(for: $0).count }
        )
        let summary = SessionActivitySummary.text(
            session: session,
            pendingCount: pending,
            pendingPermissions: permissionStore.pending(for: session.id),
            activity: activityStore.lastActivity(for: session.id)
        )
        let children = childSummary(for: session.id, using: childIndex)
        let rowMs = Int((SessionListPerf.timestampNs() &- rowStartNs) / 1_000_000)
        let _ = SessionListPerf.recordRowCompute(
            durationMs: rowMs,
            rowCount: 1,
            workspaceId: workspace.id
        )
        SessionRow(
            session: session,
            pendingCount: pending,
            activitySummary: summary,
            children: children,
            searchSnippet: searchStore.snippetsBySessionId[session.id]
        )
    }

    /// Compute child summary for a root session using pre-built child index.
    private func childSummary(
        for sessionId: String,
        using childIndex: SessionTreeHelper.ChildIndex
    ) -> SessionRow.ChildSummary? {
        let descendants = childIndex.allDescendants(of: sessionId)
        guard !descendants.isEmpty else { return nil }

        var counts = SessionTreeHelper.StatusCounts()
        var totalCost = workspaceSessions.first { $0.id == sessionId }?.cost ?? 0
        for desc in descendants {
            counts.total += 1
            switch desc.status {
            case .starting, .busy, .stopping: counts.working += 1
            case .ready: counts.ready += 1
            case .stopped: counts.stopped += 1
            case .error: counts.error += 1
            }
            totalCost += desc.cost
        }

        return .init(
            childCount: descendants.count,
            statusCounts: counts,
            aggregateCost: totalCost
        )
    }

    /// Whether a session matches the current search.
    ///
    /// For short queries (< 3 chars) or while server results are loading,
    /// falls back to local FuzzyMatch on title. Once server results arrive,
    /// uses the server's FTS5 matched set.
    private func matchesSessionSearch(_ session: Session) -> Bool {
        guard hasSessionSearchQuery else {
            return true
        }

        // If server search returned results, use those
        if normalizedSessionSearchQuery.count >= SessionSearchStore.minQueryLength,
           !searchStore.matchedSessionIds.isEmpty {
            return searchStore.matchedSessionIds.contains(session.id)
        }

        // Local fallback: fuzzy match on title
        return FuzzyMatch.match(query: normalizedSessionSearchQuery, candidate: sessionTitle(session)) != nil
    }

    private func sessionTitle(_ session: Session) -> String {
        session.displayTitle
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
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func resumeSession(_ session: Session) async {
        guard let api = apiClient else { return }
        do {
            let updated = try await api.resumeWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            sessionStore.upsert(updated)
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
