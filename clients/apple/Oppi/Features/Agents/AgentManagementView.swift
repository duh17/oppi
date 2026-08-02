import SwiftUI

struct UseOppiSessionRow: View {
    let supportingText: String?
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use Oppi Session")
                        .foregroundStyle(.themeFg)
                    if let supportingText {
                        Text(supportingText)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel("Use Oppi Session")
        .accessibilityHint(supportingText ?? "Opens an Oppi session")
    }
}

struct AgentManagementView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var agents: [AgentDefinitionSummary] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if isLoading && agents.isEmpty {
                ProgressView("Loading agents…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.themeBg)
            } else if agents.isEmpty {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Describe the Agent you need below. Default Agent will clarify its behavior before creating it.")
                )
                .listRowBackground(Color.themeBg)
            } else {
                Section {
                    ForEach(agents) { agent in
                        NavigationLink {
                            AgentDetailView(agentId: agent.id) { updated in
                                guard let index = agents.firstIndex(where: { $0.id == updated.id }) else {
                                    return
                                }
                                agents[index] = AgentDefinitionSummary(
                                    id: updated.id,
                                    name: updated.name,
                                    icon: updated.definition.icon,
                                    description: updated.description,
                                    status: updated.status,
                                    version: updated.version,
                                    createdAt: updated.createdAt,
                                    updatedAt: updated.updatedAt,
                                    archivedAt: updated.archivedAt
                                )
                            }
                        } label: {
                            AgentSummaryRow(agent: agent)
                        }
                        .accessibilityIdentifier("agents.row.\(agent.id)")
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("An Agent stores reusable instructions, resources, and Pi session defaults. Workspaces and worktrees are selected when a session starts.")
                }
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GuidedControlSessionComposer(
                domain: .agents,
                intent: .create,
                placeholder: "Describe a new Agent…"
            )
        }
        .refreshable { await loadAgents() }
        .task { await loadAgents() }
        .alert("Agents", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @MainActor
    private func loadAgents() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            agents = try await apiClient.listAgents()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AgentSummaryRow: View {
    let agent: AgentDefinitionSummary

    var body: some View {
        HStack(spacing: 12) {
            AgentIconView(value: agent.icon, size: 22, frameSize: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agent.name)
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)

                    StatusPill(
                        text: "v\(agent.version)",
                        tone: .neutral,
                        emphasis: .quiet,
                        size: .mini,
                        monospacedDigit: true
                    )
                }

                if let description = agent.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(2)
                } else {
                    Text("No description")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            Spacer(minLength: 8)

            Text(agent.updatedAt.relativeString())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 4)
    }
}

private struct AgentDetailView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(WorkspaceStore.self) private var workspaceStore

    let agentId: String
    let onUpdated: (StoredAgentDefinition) -> Void

    @State private var agent: StoredAgentDefinition?
    @State private var isLoading = false
    @State private var error: String?
    @State private var isShowingNativeEdit = false
    @State private var isShowingRevision = false
    @State private var isShowingDefinitionReview = false
    @State private var isShowingIconPicker = false
    @State private var isShowingLaunch = false
    @State private var isShowingSchedule = false
    @State private var isArchiving = false
    @State private var isLoadingResources = false

    var body: some View {
        List {
            if isLoading && agent == nil {
                ProgressView("Loading agent…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.themeBg)
            } else if let agent {
                Section("Definition") {
                    Button {
                        isShowingIconPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Text("Icon")
                                .foregroundStyle(.themeComment)
                            Spacer(minLength: 12)
                            AgentIconView(value: agent.definition.icon, size: 24, frameSize: 32)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.themeComment)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Icon")
                    .accessibilityValue(iconSummary(agent.definition.icon))
                    .accessibilityHint("Opens the Agent icon picker")
                    .accessibilityIdentifier("agents.detail.icon")

                    detailRow("Name", agent.definition.name)
                    if let description = agent.definition.description, !description.isEmpty {
                        detailTextBlock("Description", description)
                    }
                    detailRow("Status", agent.status.rawValue.capitalized)
                    detailRow("Version", "v\(agent.version)")
                }

                if let instructions = agent.definition.instructions {
                    Section(systemPromptTitle(instructions.mode)) {
                        Button {
                            isShowingDefinitionReview = true
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(instructions.text)
                                    .foregroundStyle(.themeFg)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Label("Read and comment", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.themeBlue)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Read and comment on Agent definition")
                        .accessibilityIdentifier("agents.detail.definition")
                    }
                }

                Section("Pi Session Defaults") {
                    let defaults = agent.definition.sessionDefaults
                    detailRow("Model", defaults?.model?.nilIfBlank ?? "Server default")
                    detailRow("Thinking Level", defaults?.thinkingLevel?.rawValue ?? "Default")
                    toolDefaultRows(defaults)
                }

                Section("Resources") {
                    resourceRow(
                        "Skills",
                        values: agent.definition.resources?.skillPaths,
                        displayValues: skillDisplayNames(agent.definition.resources?.skillPaths)
                    )
                    resourceRow(
                        "Extensions",
                        values: agent.definition.resources?.extensionIds,
                        displayValues: extensionDisplayNames(agent.definition.resources?.extensionIds)
                    )
                    if agent.definition.resources?.noContextFiles == true {
                        Label("Context files disabled", systemImage: "doc.badge.gearshape")
                            .font(.subheadline)
                    }
                    if let message = skillCatalogState.statusMessage(for: "Skills") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.themeOrange)
                    }
                    if let message = extensionCatalogState.statusMessage(for: "Extensions") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.themeOrange)
                    }
                }

                Section("Start") {
                    Button {
                        isShowingLaunch = true
                    } label: {
                        Label("Start Session with Agent", systemImage: "play.circle.fill")
                    }
                    .disabled(workspaceStore.workspaces.isEmpty)
                    .accessibilityIdentifier("agents.detail.launch")

                    Button {
                        isShowingSchedule = true
                    } label: {
                        Label("Schedule Recurring Run", systemImage: "calendar.badge.clock")
                    }
                    .disabled(workspaceStore.workspaces.isEmpty)
                    .accessibilityIdentifier("agents.detail.schedule")

                    if workspaceStore.workspaces.isEmpty {
                        Text("Create or sync a workspace before launching or scheduling this Agent.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    } else {
                        Text("Schedules can run this Agent with a recurring briefing prompt, selected workspace, and repeat time.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "questionmark.circle")
                    .listRowBackground(Color.themeBg)
            }
        }
        .navigationTitle(agent?.name ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if agent?.status == .active {
                    Button("Edit") {
                        isShowingNativeEdit = true
                    }
                    .accessibilityIdentifier("agents.detail.edit")

                    Menu {
                        Button {
                            isShowingRevision = true
                        } label: {
                            Label("Edit with Oppi", systemImage: "text.bubble")
                        }

                        Button("Archive Agent", role: .destructive) {
                            Task { await archiveAgent() }
                        }
                        .disabled(isArchiving)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Agent actions")
                }
            }
        }
        .task(id: agentId) {
            await loadAgent()
            await loadResources()
        }
        .refreshable {
            await loadAgent()
            await loadResources()
        }
        .fullScreenCover(isPresented: $isShowingNativeEdit) {
            if let agent {
                AgentNativeEditView(agent: agent) { updated in
                    self.agent = updated
                    onUpdated(updated)
                }
            }
        }
        .sheet(isPresented: $isShowingIconPicker) {
            if let agent {
                AgentIconPickerView(agent: agent) { updated in
                    self.agent = updated
                    onUpdated(updated)
                }
            }
        }
        .sheet(isPresented: $isShowingRevision) {
            if let agent {
                GuidedControlSessionSheet(
                    domain: .agents,
                    intent: .revise,
                    targetId: agent.id,
                    targetName: agent.name,
                    placeholder: "Describe how this Agent should change…"
                )
            }
        }
        .sheet(isPresented: $isShowingDefinitionReview) {
            if let agent {
                ReviewableControlMarkdownView(
                    content: definitionMarkdown(agent),
                    domain: .agents,
                    targetId: agent.id,
                    targetName: agent.name,
                    sourceLabel: "\(agent.name) definition",
                    sourcePath: "Agents/\(agent.id)/Definition.md"
                )
            }
        }
        .sheet(isPresented: $isShowingLaunch) {
            if let agent {
                NavigationStack {
                    AgentLaunchSheet(agent: agent) { session in
                        connection.sessionStore.upsert(session)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSchedule) {
            if let agent {
                GuidedControlSessionSheet(
                    domain: .schedules,
                    intent: .create,
                    initialRequest: "Create a schedule that runs saved Agent \(agent.name) (canonical Agent ID: \(agent.id)).",
                    allowsEmptyRequest: false,
                    placeholder: "Describe when and how this Agent should run…"
                )
            }
        }
        .alert("Agent", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func iconSummary(_ value: IconChoice) -> String {
        AgentIconPickerView.description(value)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title)
                .foregroundStyle(.themeComment)
        }
        .font(.subheadline)
    }

    private func detailTextBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.themeComment)
            Text(value)
                .foregroundStyle(.themeFg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func systemPromptTitle(_ mode: AgentInstructionMode) -> String {
        switch mode {
        case .append: return "Append System Prompt"
        case .replace: return "Replace System Prompt"
        }
    }

    private func definitionMarkdown(_ agent: StoredAgentDefinition) -> String {
        let definition = agent.definition
        let defaults = definition.sessionDefaults
        let resources = definition.resources
        let instructions: [String]
        if let instruction = definition.instructions {
            instructions = [
                "## \(systemPromptTitle(instruction.mode))",
                "",
                instruction.text,
            ]
        } else {
            instructions = ["## System Prompt", "", "_Uses the server default._"]
        }

        var lines = ["# \(definition.name)", ""]
        if let description = definition.description?.nilIfBlank {
            lines.append(description)
            lines.append("")
        }
        lines += instructions
        lines += [
            "",
            "## Pi Session Defaults",
            "",
            "- **Model:** \(defaults?.model?.nilIfBlank ?? "Server default")",
            "- **Thinking level:** \(defaults?.thinkingLevel?.rawValue ?? "Default")",
            "- **Tools:** \(agentToolSummary(defaults))",
            "",
            "## Resources",
            "",
            "- **Skills:** \(resourceSummary(resources?.skillPaths, displayValues: skillDisplayNames(resources?.skillPaths)))",
            "- **Extensions:** \(resourceSummary(resources?.extensionIds, displayValues: extensionDisplayNames(resources?.extensionIds)))",
            "- **Context files:** \(resources?.noContextFiles == true ? "Disabled" : "Default discovery")",
        ]
        return lines.joined(separator: "\n")
    }

    private func agentToolSummary(_ defaults: AgentSessionDefaults?) -> String {
        if let noTools = defaults?.noTools { return noTools.displayName }
        let allowed = defaults?.tools ?? []
        let excluded = defaults?.excludeTools ?? []
        if !allowed.isEmpty { return "Allowed: \(allowed.joined(separator: ", "))" }
        if !excluded.isEmpty { return "Excluded: \(excluded.joined(separator: ", "))" }
        return "Default"
    }

    private func resourceSummary(_ values: [String]?, displayValues: [String]? = nil) -> String {
        guard let values else { return "Default discovery" }
        guard !values.isEmpty else { return "None" }
        return (displayValues ?? values).joined(separator: ", ")
    }

    private func skillDisplayNames(_ paths: [String]?) -> [String]? {
        guard let paths, let serverId = connection.currentServerId else { return nil }
        let catalog = connection.serverResourceStore.skills(forServer: serverId)
        return paths.map { path in
            catalog.first(where: { $0.path == path })?.name ?? path
        }
    }

    private func extensionDisplayNames(_ ids: [String]?) -> [String]? {
        guard let ids, let serverId = connection.currentServerId else { return nil }
        let catalog = connection.serverResourceStore.extensions(forServer: serverId)
        return ids.map { id in
            catalog.first(where: { $0.id == id })?.name ?? id
        }
    }

    private var skillCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let sync = connection.serverResourceStore.syncState(for: .skills, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: connection.serverResourceStore.hasLoadedSkills(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !connection.serverResourceStore.skills(forServer: serverId).isEmpty
        )
    }

    private var extensionCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let sync = connection.serverResourceStore.syncState(for: .extensions, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: connection.serverResourceStore.hasLoadedExtensions(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !connection.serverResourceStore.extensions(forServer: serverId).filter {
                !$0.isBuiltInOppi
            }.isEmpty
        )
    }

    @ViewBuilder
    private func toolDefaultRows(_ defaults: AgentSessionDefaults?) -> some View {
        let allowed = defaults?.tools ?? []
        let excluded = defaults?.excludeTools ?? []
        if defaults?.noTools == nil && allowed.isEmpty && excluded.isEmpty {
            detailRow("Tools", "Default")
        } else {
            if let noTools = defaults?.noTools {
                detailRow("Tools", noTools.displayName)
            }
            if !allowed.isEmpty {
                detailTextBlock("Allowed Tools", allowed.joined(separator: ", "))
            }
            if !excluded.isEmpty {
                detailTextBlock("Excluded Tools", excluded.joined(separator: ", "))
            }
        }
    }

    @ViewBuilder
    private func resourceRow(
        _ title: String,
        values: [String]?,
        displayValues: [String]? = nil
    ) -> some View {
        if let values {
            if values.isEmpty {
                detailRow(title, "None")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text((displayValues ?? values).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .textSelection(.enabled)
                }
            }
        } else {
            detailRow(title, "Default discovery")
        }
    }

    @MainActor
    private func loadAgent() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            agent = try await apiClient.getAgent(agentId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadResources() async {
        guard let apiClient, let serverId = connection.currentServerId else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }
        await connection.serverResourceStore.load(serverId: serverId, api: apiClient)
    }

    @MainActor
    private func archiveAgent() async {
        guard let apiClient else { return }
        isArchiving = true
        defer { isArchiving = false }

        do {
            agent = try await apiClient.archiveAgent(agentId: agentId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AgentLaunchSheet: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    let agent: StoredAgentDefinition
    let onSessionCreated: (Session) -> Void

    @State private var selectedWorkspaceId = ""
    @State private var prompt = ""
    @State private var sessionName = ""
    @State private var worktreeId = ""
    @State private var model = ""
    @State private var thinkingSelection = ""
    @State private var isLaunching = false
    @State private var error: String?

    private var workspaces: [Workspace] { workspaceStore.workspaces }

    private var canLaunch: Bool {
        !selectedWorkspaceId.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLaunching
    }

    var body: some View {
        Form {
            Section("Target") {
                Picker("Workspace", selection: $selectedWorkspaceId) {
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }

                TextField("Worktree ID (optional)", text: $worktreeId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Prompt") {
                TextField("Session name", text: $sessionName)
                TextEditor(text: $prompt)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("agent.launch.prompt")
            }

            Section("Overrides") {
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Thinking", selection: $thinkingSelection) {
                    Text("Agent default").tag("")
                    ForEach(ThinkingLevel.allCases) { level in
                        Text(level.displayTitle).tag(level.rawValue)
                    }
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.themeOrange)
                }
            }
        }
        .navigationTitle("Start \(agent.name)")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isLaunching)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isLaunching ? "Starting…" : "Start") {
                    Task { await launch() }
                }
                .disabled(!canLaunch)
                .accessibilityIdentifier("agent.launch.start")
            }
        }
        .onAppear {
            if selectedWorkspaceId.isEmpty {
                selectedWorkspaceId = workspaces.first?.id ?? ""
            }
        }
    }

    @MainActor
    private func launch() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isLaunching = true
        defer { isLaunching = false }

        do {
            let response = try await apiClient.launchAgentSession(
                agentId: agent.id,
                prompt: prompt,
                workspaceId: selectedWorkspaceId,
                worktreeId: worktreeId,
                model: model,
                thinkingLevel: ThinkingLevel(rawValue: thinkingSelection),
                sessionName: sessionName
            )
            guard let session = response.session else {
                error = response.receipt.reason ?? "Launch did not return a session"
                return
            }
            onSessionCreated(session)
            if let serverId = workspaceStore.activeServerId {
                navigation.openWorkspaceSession(
                    WorkspaceSessionNavTarget(
                        serverId: serverId,
                        sessionId: session.id,
                        workspaceId: session.workspaceId ?? selectedWorkspaceId
                    )
                )
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
