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
                WorkspacePolicyView(workspace: workspace)
            } label: {
                Label("Safety Policy", systemImage: "shield.lefthalf.filled")
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

// MARK: - Safety Policy

private struct WorkspacePolicyView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection

    @State private var policy: WorkspacePolicyResponse?
    @State private var rules: [PolicyRuleRecord] = []
    @State private var auditEntries: [PolicyAuditEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var editorDraft: PolicyPermissionDraft?
    @State private var pendingDeletePermission: PolicyPermissionRecord?

    var body: some View {
        List {
            if let policy {
                summarySection(policy)

                Section("Global Guardrails") {
                    if let global = policy.globalPolicy, !global.guardrails.isEmpty {
                        ForEach(global.guardrails) { permission in
                            policyPermissionRow(permission)
                        }
                    } else {
                        Text("No global guardrails configured.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Workspace Permissions") {
                    if policy.workspacePolicy.permissions.isEmpty {
                        Text("No workspace-specific permissions.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(policy.workspacePolicy.permissions) { permission in
                            Button {
                                editorDraft = PolicyPermissionDraft(permission: permission)
                            } label: {
                                policyPermissionRow(permission)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    pendingDeletePermission = permission
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading workspace policy…")
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
                                policyChip(rule.effect.uppercased(), color: rule.effect == "deny" ? .themeRed : .themeGreen)
                                policyChip(rule.scope.capitalized, color: .themeBlue)
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
                                    color: entry.decision == "deny" ? .themeRed : .themeGreen
                                )
                                policyChip(entry.resolvedBy.replacingOccurrences(of: "_", with: " "), color: .themeBlue)
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
        .navigationTitle("Safety Policy")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadAll()
        }
        .task {
            await loadAll()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorDraft = PolicyPermissionDraft.defaultDraft()
                } label: {
                    Label("Add Permission", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editorDraft) { draft in
            NavigationStack {
                WorkspacePermissionEditorView(draft: draft) { updated in
                    Task { await upsertWorkspacePermission(updated) }
                }
            }
        }
        .confirmationDialog(
            "Delete Permission",
            isPresented: Binding(
                get: { pendingDeletePermission != nil },
                set: { if !$0 { pendingDeletePermission = nil } }
            ),
            presenting: pendingDeletePermission
        ) { permission in
            Button("Delete", role: .destructive) {
                Task { await deleteWorkspacePermission(permission) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePermission = nil
            }
        } message: { permission in
            Text("Remove workspace permission \(permission.label ?? permission.id)?")
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
    private func summarySection(_ policy: WorkspacePolicyResponse) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RuntimeBadge(runtime: workspace.runtime, compact: true)
                    policyChip("Fallback: \(policy.effectivePolicy.fallback.uppercased())", color: .themeBlue)
                    Spacer()
                }

                Text("Effective policy includes \(policy.effectivePolicy.guardrails.count) guardrails and \(policy.effectivePolicy.permissions.count) permissions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Workspace permissions: \(policy.workspacePolicy.permissions.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        } header: {
            Text(workspace.name)
        }
    }

    @ViewBuilder
    private func policyPermissionRow(_ permission: PolicyPermissionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(permission.label ?? permission.id)
                    .font(.subheadline)
                Spacer()
                policyChip(permission.decision.uppercased(), color: permission.decision == "block" ? .themeRed : (permission.decision == "ask" ? .themeOrange : .themeGreen))
                if let risk = permission.risk {
                    policyChip(risk.label, color: Color.riskColor(risk))
                }
            }

            if let matchSummary = permissionMatchSummary(permission.match) {
                Text(matchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func permissionMatchSummary(_ match: PolicyPermissionRecord.Match) -> String? {
        var parts: [String] = []
        if let tool = match.tool, !tool.isEmpty { parts.append("tool: \(tool)") }
        if let executable = match.executable, !executable.isEmpty { parts.append("exec: \(executable)") }
        if let command = match.commandMatches, !command.isEmpty { parts.append("command: \(command)") }
        if let path = match.pathMatches, !path.isEmpty { parts.append("path: \(path)") }
        if let within = match.pathWithin, !within.isEmpty { parts.append("within: \(within)") }
        if let domain = match.domain, !domain.isEmpty { parts.append("domain: \(domain)") }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
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
            async let policyTask = api.getWorkspacePolicy(workspaceId: workspace.id)
            async let rulesTask = api.listPolicyRules(workspaceId: workspace.id)
            async let auditTask = api.listPolicyAudit(workspaceId: workspace.id, limit: 80)

            policy = try await policyTask
            rules = try await rulesTask
            auditEntries = try await auditTask
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func upsertWorkspacePermission(_ draft: PolicyPermissionDraft) async {
        guard let api = connection.apiClient else { return }

        do {
            let permission = draft.asPermissionRecord()
            let updatedPolicy = try await api.patchWorkspacePolicy(
                workspaceId: workspace.id,
                permissions: [permission]
            )

            if let current = policy {
                policy = WorkspacePolicyResponse(
                    workspaceId: current.workspaceId,
                    globalPolicy: current.globalPolicy,
                    workspacePolicy: updatedPolicy,
                    effectivePolicy: current.effectivePolicy
                )
            }

            editorDraft = nil
            await loadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteWorkspacePermission(_ permission: PolicyPermissionRecord) async {
        guard let api = connection.apiClient else { return }

        do {
            let updatedPolicy = try await api.deleteWorkspacePolicyPermission(
                workspaceId: workspace.id,
                permissionId: permission.id
            )

            if let current = policy {
                policy = WorkspacePolicyResponse(
                    workspaceId: current.workspaceId,
                    globalPolicy: current.globalPolicy,
                    workspacePolicy: updatedPolicy,
                    effectivePolicy: current.effectivePolicy
                )
            }

            pendingDeletePermission = nil
            await loadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PolicyPermissionDraft: Identifiable {
    let id = UUID()
    var permissionId: String
    var decision: String
    var risk: RiskLevel
    var label: String
    var reason: String
    var tool: String
    var executable: String
    var commandMatches: String
    var pathMatches: String
    var pathWithin: String
    var domain: String

    init(
        permissionId: String,
        decision: String,
        risk: RiskLevel,
        label: String,
        reason: String,
        tool: String,
        executable: String,
        commandMatches: String,
        pathMatches: String,
        pathWithin: String,
        domain: String
    ) {
        self.permissionId = permissionId
        self.decision = decision
        self.risk = risk
        self.label = label
        self.reason = reason
        self.tool = tool
        self.executable = executable
        self.commandMatches = commandMatches
        self.pathMatches = pathMatches
        self.pathWithin = pathWithin
        self.domain = domain
    }

    static func defaultDraft() -> PolicyPermissionDraft {
        Self(
            permissionId: "allow-\(UUID().uuidString.prefix(8).lowercased())",
            decision: "allow",
            risk: .low,
            label: "",
            reason: "",
            tool: "bash",
            executable: "",
            commandMatches: "",
            pathMatches: "",
            pathWithin: "",
            domain: ""
        )
    }

    init(permission: PolicyPermissionRecord) {
        permissionId = permission.id
        decision = permission.decision
        risk = permission.risk ?? .medium
        label = permission.label ?? ""
        reason = permission.reason ?? ""
        tool = permission.match.tool ?? ""
        executable = permission.match.executable ?? ""
        commandMatches = permission.match.commandMatches ?? ""
        pathMatches = permission.match.pathMatches ?? ""
        pathWithin = permission.match.pathWithin ?? ""
        domain = permission.match.domain ?? ""
    }

    func asPermissionRecord() -> PolicyPermissionRecord {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)

        return PolicyPermissionRecord(
            id: permissionId.trimmingCharacters(in: .whitespacesAndNewlines),
            decision: decision,
            risk: risk,
            label: trimmedLabel.isEmpty ? nil : trimmedLabel,
            reason: trimmedReason.isEmpty ? nil : trimmedReason,
            immutable: nil,
            match: .init(
                tool: nonEmpty(tool),
                executable: nonEmpty(executable),
                commandMatches: nonEmpty(commandMatches),
                pathMatches: nonEmpty(pathMatches),
                pathWithin: nonEmpty(pathWithin),
                domain: nonEmpty(domain)
            )
        )
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct WorkspacePermissionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PolicyPermissionDraft
    let onSave: (PolicyPermissionDraft) -> Void

    init(draft: PolicyPermissionDraft, onSave: @escaping (PolicyPermissionDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Rule") {
                TextField("permission id", text: $draft.permissionId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                Picker("Decision", selection: $draft.decision) {
                    Text("Allow").tag("allow")
                    Text("Ask").tag("ask")
                    Text("Block").tag("block")
                }

                Picker("Risk", selection: $draft.risk) {
                    Text("Low").tag(RiskLevel.low)
                    Text("Medium").tag(RiskLevel.medium)
                    Text("High").tag(RiskLevel.high)
                    Text("Critical").tag(RiskLevel.critical)
                }

                TextField("label (optional)", text: $draft.label)
                TextField("reason (optional)", text: $draft.reason)
            }

            Section("Match") {
                TextField("tool (bash/read/write/edit/*)", text: $draft.tool)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("executable (optional)", text: $draft.executable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("command glob (optional)", text: $draft.commandMatches)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("path glob (optional)", text: $draft.pathMatches)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("pathWithin (optional)", text: $draft.pathWithin)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("domain (optional)", text: $draft.domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
        .navigationTitle("Edit Permission")
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
        !draft.permissionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasAnyMatchField
    }

    private var hasAnyMatchField: Bool {
        [
            draft.tool,
            draft.executable,
            draft.commandMatches,
            draft.pathMatches,
            draft.pathWithin,
            draft.domain,
        ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
