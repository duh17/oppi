import SwiftUI

// MARK: - Safety Policy

struct WorkspacePolicyView: View {
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
