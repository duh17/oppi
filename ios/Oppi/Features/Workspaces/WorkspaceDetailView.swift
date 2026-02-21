import SwiftUI

enum WorkspaceDetailWorkspaceResolver {
    static func resolve(
        fallback workspace: Workspace,
        currentServerId: String?,
        workspacesByServer: [String: [Workspace]]
    ) -> Workspace {
        guard let currentServerId,
              let latest = workspacesByServer[currentServerId]?
                .first(where: { $0.id == workspace.id }) else {
            return workspace
        }
        return latest
    }
}

/// Detail view for a workspace — shows its sessions with management actions.
///
/// Sessions are grouped into active (running/busy/ready) and stopped.
/// Supports creating new sessions, resuming stopped ones, and stopping active ones.
struct WorkspaceDetailView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection
    @Environment(ServerStore.self) private var serverStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore

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

    private struct SessionLineageSummary {
        let parentSessionName: String?
        let parentSessionStatus: SessionStatus?
        let childForkCount: Int
        let activeChildForkCount: Int
    }

    /// A unified item that can be either a stopped oppi session or a local TUI session.
    private enum StoppedItem: Identifiable {
        case session(Session)
        case local(LocalSession)

        var id: String {
            switch self {
            case .session(let s): return s.id
            case .local(let l): return "local-\(l.id)"
            }
        }

        var sortDate: Date {
            switch self {
            case .session(let s): return s.lastActivity
            case .local(let l): return l.lastModified
            }
        }
    }

    private struct StoppedSessionGroup: Identifiable {
        enum Bucket: Hashable {
            case day(Date)
            case month(Date)
        }

        let bucket: Bucket
        let items: [StoppedItem]

        var id: String {
            switch bucket {
            case .day(let day):
                return "day-\(Int(day.timeIntervalSince1970))"
            case .month(let month):
                return "month-\(Int(month.timeIntervalSince1970))"
            }
        }
    }

    // MARK: - Computed

    private var calendar: Calendar {
        Calendar.current
    }

    private var normalizedSessionSearchQuery: String {
        sessionSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var hasSessionSearchQuery: Bool {
        !normalizedSessionSearchQuery.isEmpty
    }

    private var serverBadgeIcon: ServerBadgeIcon {
        guard let currentServerId = connection.currentServerId,
              let server = serverStore.server(for: currentServerId) else {
            return .defaultValue
        }
        return server.resolvedBadgeIcon
    }

    private var serverBadgeColor: ServerBadgeColor {
        guard let currentServerId = connection.currentServerId,
              let server = serverStore.server(for: currentServerId) else {
            return .defaultValue
        }
        return server.resolvedBadgeColor
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
        WorkspaceDetailWorkspaceResolver.resolve(
            fallback: workspace,
            currentServerId: connection.currentServerId,
            workspacesByServer: connection.workspaceStore.workspacesByServer
        )
    }

    private var workspaceSessions: [Session] {
        sessionStore.sessions.filter { $0.workspaceId == workspace.id }
    }

    private var activeSessions: [Session] {
        workspaceSessions
            .filter { $0.status != .stopped && matchesSessionSearch($0) }
            .sorted { lhs, rhs in
                let lhsAttn = !permissionStore.pending(for: lhs.id).isEmpty
                let rhsAttn = !permissionStore.pending(for: rhs.id).isEmpty
                if lhsAttn != rhsAttn { return lhsAttn }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    private var stoppedSessions: [Session] {
        workspaceSessions
            .filter { $0.status == .stopped && matchesSessionSearch($0) }
            .sorted { $0.lastActivity > $1.lastActivity }
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
                let title = local.displayTitle.lowercased()
                guard title.contains(normalizedSessionSearchQuery) else { return false }
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

    /// Progressive grouping for stopped sessions + local TUI sessions:
    /// - Recent: grouped by day (last 30 days)
    /// - Older: grouped by month
    /// Local sessions are mixed in alongside stopped sessions by date.
    private var stoppedSessionGroups: [StoppedSessionGroup] {
        // Merge stopped sessions and local sessions into unified items
        let stoppedItems: [StoppedItem] = stoppedSessions.map { .session($0) }
        let localItems: [StoppedItem] = filteredLocalSessions.map { .local($0) }
        let allItems = stoppedItems + localItems

        guard !allItems.isEmpty else { return [] }

        let recentCutoff = calendar.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast

        let grouped = Dictionary(grouping: allItems) { item in
            if item.sortDate >= recentCutoff {
                return StoppedSessionGroup.Bucket.day(calendar.startOfDay(for: item.sortDate))
            }

            let comps = calendar.dateComponents([.year, .month], from: item.sortDate)
            let monthStart = calendar.date(from: comps) ?? calendar.startOfDay(for: item.sortDate)
            return StoppedSessionGroup.Bucket.month(monthStart)
        }

        return grouped
            .map { bucket, items in
                StoppedSessionGroup(
                    bucket: bucket,
                    items: items.sorted { $0.sortDate > $1.sortDate }
                )
            }
            .sorted { lhs, rhs in
                stoppedGroupSortDate(lhs.bucket) > stoppedGroupSortDate(rhs.bucket)
            }
    }

    // MARK: - Body

    var body: some View {
        List {
            if let gitStatus = connection.gitStatusStore.gitStatus, gitStatus.isGitRepo, !gitStatus.isClean {
                Section {
                    WorkspaceContextBar(
                        gitStatus: gitStatus,
                        changeStats: nil,
                        isLoading: false,
                        appliesOuterHorizontalPadding: false
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if !activeSessions.isEmpty {
                Section("Active") {
                    ForEach(activeSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(
                                session: session,
                                pendingCount: permissionStore.pending(for: session.id).count,
                                lineageHint: lineageHint(for: session)
                            )
                        }
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

            if !stoppedSessionGroups.isEmpty {
                ForEach(Array(stoppedSessionGroups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        if isStoppedGroupExpanded(group) {
                            ForEach(group.items) { item in
                                switch item {
                                case .session(let session):
                                    NavigationLink(value: session.id) {
                                        SessionRow(
                                            session: session,
                                            pendingCount: 0,
                                            lineageHint: lineageHint(for: session)
                                        )
                                    }
                                    .listRowBackground(Color.themeBg)
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            Task { await resumeSession(session) }
                                        } label: {
                                            Label("Resume", systemImage: "play.fill")
                                        }
                                        .tint(.themeGreen)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            Task { await deleteSession(session) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }

                                case .local(let local):
                                    Button {
                                        Task { await importAndResumeLocal(local) }
                                    } label: {
                                        LocalSessionRow(session: local)
                                    }
                                    .listRowBackground(Color.themeBg)
                                    .disabled(isImportingLocal)
                                }
                            }
                        }
                    } header: {
                        Button {
                            toggleStoppedGroupExpansion(group)
                        } label: {
                            HStack(spacing: 8) {
                                Text(index == 0 ? "Stopped · \(stoppedGroupTitle(group.bucket))" : stoppedGroupTitle(group.bucket))
                                Spacer()
                                Image(systemName: isStoppedGroupExpanded(group) ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.themeComment)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if workspaceSessions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Tap + to start a new session in this workspace.")
                    )
                    .listRowBackground(Color.themeBg)
                }
            } else if hasSessionSearchQuery,
                      activeSessions.isEmpty,
                      stoppedSessions.isEmpty {
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
        .listStyle(.insetGrouped)
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
                .disabled(isCreating)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { showEditWorkspace = true } label: {
                    HStack(spacing: 8) {
                        WorkspaceIcon(icon: currentWorkspace.icon, size: 18)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentWorkspace.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? currentWorkspace.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            HStack(spacing: 6) {
                                RuntimeBadge(compact: true, icon: serverBadgeIcon, badgeColor: serverBadgeColor)
                                Text("\(currentWorkspace.skills.count) skills")
                                    .font(.caption2)
                                    .foregroundStyle(.themeComment)
                                if let model = currentWorkspace.defaultModel {
                                    Text(model.split(separator: "/").last.map(String.init) ?? model)
                                        .font(.caption2)
                                        .foregroundStyle(.themeComment)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if let api = connection.apiClient {
                connection.gitStatusStore.loadInitial(
                    workspaceId: workspace.id,
                    apiClient: api,
                    gitStatusEnabled: currentWorkspace.gitStatusEnabled ?? true
                )
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

    private func stoppedGroupSortDate(_ bucket: StoppedSessionGroup.Bucket) -> Date {
        switch bucket {
        case .day(let day):
            return day
        case .month(let month):
            return month
        }
    }

    private func stoppedGroupTitle(_ bucket: StoppedSessionGroup.Bucket) -> String {
        switch bucket {
        case .day(let day):
            if calendar.isDateInToday(day) {
                return "Today"
            }
            if calendar.isDateInYesterday(day) {
                return "Yesterday"
            }
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())

        case .month(let month):
            return month.formatted(.dateTime.month(.wide).year())
        }
    }

    private func matchesSessionSearch(_ session: Session) -> Bool {
        guard hasSessionSearchQuery else {
            return true
        }

        return sessionTitle(session)
            .lowercased()
            .contains(normalizedSessionSearchQuery)
    }

    private func isStoppedGroupExpanded(_ group: StoppedSessionGroup) -> Bool {
        if hasSessionSearchQuery {
            return true
        }
        if expandedStoppedGroupIDs.contains(group.id) {
            return true
        }
        if collapsedStoppedGroupIDs.contains(group.id) {
            return false
        }
        return isStoppedGroupExpandedByDefault(group.bucket)
    }

    private func toggleStoppedGroupExpansion(_ group: StoppedSessionGroup) {
        if isStoppedGroupExpanded(group) {
            expandedStoppedGroupIDs.remove(group.id)
            collapsedStoppedGroupIDs.insert(group.id)
        } else {
            collapsedStoppedGroupIDs.remove(group.id)
            expandedStoppedGroupIDs.insert(group.id)
        }
    }

    private func isStoppedGroupExpandedByDefault(_ bucket: StoppedSessionGroup.Bucket) -> Bool {
        switch bucket {
        case .day(let day):
            let todayStart = calendar.startOfDay(for: Date())
            let expandedCutoff = calendar.date(byAdding: .day, value: -2, to: todayStart) ?? .distantPast
            return day >= expandedCutoff
        case .month:
            return false
        }
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
        guard let api = connection.apiClient else { return }

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

    private func createSession() async {
        guard let api = connection.apiClient else { return }
        isCreating = true
        error = nil

        do {
            let session = try await api.createWorkspaceSession(workspaceId: workspace.id)
            sessionStore.upsert(session)
            await refreshLineage()
            isCreating = false
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }

    private func stopSession(_ session: Session) async {
        guard let api = connection.apiClient else { return }
        do {
            let updated = try await api.stopWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            sessionStore.upsert(updated)
            await refreshLineage()
        } catch {
            self.error = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func resumeSession(_ session: Session) async {
        guard let api = connection.apiClient else { return }
        do {
            let updated = try await api.resumeWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            sessionStore.upsert(updated)
            await refreshLineage()
        } catch {
            self.error = "Resume failed: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ session: Session) async {
        guard let api = connection.apiClient else { return }
        sessionStore.remove(id: session.id)
        do {
            try await api.deleteWorkspaceSession(workspaceId: workspace.id, sessionId: session.id)
            await refreshLineage()
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func importAndResumeLocal(_ local: LocalSession) async {
        guard let api = connection.apiClient else { return }
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
        guard let api = connection.apiClient else { return }
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
        guard let api = connection.apiClient else { return }
        do {
            localSessions = try await api.listLocalSessions()
        } catch {
            // Non-fatal — local sessions are a nice-to-have
        }
    }

    private func refreshPolicyFallback() async {
        guard let api = connection.apiClient else { return }
        do {
            policyFallback = try await api.getPolicyFallback()
        } catch {
            // Non-fatal — use cached/default icon state
        }
    }
}

// MARK: - Safety Policy

private struct WorkspacePolicyView: View {
    let workspace: Workspace
    let onFallbackChanged: (PolicyFallbackDecision) -> Void

    @Environment(ServerConnection.self) private var connection

    @State private var fallbackDecision: PolicyFallbackDecision = .allow
    @State private var isUpdatingFallback = false
    @State private var rules: [PolicyRuleRecord] = []
    @State private var auditEntries: [PolicyAuditEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var rememberedRuleDraft: RememberedRuleDraft?
    @State private var pendingDeleteRule: PolicyRuleRecord?

    var body: some View {
        List {
            if isLoading && rules.isEmpty && auditEntries.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading safety rules…")
                        Spacer()
                    }
                }
            }

            Section("Default Fallback") {
                Picker("When no rule matches", selection: Binding(
                    get: { fallbackDecision },
                    set: { newValue in
                        guard newValue != fallbackDecision else { return }
                        fallbackDecision = newValue
                        Task { await updateFallbackDecision(newValue) }
                    }
                )) {
                    Text("Allow").tag(PolicyFallbackDecision.allow)
                    Text("Ask").tag(PolicyFallbackDecision.ask)
                    Text("Deny").tag(PolicyFallbackDecision.deny)
                }
                .pickerStyle(.segmented)
                .disabled(isLoading || isUpdatingFallback)
            }

            Section("Remembered Rules") {
                if rules.isEmpty {
                    Text("No remembered rules for this workspace.")
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(rules.prefix(25)) { rule in
                        Button {
                            rememberedRuleDraft = RememberedRuleDraft(rule: rule)
                        } label: {
                            rememberedRuleRow(rule)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteRule = rule
                            } label: {
                                Label("Revoke", systemImage: "trash")
                            }
                        }
                    }

                    if rules.count > 25 {
                        Text("Showing 25 of \(rules.count) rules")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Recent Decisions") {
                if auditEntries.isEmpty {
                    Text("No recent policy decisions.")
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(auditEntries.prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displaySummary)
                                .font(.subheadline)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                policyChip(
                                    entry.decision.capitalized,
                                    color: entry.decision == "deny" ? .themeRed : .themeGreen
                                )
                                policyChip(entry.resolvedBy.replacingOccurrences(of: "_", with: " "), color: .themeBlue)
                                Spacer()
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if auditEntries.count > 30 {
                        Text("Showing 30 of \(auditEntries.count) entries")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Safety Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    rememberedRuleDraft = RememberedRuleDraft(workspaceId: workspace.id)
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
        }
        .refreshable {
            await loadAll()
        }
        .task {
            await loadAll()
        }
        .sheet(item: $rememberedRuleDraft) { draft in
            NavigationStack {
                RememberedRuleEditorView(draft: draft) { updated in
                    Task { await updateRememberedRule(updated) }
                }
            }
        }
        .confirmationDialog(
            "Revoke Remembered Rule",
            isPresented: Binding(
                get: { pendingDeleteRule != nil },
                set: { if !$0 { pendingDeleteRule = nil } }
            ),
            presenting: pendingDeleteRule
        ) { rule in
            Button("Revoke", role: .destructive) {
                Task { await deleteRememberedRule(rule) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteRule = nil
            }
        } message: { rule in
            Text("Remove remembered rule \(rule.label)?")
        }
        .alert("Policy Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func rememberedRuleRow(_ rule: PolicyRuleRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.label)
                .font(.subheadline)
            HStack(spacing: 8) {
                let chipColor: Color =
                    rule.decision == "deny" ? .themeRed :
                    (rule.decision == "ask" ? .themeOrange : .themeGreen)
                policyChip(rule.decision.uppercased(), color: chipColor)
                policyChip(rule.scope.capitalized, color: .themeBlue)
            }

            if let match = ruleMatchSummary(rule) {
                Text(match)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .textSelection(.enabled)
            }

            if let expiresAt = rule.expiresAt {
                Text("Expires \(expiresAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func policyChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func ruleMatchSummary(_ rule: PolicyRuleRecord) -> String? {
        var parts: [String] = []

        if let tool = rule.tool, !tool.isEmpty {
            parts.append("tool: \(tool)")
        }
        if let executable = rule.executable, !executable.isEmpty {
            parts.append("exec: \(executable)")
        }
        if let pattern = rule.pattern, !pattern.isEmpty {
            parts.append("pattern: \(pattern)")
        }

        if parts.isEmpty { return nil }
        return parts.joined(separator: " • ")
    }

    private func loadAll() async {
        guard let api = connection.apiClient else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let rulesTask = api.listPolicyRules(workspaceId: workspace.id)
            async let auditTask = api.listPolicyAudit(workspaceId: workspace.id, limit: 80)
            async let fallbackTask = api.getPolicyFallback()

            rules = try await rulesTask
            auditEntries = try await auditTask
            let loadedFallback = try await fallbackTask
            fallbackDecision = loadedFallback
            onFallbackChanged(loadedFallback)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updateFallbackDecision(_ fallback: PolicyFallbackDecision) async {
        guard let api = connection.apiClient else { return }

        isUpdatingFallback = true
        defer { isUpdatingFallback = false }

        do {
            let updatedFallback = try await api.patchPolicyFallback(fallback)
            fallbackDecision = updatedFallback
            onFallbackChanged(updatedFallback)
            error = nil
        } catch {
            self.error = error.localizedDescription
            do {
                let loadedFallback = try await api.getPolicyFallback()
                fallbackDecision = loadedFallback
                onFallbackChanged(loadedFallback)
            } catch {
                // Keep optimistic value if fallback reload fails.
            }
        }
    }

    private func updateRememberedRule(_ draft: RememberedRuleDraft) async {
        guard let api = connection.apiClient else { return }

        do {
            if let ruleId = draft.ruleId {
                _ = try await api.patchPolicyRule(ruleId: ruleId, request: draft.asPatchRequest())
            } else {
                _ = try await api.createPolicyRule(request: draft.asCreateRequest(defaultWorkspaceId: workspace.id))
            }
            rememberedRuleDraft = nil
            await loadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteRememberedRule(_ rule: PolicyRuleRecord) async {
        guard let api = connection.apiClient else { return }

        do {
            try await api.deletePolicyRule(ruleId: rule.id)
            pendingDeleteRule = nil
            rules.removeAll { $0.id == rule.id }
            await loadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RememberedRuleDraft: Identifiable {
    let id = UUID()
    let ruleId: String?
    let scope: String
    let workspaceId: String?
    var decision: String
    var label: String
    var tool: String
    var executable: String
    var pattern: String

    init(rule: PolicyRuleRecord) {
        ruleId = rule.id
        scope = rule.scope
        workspaceId = rule.workspaceId
        decision = rule.decision
        label = rule.label
        tool = rule.tool ?? ""
        executable = rule.executable ?? ""
        pattern = rule.pattern ?? ""
    }

    init(workspaceId: String) {
        ruleId = nil
        scope = "workspace"
        self.workspaceId = workspaceId
        decision = "ask"
        label = ""
        tool = ""
        executable = ""
        pattern = ""
    }

    func asCreateRequest(defaultWorkspaceId: String) -> PolicyRuleCreateRequest {
        let workspaceScopeId = scope == "workspace"
            ? (workspaceId ?? defaultWorkspaceId)
            : nil

        return PolicyRuleCreateRequest(
            decision: decision,
            label: nonEmpty(label),
            tool: nonEmpty(tool),
            pattern: nonEmpty(pattern),
            executable: nonEmpty(executable),
            scope: scope,
            workspaceId: workspaceScopeId,
            sessionId: nil,
            expiresAt: nil
        )
    }

    func asPatchRequest() -> PolicyRulePatchRequest {
        PolicyRulePatchRequest(
            decision: decision,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            tool: nonEmpty(tool),
            pattern: nonEmpty(pattern),
            executable: nonEmpty(executable)
        )
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct RememberedRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RememberedRuleDraft
    let onSave: (RememberedRuleDraft) -> Void

    init(draft: RememberedRuleDraft, onSave: @escaping (RememberedRuleDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Rule") {
                if let ruleId = draft.ruleId {
                    LabeledContent("Rule ID", value: ruleId)
                } else {
                    LabeledContent("Rule ID", value: "New rule")
                }
                LabeledContent("Scope", value: draft.scope.capitalized)

                Picker("Decision", selection: $draft.decision) {
                    Text("Allow").tag("allow")
                    Text("Ask").tag("ask")
                    Text("Deny").tag("deny")
                }

                TextField("label", text: $draft.label)
            }

            Section("Match") {
                TextField("tool (optional)", text: $draft.tool)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("executable (optional)", text: $draft.executable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("pattern (optional)", text: $draft.pattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
        .navigationTitle(draft.ruleId == nil ? "Add Remembered Rule" : "Edit Remembered Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
    }

    private var isValid: Bool {
        !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (hasSpecificTool || hasAnyMatchField)
    }

    private var hasSpecificTool: Bool {
        let trimmed = draft.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "*"
    }

    private var hasAnyMatchField: Bool {
        [
            draft.executable,
            draft.pattern,
        ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
