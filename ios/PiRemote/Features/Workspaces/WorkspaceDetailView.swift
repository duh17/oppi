import SwiftUI

/// Detail view for a workspace — shows its sessions with management actions.
///
/// Sessions are grouped into active (running/busy/ready) and stopped.
/// Supports creating new sessions, resuming stopped ones, and stopping active ones.
struct WorkspaceDetailView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore

    @State private var isCreating = false
    @State private var error: String?
    @State private var lineageBySessionId: [String: SessionLineageSummary] = [:]

    private struct SessionLineageSummary {
        let parentSessionName: String?
        let parentSessionStatus: SessionStatus?
        let childForkCount: Int
        let activeChildForkCount: Int
    }

    // MARK: - Computed

    private var workspaceSessions: [Session] {
        sessionStore.sessions.filter { $0.workspaceId == workspace.id }
    }

    private var activeSessions: [Session] {
        workspaceSessions
            .filter { $0.status != .stopped }
            .sorted { lhs, rhs in
                let lhsAttn = !permissionStore.pending(for: lhs.id).isEmpty
                let rhsAttn = !permissionStore.pending(for: rhs.id).isEmpty
                if lhsAttn != rhsAttn { return lhsAttn }
                return lhs.lastActivity > rhs.lastActivity
            }
    }

    private var stoppedSessions: [Session] {
        workspaceSessions
            .filter { $0.status == .stopped }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Body

    var body: some View {
        List {
            workspaceInfoSection

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
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await stopSession(session) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }

            if !stoppedSessions.isEmpty {
                Section("Stopped") {
                    ForEach(stoppedSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(
                                session: session,
                                pendingCount: 0,
                                lineageHint: lineageHint(for: session)
                            )
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await resumeSession(session) }
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteSession(session) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
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
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(workspace.name)
        .navigationDestination(for: String.self) { sessionId in
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

            ToolbarItem(placement: .secondaryAction) {
                NavigationLink {
                    WorkspaceEditView(workspace: workspace)
                } label: {
                    Label("Edit Workspace", systemImage: "pencil")
                }
            }
        }
        .refreshable {
            await refreshSessions()
        }
        .task {
            await refreshLineage()
        }
        .overlay {
            if isCreating {
                ProgressView("Creating session...")
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
    }

    // MARK: - Workspace Info

    private var workspaceInfoSection: some View {
        Section {
            HStack(spacing: 12) {
                WorkspaceIcon(icon: workspace.icon, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    if let desc = workspace.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        RuntimeBadge(runtime: workspace.runtime, compact: true)
                        Text("\(workspace.skills.count) skills")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if let model = workspace.defaultModel {
                            Text(model.split(separator: "/").last.map(String.init) ?? model)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            NavigationLink {
                WorkspacePolicyProfileView(workspace: workspace)
            } label: {
                Label("Safety Profile", systemImage: "shield.lefthalf.filled")
            }

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
        let trimmed = session.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return "Session \(String(session.id.prefix(8)))"
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
}

// MARK: - Safety Profile

private struct WorkspacePolicyProfileView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection

    @State private var profile: PolicyProfile?
    @State private var rules: [PolicyRuleRecord] = []
    @State private var auditEntries: [PolicyAuditEntry] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if let profile {
                summarySection(profile)

                Section("Always Blocked") {
                    if profile.alwaysBlocked.isEmpty {
                        Text("No hard blocks configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profile.alwaysBlocked) { item in
                            PolicyProfileItemRow(item: item)
                        }
                    }
                }

                Section("Needs Approval") {
                    if profile.needsApproval.isEmpty {
                        Text("No approval-required actions.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profile.needsApproval) { item in
                            PolicyProfileItemRow(item: item)
                        }
                    }
                }

                Section("Runs Automatically") {
                    ForEach(profile.usuallyAllowed, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading policy profile…")
                        Spacer()
                    }
                }
            }

            Section("Remembered Permissions") {
                if rules.isEmpty {
                    Text("No remembered rules for this workspace.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules.prefix(25)) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.description)
                                .font(.subheadline)
                            HStack(spacing: 8) {
                                policyChip(rule.effect.uppercased(), color: rule.effect == "deny" ? .tokyoRed : .tokyoGreen)
                                policyChip(rule.scope.capitalized, color: .tokyoBlue)
                                policyChip(rule.risk.label, color: Color.riskColor(rule.risk))
                            }

                            if let match = ruleMatchSummary(rule.match) {
                                Text(match)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(auditEntries.prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displaySummary)
                                .font(.subheadline)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                policyChip(
                                    entry.decision.capitalized,
                                    color: entry.decision == "deny" ? .tokyoRed : .tokyoGreen
                                )
                                policyChip(entry.resolvedBy.replacingOccurrences(of: "_", with: " "), color: .tokyoBlue)
                                policyChip(entry.risk.label, color: Color.riskColor(entry.risk))
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
        .navigationTitle("Safety Profile")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadAll()
        }
        .task {
            await loadAll()
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
    private func summarySection(_ profile: PolicyProfile) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RuntimeBadge(runtime: profile.runtime, compact: true)
                    policyChip(
                        profile.supervisionLevel == "high" ? "High Supervision" : "Standard Supervision",
                        color: profile.supervisionLevel == "high" ? .tokyoOrange : .tokyoGreen
                    )
                    Spacer()
                }

                Text(profile.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Preset: \(policyPresetLabel(profile.policyPreset)) • Updated \(profile.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        } header: {
            Text(workspace.name)
        }
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

    private func policyPresetLabel(_ value: String) -> String {
        switch value {
        case "container": return "Container"
        case "host": return "Host Dev"
        case "host_standard": return "Host Standard"
        case "host_locked": return "Host Locked"
        default: return value
        }
    }

    private func ruleMatchSummary(_ match: PolicyRuleRecord.Match?) -> String? {
        guard let match else { return nil }

        var parts: [String] = []
        if let executable = match.executable, !executable.isEmpty {
            parts.append("exec: \(executable)")
        }
        if let domain = match.domain, !domain.isEmpty {
            parts.append("domain: \(domain)")
        }
        if let pathPattern = match.pathPattern, !pathPattern.isEmpty {
            parts.append("path: \(pathPattern)")
        }
        if let commandPattern = match.commandPattern, !commandPattern.isEmpty {
            parts.append("command: \(commandPattern)")
        }

        if parts.isEmpty { return nil }
        return parts.joined(separator: " • ")
    }

    private func loadAll() async {
        guard let api = connection.apiClient else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let profileTask = api.getPolicyProfile(workspaceId: workspace.id)
            async let rulesTask = api.listPolicyRules(workspaceId: workspace.id)
            async let auditTask = api.listPolicyAudit(workspaceId: workspace.id, limit: 80)

            profile = try await profileTask
            rules = try await rulesTask
            auditEntries = try await auditTask
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PolicyProfileItemRow: View {
    let item: PolicyProfileItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: item.risk.systemImage)
                    .font(.caption)
                    .foregroundStyle(Color.riskColor(item.risk))
                Text(item.title)
                    .font(.subheadline)
                Spacer()
                Text(item.risk.label)
                    .font(.caption2)
                    .foregroundStyle(Color.riskColor(item.risk))
            }

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let example = item.example, !example.isEmpty {
                Text(example)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
