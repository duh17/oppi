import SwiftUI

/// Sort "Your Turn" sessions so the user sees the oldest waiting item first.
///
/// Priority remains ask/input requests before plain ready/error sessions.
/// Within the same priority tier, use the same timestamp shown in the row
/// (`lastActivity`) so the visual order matches the visible "xh ago" label.
func workspaceYourTurnSorted(
    _ sessions: [Session],
    hasAskInQueue: (String) -> Bool
) -> [Session] {
    SessionListPresentation.sortYourTurn(sessions) { sessionId in
        SessionListAttentionCounts(
            askCount: hasAskInQueue(sessionId) ? 1 : 0
        )
    }
}

typealias WorkspaceRefreshPollingPolicy = SessionListRefreshPollingPolicy

/// Detail view for a workspace — shows its sessions with management actions.
///
/// Sessions are grouped into active (running/busy/ready) and stopped.
/// Supports creating new sessions, resuming stopped ones, and stopping active ones.
enum WorkspaceDetailLoadErrorPolicy {
    static func shouldPresent(
        error: any Error,
        workspaceId: String,
        hadVisibleData: Bool,
        knownWorkspaceIds: Set<String>
    ) -> Bool {
        guard !hadVisibleData else { return false }

        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }

        if let apiError = error as? APIError,
           case .server(let status, let message) = apiError,
           status == 404,
           message.localizedCaseInsensitiveContains("Workspace not found"),
           knownWorkspaceIds.contains(workspaceId) {
            return false
        }

        return true
    }
}

enum SessionDeleteConfirmationPolicy {
    static let swipeButtonRole: ButtonRole? = nil

    static func confirm(
        session: Session,
        clearPending: () -> Void,
        performDelete: (Session) -> Void
    ) {
        clearPending()
        performDelete(session)
    }

    static func deleteMessage(for session: Session) -> String {
        "This permanently deletes SQLite session metadata, local pi JSONL trace files for this session, chat attachment copies under .pi/attachments/\(session.id), generated media attachments served by Oppi, and this device's cached timeline copy."
    }
}

private struct SessionDeleteConfirmationModifier: ViewModifier {
    @Binding var pendingSession: Session?
    let onDelete: (Session) -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { pendingSession != nil },
            set: { newValue in
                if !newValue { pendingSession = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete Session?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            if let session = pendingSession {
                Button("Delete Session", role: .destructive) {
                    SessionDeleteConfirmationPolicy.confirm(
                        session: session,
                        clearPending: { pendingSession = nil },
                        performDelete: onDelete
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSession = nil
            }
        } message: {
            if let session = pendingSession {
                Text(SessionDeleteConfirmationPolicy.deleteMessage(for: session))
            }
        }
    }
}

struct WorkspaceDetailView: View {
    #if DEBUG
    nonisolated(unsafe) static var _onWorkspaceLoadErrorForTesting: ((String, String) -> Void)?
    #endif

    let workspace: Workspace

    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AskRequestStore.self) private var askRequestStore
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(GitStatusStore.self) private var gitStatusStore

    @State private var isCreating = false
    @State private var error: String?

    @State private var sessionSearchText = ""
    @State private var searchStore = SessionSearchStore()
    @State private var expandedStoppedGroupIDs: Set<String> = []
    @State private var collapsedStoppedGroupIDs: Set<String> = []
    @State private var showEditWorkspace = false
    @State private var localSessions: [LocalSession] = []
    @State private var worktrees: [WorkspaceWorktree] = []
    @State private var selectedWorktreeId = WorkspaceWorktree.mainId
    @State private var isLoadingWorktrees = false
    @State private var isImportingLocal = false
    @State private var navigateToSessionId: String?
    @State private var pendingDeleteSession: Session?
    @State private var contextBarCollapseToken = 0
    @State private var contextBarExpanded = false
    @State private var contextBarHeight: CGFloat = 0
    @State private var archiveBuckets: [WorkspaceSessionArchiveBucket] = []
    @State private var archiveStoppedSessionsByBucketID: [String: [Session]] = [:]
    @State private var archiveLocalSessionsByBucketID: [String: [LocalSession]] = [:]
    @State private var loadingArchiveBucketIDs: Set<String> = []
    @State private var isRefreshingWorkspaceData = false
    @State private var workspaceRefreshGeneration = 0
    @State private var hasPresentedWorkspaceOnce = false
    @State private var hasAutoCreatedE2ESession = false
    @State private var hasAutoOpenedE2ESession = false
    @State private var workspaceLoad: WorkspaceLoadMeasurement?

    private struct WorkspaceLoadMeasurement {
        let startedAtMs: Int64
        let path: String
        let hadImmediateContent: Bool
    }

    // MARK: - Computed

    /// Detect when the stack is pushing a chat destination so workspace-list
    /// HTTP polling pauses behind focused chat. Do not attach tap gestures to
    /// `NavigationLink` rows for this; that can consume the row activation.
    private var isNavigatingDeeperInWorkspaceStack: Bool {
        navigation.workspacePath.count > 1 || navigateToSessionId != nil
    }

    private var workspaceRefreshPollingTaskId: String {
        "\(workspace.id):\(selectedWorktreeId):\(isNavigatingDeeperInWorkspaceStack ? "covered" : "visible")"
    }

    private var currentServerId: String? {
        connection.currentServerId ?? workspaceStore.activeServerId
    }

    private var normalizedSessionSearchQuery: String {
        sessionSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static let hotStoppedRangeDays = 3

    private var hasSessionSearchQuery: Bool {
        !normalizedSessionSearchQuery.isEmpty
    }

    private func hotStoppedRange(now: Date = Date()) -> (since: Date, until: Date) {
        (since: now.addingTimeInterval(-Double(Self.hotStoppedRangeDays) * 86_400), until: now)
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
        // Keep workspace rows on the cold list projection instead of the full
        // session cache. Timeline-frequency events should not make this view
        // rebuild its section tree.
        sessionStore.listProjectionSessions(workspaceId: workspace.id)
            .filter { ($0.worktreeId ?? WorkspaceWorktree.mainId) == selectedWorktreeId }
    }

    private var activeSessions: [Session] {
        workspaceSessions.filter { $0.status != .stopped }
    }

    /// Importable local pi TUI sessions for this workspace.
    ///
    /// The server owns CWD/hostMount alignment so the client only applies the
    /// visible search filter here.
    private var filteredLocalSessions: [LocalSession] {
        guard hasSessionSearchQuery else { return localSessions }

        return localSessions.filter { local in
            FuzzyMatch.match(query: normalizedSessionSearchQuery, candidate: local.displayTitle) != nil
        }
    }

    // MARK: - Body

    private struct ViewData {
        let yourTurnRoots: [Session]
        let workingRoots: [Session]
        let stoppedRoots: [Session]
        let localFiltered: [LocalSession]
        let wsEmpty: Bool
    }

    /// Classify a session into Your Turn / Working / Stopped.
    ///
    /// Shared with workspace overview previews so attention, idle drafts,
    /// and terminal states move through the same rules.
    private func classifySession(_ session: Session) -> SessionListActiveSectionKind? {
        let attention = SessionRowPresentationBuilder.attentionCounts(
            sessionId: session.id,
            pendingAskCountForSession: { pendingAskCount(for: $0) }
        )

        return SessionListPresentation.activeSectionKind(for: session, attention: attention)
    }

    private var selectedWorktree: WorkspaceWorktree? {
        worktrees.first { $0.id == selectedWorktreeId }
    }

    private var worktreeNavigationTitle: String {
        currentWorkspace.name
    }

    private var selectedWorktreeDisplayName: String {
        selectedWorktree?.displayName ?? "Main"
    }

    private var visibleWorktrees: [WorkspaceWorktree] {
        if worktrees.isEmpty {
            return [
                WorkspaceWorktree(
                    id: WorkspaceWorktree.mainId,
                    name: "Main checkout",
                    path: currentWorkspace.hostMount ?? "",
                    branch: nil,
                    headSha: nil,
                    isMain: true,
                    isGitRepo: false,
                    sessionCount: nil
                ),
            ]
        }
        return worktrees
    }

    private var canSwitchWorktrees: Bool {
        !isLoadingWorktrees && visibleWorktrees.count > 1
    }

    private func worktreeMenuTitle(for worktree: WorkspaceWorktree) -> String {
        let title = WorkspaceWorktreeMenuFormatting.title(for: worktree)
        guard let sessionCount = WorkspaceWorktreeMenuFormatting.sessionCountText(for: worktree) else {
            return title
        }
        return "\(title) · \(sessionCount)"
    }

    @ViewBuilder
    private var worktreeTitleMenu: some View {
        if canSwitchWorktrees {
            Menu {
                Section("Worktree") {
                    ForEach(visibleWorktrees) { worktree in
                        Button {
                            selectWorktree(worktree)
                        } label: {
                            Label {
                                Text(worktreeMenuTitle(for: worktree))
                            } icon: {
                                Image(systemName: selectedWorktreeId == worktree.id ? "checkmark" : worktree.isMain ? "house" : "point.3.connected.trianglepath.dotted")
                            }
                        }
                        .accessibilityLabel(WorkspaceWorktreeMenuFormatting.accessibilityLabel(for: worktree))
                        .accessibilityIdentifier("workspace.worktree.\(worktree.id)")
                    }
                }
            } label: {
                worktreeTitleLabel(showsChevron: true)
                    .accessibilityLabel("Switch worktree, current worktree \(selectedWorktreeDisplayName)")
            }
            .accessibilityIdentifier("workspace.worktree.menu")
        } else {
            worktreeTitleLabel(showsChevron: false)
                .accessibilityLabel("Current worktree \(selectedWorktreeDisplayName)")
                .accessibilityIdentifier("workspace.worktree.title")
        }
    }

    private func worktreeTitleLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            VStack(spacing: 1) {
                Text(currentWorkspace.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                Text(selectedWorktreeDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private var viewData: ViewData {
        let startNs = SessionListPerf.timestampNs()

        var yourTurnUnfiltered: [Session] = []
        var workingUnfiltered: [Session] = []
        var stoppedUnfiltered: [Session] = []

        for session in workspaceSessions {
            switch classifySession(session) {
            case .yourTurn: yourTurnUnfiltered.append(session)
            case .working: workingUnfiltered.append(session)
            case nil: stoppedUnfiltered.append(session)
            }
        }

        // Your Turn: apply search, keep user-input priorities, then oldest visible activity first.
        let yourTurnRoots: [Session] = {
            let filtered = hasSessionSearchQuery
                ? yourTurnUnfiltered.filter(matchesSessionSearch)
                : yourTurnUnfiltered
            return workspaceYourTurnSorted(
                filtered,
                hasAskInQueue: { pendingAskCount(for: $0) > 0 }
            )
        }()

        // Working: apply search, sort newest first
        let workingRoots: [Session] = {
            let filtered = hasSessionSearchQuery
                ? workingUnfiltered.filter(matchesSessionSearch)
                : workingUnfiltered
            return SessionListPresentation.sortWorking(filtered)
        }()

        // Stopped: apply search, most recently stopped first
        let stoppedRoots: [Session] = {
            let filtered = hasSessionSearchQuery
                ? stoppedUnfiltered.filter(matchesSessionSearch)
                : stoppedUnfiltered
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
            wsEmpty: workspaceSessions.isEmpty
        )
    }

    var body: some View {
        let data = viewData

        List {
            if !data.yourTurnRoots.isEmpty {
                Section("Your Turn") {
                    ForEach(data.yourTurnRoots) { session in
                        Button {
                            openSession(session)
                        } label: {
                            sessionRow(for: session)
                        }
                        .accessibilityIdentifier("session.nav.\(session.id)")
                        .accessibilityValue(sessionRowAccessibilityValue(for: session))
                        .buttonStyle(.plain)
                        .listRowBackground(Color.themeBg)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await stopSession(session) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .accessibilityIdentifier("session.stop.\(session.id)")
                            .tint(.themeOrange)
                        }
                    }
                }
            }

            if !data.workingRoots.isEmpty {
                Section("Working") {
                    ForEach(data.workingRoots) { session in
                        Button {
                            openSession(session)
                        } label: {
                            sessionRow(for: session)
                        }
                        .accessibilityIdentifier("session.nav.\(session.id)")
                        .accessibilityValue(sessionRowAccessibilityValue(for: session))
                        .buttonStyle(.plain)
                        .listRowBackground(Color.themeBg)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await stopSession(session) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .accessibilityIdentifier("session.stop.\(session.id)")
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
                sessionPresentation: { session in
                    rowPresentation(for: session)
                },
                onOpenSession: { session in
                    openSession(session)
                },
                onResumeSession: { session in
                    Task { await resumeSession(session) }
                },
                onDeleteSession: { session in
                    pendingDeleteSession = session
                },
                onImportLocal: { local in
                    Task { await importAndResumeLocal(local) }
                },
                expandedGroupIDs: $expandedStoppedGroupIDs,
                collapsedGroupIDs: $collapsedStoppedGroupIDs,
                archiveBuckets: archiveBuckets,
                archiveStoppedSessions: archiveStoppedSessions(for:),
                archiveLocalSessions: archiveLocalSessions(for:),
                loadingArchiveBucketIDs: loadingArchiveBucketIDs,
                onExpandArchiveBucket: { bucket in
                    Task { await ensureArchiveBucketLoaded(bucket) }
                }
            )

            if data.wsEmpty {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Tap the compose button to start a new session in this worktree. Long press for incognito.")
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
            if let gitStatus = gitStatusStore.gitStatus, gitStatus.isGitRepo {
                WorkspaceContextBar(
                    gitStatus: gitStatus,
                    isLoading: false,
                    workspaceId: workspace.id,
                    worktreeId: selectedWorktreeId,
                    showCleanWorkspace: true,
                    collapseToken: contextBarCollapseToken,
                    onExpandedChanged: { contextBarExpanded = $0 }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contextBarHeight = $0 }
            }
        }
        .navigationTitle(worktreeNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbarVisibility(
            WorkspaceSessionNavigationChromePolicy.bottomBarVisibility(on: .sessionList),
            for: .bottomBar
        )
        .onAppear {
            handleViewAppear()
        }
        .onDisappear {
            workspaceLoad = nil
        }
        .onChange(of: isRefreshingWorkspaceData) { _, newValue in
            handleWorkspaceRefreshStateChange(newValue)
        }
        .onChange(of: workspace.id) { _, _ in
            handleWorkspaceIdentityChanged()
        }
        .searchable(text: $sessionSearchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search sessions")
        .onChange(of: sessionSearchText) { _, newValue in
            searchStore.search(
                query: newValue,
                workspaceId: workspace.id,
                apiClient: apiClient
            )
        }
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId, workspaceIdHint: workspace.id)
        }
        .navigationDestination(
            item: $navigateToSessionId
        ) { sessionId in
            ChatView(sessionId: sessionId, workspaceIdHint: workspace.id)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                worktreeTitleMenu
            }
            ToolbarItem(placement: .topBarLeading) {
                workspaceListToolbarItem
            }
            ToolbarItem(placement: .topBarTrailing) {
                workspaceConfigurationButton
            }
            if !isNavigatingDeeperInWorkspaceStack {
                ToolbarItemGroup(placement: .bottomBar) {
                    workspaceFilesToolbarItem
                    Spacer()
                    newSessionToolbarItem
                }
            }
        }
        .refreshable {
            await refreshWorkspaceData()
        }
        .task(id: workspace.id) {
            await loadWorktrees()
            // Start git status immediately so the context bar does not wait for
            // the workspace session-list refresh.
            refreshGitStatusContextBar()

            await refreshWorkspaceData()
            autoOpenE2ESessionIfRequested()
            await autoCreateE2ESessionIfRequested()
        }
        .task(id: workspaceRefreshPollingTaskId) {
            guard !isNavigatingDeeperInWorkspaceStack else { return }
            beginWorkspaceLoadIfNeeded(path: hasPresentedWorkspaceOnce ? "return_from_chat" : "open")
            await refreshWorkspaceData()
            await runWorkspaceRefreshPolling()
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
        .modifier(SessionDeleteConfirmationModifier(pendingSession: $pendingDeleteSession) { session in
            Task { await deleteSession(session) }
        })
        .navigationDestination(isPresented: $showEditWorkspace) {
            WorkspaceEditView(workspace: currentWorkspace)
        }
    }

    /// Build a SessionRow with shared presentation inputs for the given session.
    @ViewBuilder
    private func sessionRow(for session: Session) -> some View {
        let rowStartNs = SessionListPerf.timestampNs()
        let presentation = rowPresentation(for: session)
        let rowMs = Int((SessionListPerf.timestampNs() &- rowStartNs) / 1_000_000)
        let _ = SessionListPerf.recordRowCompute(
            durationMs: rowMs,
            rowCount: 1,
            workspaceId: workspace.id
        )
        SessionRow(presentation: presentation)
    }

    private func rowPresentation(
        for session: Session,
        lineageHint: String? = nil
    ) -> SessionRowPresentation {
        let attention = SessionRowPresentationBuilder.attentionCounts(
            sessionId: session.id,
            pendingAskCountForSession: { pendingAskCount(for: $0) }
        )
        return SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: attention.askCount,
            pendingAsk: askRequestStore.pending(for: session.id),
            lineageHint: lineageHint,
            unreadCompletionAt: sessionStore.unreadCompletionDate(for: session.id),
            searchSnippet: searchStore.snippetsBySessionId[session.id]
        )
    }

    private func sessionRowAccessibilityValue(for session: Session) -> String {
        pendingAskCount(for: session.id) > 0 ? "Question pending" : ""
    }

    private func pendingAskCount(for sessionId: String) -> Int {
        SessionListAttentionMerger.askCount(
            listCount: sessionStore.listPendingAskCount(for: sessionId),
            hasPendingAsk: askRequestStore.hasPending(for: sessionId),
            hasPendingExtensionDialog: connection.hasPendingExtensionDialog(for: sessionId)
        )
    }

    /// Whether a session matches the current search.
    ///
    /// For short queries (< 3 chars), use local FuzzyMatch on title.
    /// For server queries (>= 3 chars), use authoritative server results once
    /// available (including zero-result responses). While a server query is
    /// in-flight, avoid local fallback to prevent stale or misleading matches.
    private func matchesSessionSearch(_ session: Session) -> Bool {
        guard hasSessionSearchQuery else {
            return true
        }

        if normalizedSessionSearchQuery.count >= SessionSearchStore.minQueryLength {
            if searchStore.completedServerQuery == normalizedSessionSearchQuery {
                return searchStore.matchedSessionIds.contains(session.id)
            }

            if searchStore.activeServerQuery == normalizedSessionSearchQuery {
                return false
            }
        }

        // Local fallback: fuzzy match on title
        return FuzzyMatch.match(query: normalizedSessionSearchQuery, candidate: sessionTitle(session)) != nil
    }

    private func sessionTitle(_ session: Session) -> String {
        session.displayTitle
    }

    @ViewBuilder
    private var workspaceFilesToolbarItem: some View {
        if let currentServerId {
            let target = FileBrowserNavTarget(
                serverId: currentServerId,
                workspaceId: workspace.id,
                worktreeId: selectedWorktreeId,
                path: ""
            )

            switch navigation.workspaceNavigationPresentation {
            case .stack:
                Button {
                    ClientLog.info("FileBrowser", "Workspace files toolbar tapped", metadata: [
                        "workspaceId": workspace.id,
                        "serverId": currentServerId,
                        "presentation": "stack",
                        "workspacePathCount": String(navigation.workspacePath.count),
                    ])
                    navigation.openWorkspaceFileBrowser(target)
                } label: {
                    workspaceFilesToolbarLabel
                }
                .accessibilityIdentifier("workspace.files.open")
                .accessibilityLabel("Open workspace files")
            case .split:
                Button {
                    ClientLog.info("FileBrowser", "Workspace files toolbar tapped", metadata: [
                        "workspaceId": workspace.id,
                        "serverId": currentServerId,
                        "presentation": "split",
                        "workspacePathCount": String(navigation.workspacePath.count),
                    ])
                    navigation.openWorkspaceFileBrowser(
                        target,
                        workspace: WorkspaceNavTarget(serverId: currentServerId, workspace: currentWorkspace)
                    )
                } label: {
                    workspaceFilesToolbarLabel
                }
                .accessibilityIdentifier("workspace.files.open")
                .accessibilityLabel("Open workspace files")
            }
        } else {
            Button {} label: {
                workspaceFilesToolbarLabel
            }
            .disabled(true)
            .accessibilityIdentifier("workspace.files.open")
            .accessibilityLabel("Open workspace files")
        }
    }

    private var workspaceFilesToolbarLabel: some View {
        Image(systemName: "folder")
            .foregroundStyle(.themeFg)
    }

    @ViewBuilder
    private var workspaceListToolbarItem: some View {
        if navigation.workspaceNavigationPresentation == .split {
            Button {
                navigation.showWorkspaceListInSplitSidebar()
            } label: {
                Label("Workspaces", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .foregroundStyle(.themeFg)
            .accessibilityLabel("Show workspaces")
            .accessibilityIdentifier("workspace.sidebar.showWorkspaces")
        }
    }

    private var newSessionToolbarItem: some View {
        Button {
            Task { await createSession() }
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .foregroundStyle(.themeFg)
        .contextMenu {
            Button {
                Task { await createSession() }
            } label: {
                Label("New Session", systemImage: "square.and.pencil")
            }

            Button {
                Task { await createSession(ephemeral: true) }
            } label: {
                Label("Incognito Session", systemImage: "eye.slash")
            }
        }
        .accessibilityLabel("New Session")
        .accessibilityIdentifier("workspace.newSession")
        .disabled(isCreating)
    }

    private var workspaceConfigurationButton: some View {
        Button {
            switch navigation.workspaceNavigationPresentation {
            case .stack:
                showEditWorkspace = true
            case .split:
                if let currentServerId {
                    navigation.openWorkspaceConfiguration(
                        WorkspaceNavTarget(serverId: currentServerId, workspace: currentWorkspace)
                    )
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.themeFg)
        }
        .accessibilityLabel(workspaceConfigurationAccessibilityLabel)
        .accessibilityIdentifier("workspace.edit.open")
    }

    private var workspaceConfigurationAccessibilityLabel: String {
        let workspaceKind = currentWorkspace.runtime == .sandbox ? "sandbox workspace" : "workspace"
        return "Edit \(workspaceKind)"
    }

    // MARK: - Actions

    private func selectWorktree(_ worktree: WorkspaceWorktree) {
        guard selectedWorktreeId != worktree.id else { return }
        selectedWorktreeId = worktree.id
        resetWorktreeScopedState()
        refreshGitStatusContextBar()
        Task { await refreshWorkspaceData() }
    }

    private func loadWorktrees() async {
        guard let api = apiClient else { return }
        isLoadingWorktrees = worktrees.isEmpty
        defer { isLoadingWorktrees = false }

        do {
            let fetched = try await api.listWorkspaceWorktrees(workspaceId: workspace.id)
            worktrees = fetched
            if !fetched.contains(where: { $0.id == selectedWorktreeId }) {
                selectedWorktreeId = fetched.first?.id ?? WorkspaceWorktree.mainId
                resetWorktreeScopedState()
            }
        } catch {
            // Worktree discovery is best-effort for older servers. Keep the main checkout visible.
            if worktrees.isEmpty {
                worktrees = visibleWorktrees
            }
        }
    }

    private func resetWorktreeScopedState() {
        workspaceRefreshGeneration &+= 1
        localSessions = []
        archiveBuckets = []
        archiveStoppedSessionsByBucketID = [:]
        archiveLocalSessionsByBucketID = [:]
        loadingArchiveBucketIDs = []
        expandedStoppedGroupIDs = []
        collapsedStoppedGroupIDs = []
        isRefreshingWorkspaceData = false
        workspaceLoad = nil
    }

    private func autoOpenE2ESessionIfRequested() {
        guard !hasAutoOpenedE2ESession,
              let sessionId = ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"],
              !sessionId.isEmpty,
              workspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"]
        else { return }

        hasAutoOpenedE2ESession = true
        if let session = workspaceSessions.first(where: { $0.id == sessionId }) {
            openSession(session)
        } else {
            routeToSession(sessionId)
        }
    }

    /// Create a new session in this workspace.
    ///
    /// Sandbox VM errors (QEMU unavailable, VM start failure) return as
    /// standard API errors (500/503) and are caught and displayed in the
    /// error alert — no special handling needed.
    private func autoCreateE2ESessionIfRequested() async {
        guard !hasAutoCreatedE2ESession,
              (ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_SESSION_ID"] ?? "").isEmpty,
              ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_CREATE_SESSION"] == "1",
              workspace.name == ProcessInfo.processInfo.environment["OPPI_E2E_AUTO_OPEN_WORKSPACE"]
        else { return }

        hasAutoCreatedE2ESession = true
        await createSession()
    }

    private func createSession(ephemeral: Bool = false) async {
        guard let api = apiClient else {
            error = "Server is offline — reconnecting in background"
            return
        }
        isCreating = true
        error = nil

        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: workspace.id,
                ephemeral: ephemeral ? true : nil,
                worktreeId: selectedWorktreeId
            )
            sessionStore.upsert(response.session)
            isCreating = false
            routeToSession(response.session.id)
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
            removeArchiveSession(session.id)
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ session: Session) async {
        guard let api = apiClient else { return }
        sessionStore.remove(id: session.id)
        removeArchiveSession(session.id)
        await TimelineCache.shared.removeTrace(session.id)
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

    private func openSession(_ session: Session) {
        var normalized = session
        if normalized.workspaceId == nil || normalized.workspaceId?.isEmpty == true {
            normalized.workspaceId = currentWorkspace.id
        }
        if normalized.workspaceName == nil || normalized.workspaceName?.isEmpty == true {
            normalized.workspaceName = currentWorkspace.name
        }
        sessionStore.cacheSessionForNavigation(normalized)
        routeToSession(normalized.id)
    }

    private func routeToSession(_ sessionId: String) {
        guard let currentServerId else {
            navigateToSessionId = sessionId
            return
        }

        let workspaceTarget = WorkspaceNavTarget(serverId: currentServerId, workspace: currentWorkspace)
        let sessionTarget = WorkspaceSessionNavTarget(
            serverId: currentServerId,
            sessionId: sessionId,
            workspaceId: currentWorkspace.id
        )

        if navigation.workspaceNavigationPresentation == .stack {
            var path = NavigationPath()
            path.append(workspaceTarget)
            path.append(sessionTarget)
            navigation.workspacePath = path
            return
        }

        navigation.openWorkspaceSession(
            sessionTarget,
            workspace: workspaceTarget
        )
    }

    private func importAndResumeLocal(_ local: LocalSession) async {
        guard let api = apiClient else { return }
        isImportingLocal = true
        error = nil

        do {
            let session = try await api.createWorkspaceSessionFromLocal(
                workspaceId: workspace.id,
                piSessionFile: local.path,
                worktreeId: selectedWorktreeId
            )
            sessionStore.upsert(session)

            // Remove from local list immediately (server will also filter it on next fetch)
            localSessions.removeAll { $0.path == local.path }
            removeArchiveLocalSession(local.path)

            isImportingLocal = false
            routeToSession(session.id)
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
            isImportingLocal = false
        }
    }

    private func isArchiveBucketGroupID(_ id: String) -> Bool {
        id.hasPrefix("day:") || id.hasPrefix("month:")
    }

    private func pruneArchiveState(validBucketIDs: Set<String>) {
        archiveStoppedSessionsByBucketID = archiveStoppedSessionsByBucketID.filter { validBucketIDs.contains($0.key) }
        archiveLocalSessionsByBucketID = archiveLocalSessionsByBucketID.filter { validBucketIDs.contains($0.key) }
        loadingArchiveBucketIDs = loadingArchiveBucketIDs.filter { validBucketIDs.contains($0) }
        expandedStoppedGroupIDs = expandedStoppedGroupIDs.filter { validBucketIDs.contains($0) || !isArchiveBucketGroupID($0) }
        collapsedStoppedGroupIDs = collapsedStoppedGroupIDs.filter { validBucketIDs.contains($0) || !isArchiveBucketGroupID($0) }
    }

    private func archiveStoppedSessions(for bucket: WorkspaceSessionArchiveBucket) -> [Session] {
        archiveStoppedSessionsByBucketID[bucket.id] ?? []
    }

    private func archiveLocalSessions(for bucket: WorkspaceSessionArchiveBucket) -> [LocalSession] {
        archiveLocalSessionsByBucketID[bucket.id] ?? []
    }

    private func ensureArchiveBucketLoaded(_ bucket: WorkspaceSessionArchiveBucket) async {
        if archiveStoppedSessionsByBucketID[bucket.id] != nil || archiveLocalSessionsByBucketID[bucket.id] != nil {
            return
        }
        guard !loadingArchiveBucketIDs.contains(bucket.id) else { return }
        guard let api = apiClient else { return }

        loadingArchiveBucketIDs.insert(bucket.id)
        defer { loadingArchiveBucketIDs.remove(bucket.id) }

        do {
            let response = try await api.getWorkspaceSessionListBucket(
                workspaceId: workspace.id,
                since: bucket.startAt,
                until: bucket.endAt,
                worktreeId: selectedWorktreeId
            )
            archiveStoppedSessionsByBucketID[bucket.id] = response.sessionSummaries
                .map(\.session)
                .filter { session in
                    session.status == .stopped &&
                        session.lastActivity >= bucket.startAt &&
                        session.lastActivity < bucket.endAt
                }
            archiveLocalSessionsByBucketID[bucket.id] = response.importableSessions
        } catch {
            self.error = "Failed to load older sessions: \(error.localizedDescription)"
        }
    }

    private func updateArchiveBucketCounts(
        bucketId: String,
        removedManagedStoppedCount: Int = 0,
        removedImportableLocalCount: Int = 0
    ) {
        guard let index = archiveBuckets.firstIndex(where: { $0.id == bucketId }) else { return }
        archiveBuckets[index].managedStoppedCount = max(
            0,
            archiveBuckets[index].managedStoppedCount - removedManagedStoppedCount
        )
        archiveBuckets[index].importableLocalCount = max(
            0,
            archiveBuckets[index].importableLocalCount - removedImportableLocalCount
        )
        archiveBuckets[index].itemCount = max(
            0,
            archiveBuckets[index].itemCount - removedManagedStoppedCount - removedImportableLocalCount
        )
        if archiveBuckets[index].itemCount == 0 {
            let bucketId = archiveBuckets[index].id
            archiveBuckets.remove(at: index)
            archiveStoppedSessionsByBucketID.removeValue(forKey: bucketId)
            archiveLocalSessionsByBucketID.removeValue(forKey: bucketId)
            expandedStoppedGroupIDs.remove(bucketId)
            collapsedStoppedGroupIDs.remove(bucketId)
        }
    }

    private func removeArchiveSession(_ sessionId: String) {
        for (bucketId, sessions) in archiveStoppedSessionsByBucketID {
            if sessions.contains(where: { $0.id == sessionId }) {
                archiveStoppedSessionsByBucketID[bucketId] = sessions.filter { $0.id != sessionId }
                updateArchiveBucketCounts(bucketId: bucketId, removedManagedStoppedCount: 1)
                break
            }
        }
    }

    private func removeArchiveLocalSession(_ path: String) {
        for (bucketId, sessions) in archiveLocalSessionsByBucketID {
            if sessions.contains(where: { $0.path == path }) {
                archiveLocalSessionsByBucketID[bucketId] = sessions.filter { $0.path != path }
                updateArchiveBucketCounts(bucketId: bucketId, removedImportableLocalCount: 1)
                break
            }
        }
    }

    private func runWorkspaceRefreshPolling() async {
        var policy = WorkspaceRefreshPollingPolicy()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Int.random(in: 10...15)))
            guard !Task.isCancelled else { break }

            let state = workspacePollingState()
            guard policy.shouldRefresh(
                hasActiveWork: state.hasActiveWork,
                hasAttention: state.hasAttention
            ) else {
                continue
            }

            await refreshWorkspaceData()
        }
    }

    private func workspacePollingState() -> (hasActiveWork: Bool, hasAttention: Bool) {
        let sessions = workspaceSessions
        let sessionIds = Set(sessions.map(\.id))
        let hasActiveWork = sessions.contains { session in
            switch session.status {
            case .starting, .busy, .stopping:
                return true
            case .ready, .stopped, .error:
                return false
            }
        }
        let hasAskAttention = sessions.contains { pendingAskCount(for: $0.id) > 0 }
            || askRequestStore.pending.values.contains { ask in
                ask.workspaceId == workspace.id ||
                    (ask.workspaceId == nil && sessionIds.contains(ask.sessionId))
            }

        return (
            hasActiveWork: hasActiveWork,
            hasAttention: hasAskAttention
        )
    }

    private func refreshWorkspaceData() async {
        guard !isRefreshingWorkspaceData else { return }
        let requestedWorkspaceId = workspace.id
        let requestedGeneration = workspaceRefreshGeneration
        isRefreshingWorkspaceData = true
        defer {
            if requestedGeneration == workspaceRefreshGeneration {
                isRefreshingWorkspaceData = false
            }
        }

        guard let api = apiClient else { return }
        let hadVisibleData = !workspaceSessions.isEmpty || !localSessions.isEmpty || !archiveBuckets.isEmpty

        do {
            let startedAt = Date()
            let range = hotStoppedRange(now: startedAt)
            let response = try await api.getWorkspaceSessionList(
                workspace: workspace,
                since: range.since,
                until: range.until,
                worktreeId: selectedWorktreeId
            )
            guard !Task.isCancelled,
                  requestedGeneration == workspaceRefreshGeneration else { return }

            sessionStore.applyWorkspaceRecentSnapshot(
                workspaceId: requestedWorkspaceId,
                summaries: response.sessionSummaries,
                requestStartedAt: startedAt
            )
            archiveBuckets = response.archiveBuckets
            pruneArchiveState(validBucketIDs: Set(response.archiveBuckets.map(\.id)))
            localSessions = response.importableSessions
            connection.applyWorkspaceAttentionSnapshot(
                APIClient.WorkspaceAttentionResponse(
                    workspaceId: requestedWorkspaceId,
                    serverNow: response.serverNow,
                    attention: response.attention
                )
            )
            if error?.hasPrefix("Failed to load workspace:") == true {
                error = nil
            }
        } catch {
            guard !Task.isCancelled,
                  requestedGeneration == workspaceRefreshGeneration else { return }
            let knownWorkspaceIds = Set(workspaceStore.workspaces.map(\.id))
            if WorkspaceDetailLoadErrorPolicy.shouldPresent(
                error: error,
                workspaceId: requestedWorkspaceId,
                hadVisibleData: hadVisibleData,
                knownWorkspaceIds: knownWorkspaceIds
            ) {
                let message = "Failed to load workspace: \(error.localizedDescription)"
                #if DEBUG
                Self._onWorkspaceLoadErrorForTesting?(requestedWorkspaceId, message)
                #endif
                self.error = message
            }
        }
    }

    @MainActor
    private func handleWorkspaceIdentityChanged() {
        workspaceRefreshGeneration &+= 1
        error = nil
        localSessions = []
        worktrees = []
        selectedWorktreeId = WorkspaceWorktree.mainId
        archiveBuckets = []
        archiveStoppedSessionsByBucketID = [:]
        archiveLocalSessionsByBucketID = [:]
        loadingArchiveBucketIDs = []
        isRefreshingWorkspaceData = false
        workspaceLoad = nil
    }

    @MainActor
    private func handleViewAppear() {
        let path = hasPresentedWorkspaceOnce ? "return_from_chat" : "open"
        beginWorkspaceLoadIfNeeded(path: path)
        hasPresentedWorkspaceOnce = true
        refreshGitStatusContextBar()

        if workspaceLoad?.hadImmediateContent == true {
            scheduleWorkspaceLoadCompletionCheck()
        }
    }

    @MainActor
    private func refreshGitStatusContextBar() {
        // GitStatusStore is connection-scoped, so returning from a chat can leave
        // the workspace list showing the last pushed status until REST refreshes it.
        guard let api = apiClient else { return }
        gitStatusStore.loadInitial(
            workspaceId: workspace.id,
            worktreeId: selectedWorktreeId,
            apiClient: api,
            gitStatusEnabled: currentWorkspace.gitStatusEnabled ?? true
        )
    }

    @MainActor
    private func handleWorkspaceRefreshStateChange(_ isRefreshing: Bool) {
        guard !isRefreshing else { return }
        scheduleWorkspaceLoadCompletionCheck()
    }

    @MainActor
    private func beginWorkspaceLoadIfNeeded(path: String) {
        guard workspaceLoad == nil else { return }
        workspaceLoad = WorkspaceLoadMeasurement(
            startedAtMs: Date.nowMs(),
            path: path,
            hadImmediateContent: !workspaceSessions.isEmpty || !localSessions.isEmpty
        )
    }

    @MainActor
    private func scheduleWorkspaceLoadCompletionCheck() {
        Task { @MainActor in
            await Task.yield()
            finishWorkspaceLoadIfReady()
        }
    }

    @MainActor
    private func finishWorkspaceLoadIfReady() {
        guard let workspaceLoad else { return }
        if !workspaceLoad.hadImmediateContent, isRefreshingWorkspaceData {
            return
        }

        ChatSessionTelemetry.recordTimingMetric(
            .workspaceLoadMs,
            durationMs: Date.nowMs() - workspaceLoad.startedAtMs,
            workspaceId: workspace.id,
            tags: ["path": workspaceLoad.path]
        )
        self.workspaceLoad = nil
    }

}
