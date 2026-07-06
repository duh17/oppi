import SwiftUI

struct AgentManagementView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var agents: [AgentDefinitionSummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var editorContext: AgentEditorContext?

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
                    description: Text("Create reusable Agent definitions for common session setups.")
                )
                .listRowBackground(Color.themeBg)
            } else {
                Section {
                    ForEach(agents) { agent in
                        NavigationLink {
                            AgentDetailView(agentId: agent.id)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorContext = AgentEditorContext(agent: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Agent")
                .accessibilityIdentifier("agents.create.open")
            }
        }
        .refreshable { await loadAgents() }
        .task { await loadAgents() }
        .sheet(item: $editorContext) { context in
            NavigationStack {
                AgentEditView(agent: context.agent) {
                    await loadAgents()
                }
            }
        }
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

private struct AgentEditorContext: Identifiable {
    let agent: StoredAgentDefinition?

    var id: String { agent?.id ?? "new" }
}

private struct AgentSummaryRow: View {
    let agent: AgentDefinitionSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.themeBlue)
                .frame(width: 30, height: 30)

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

    @State private var agent: StoredAgentDefinition?
    @State private var isLoading = false
    @State private var error: String?
    @State private var isShowingEditor = false
    @State private var isShowingLaunch = false
    @State private var isShowingSchedule = false
    @State private var isArchiving = false

    var body: some View {
        List {
            if isLoading && agent == nil {
                ProgressView("Loading agent…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.themeBg)
            } else if let agent {
                Section("Definition") {
                    detailRow("Name", agent.definition.name)
                    if let description = agent.definition.description, !description.isEmpty {
                        detailRow("Description", description)
                    }
                    detailRow("Status", agent.status.rawValue.capitalized)
                    detailRow("Version", "v\(agent.version)")
                }

                if let instructions = agent.definition.instructions {
                    Section("Instructions") {
                        detailRow("Mode", instructions.mode.rawValue)
                        Text(instructions.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.themeFg)
                            .textSelection(.enabled)
                    }
                }

                Section("Pi Defaults") {
                    let defaults = agent.definition.sessionDefaults
                    detailRow("Model", defaults?.model?.nilIfBlank ?? "Server default")
                    detailRow("Thinking", defaults?.thinkingLevel?.rawValue ?? "Default")
                    detailRow("Tools", toolSummary(defaults))
                }

                Section("Resources") {
                    resourceRow("Skills", values: agent.definition.resources?.skillIds)
                    resourceRow("Prompt templates", values: agent.definition.resources?.promptTemplateIds)
                    resourceRow("Extensions", values: agent.definition.resources?.extensionIds)
                    if agent.definition.resources?.noContextFiles == true {
                        Label("Context files disabled", systemImage: "doc.badge.gearshape")
                            .font(.subheadline)
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
                if agent != nil {
                    Button("Edit") {
                        isShowingEditor = true
                    }
                    .accessibilityIdentifier("agents.detail.edit")

                    Menu {
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
        .task(id: agentId) { await loadAgent() }
        .refreshable { await loadAgent() }
        .sheet(isPresented: $isShowingEditor) {
            if let agent {
                NavigationStack {
                    AgentEditView(agent: agent) {
                        await loadAgent()
                    }
                }
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
                NavigationStack {
                    ScheduleEditView(
                        schedule: nil,
                        prefill: ScheduleEditPrefill(agentId: agent.id, agentName: agent.name)
                    ) {
                        await loadAgent()
                    }
                }
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

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.themeComment)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func resourceRow(_ title: String, values: [String]?) -> some View {
        if let values, !values.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(values.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .textSelection(.enabled)
            }
        } else {
            detailRow(title, "Default discovery")
        }
    }

    private func toolSummary(_ defaults: AgentSessionDefaults?) -> String {
        guard let defaults else { return "Default" }
        if let noTools = defaults.noTools { return noTools.displayName }
        let allow = defaults.tools?.count ?? 0
        let deny = defaults.excludeTools?.count ?? 0
        if allow == 0 && deny == 0 { return "Default" }
        return "\(allow) allowed · \(deny) excluded"
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

private struct AgentEditView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    let agent: StoredAgentDefinition?
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var instructionMode: AgentInstructionMode = .append
    @State private var instructions = ""
    @State private var noContextFiles = false
    @State private var skillIdsText = ""
    @State private var promptTemplateIdsText = ""
    @State private var extensionIdsText = ""
    @State private var model = ""
    @State private var thinkingSelection = ""
    @State private var noToolsSelection = ""
    @State private var toolsText = ""
    @State private var excludeToolsText = ""
    @State private var isSaving = false
    @State private var error: String?

    private let thinkingOptions: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("agent.edit.name")
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("agent.edit.description")
            }

            Section {
                Picker("Mode", selection: $instructionMode) {
                    ForEach(AgentInstructionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }

                TextEditor(text: $instructions)
                    .frame(minHeight: 160)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("agent.edit.instructions")
            } header: {
                Text("Instructions")
            } footer: {
                Text("Instructions are stored on the Agent. Workspaces and worktrees are still chosen per launch.")
            }

            Section {
                Toggle("Ignore discovered context files", isOn: $noContextFiles)
                TextField("Skill IDs", text: $skillIdsText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Prompt template IDs", text: $promptTemplateIdsText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Extension IDs", text: $extensionIdsText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Pi Resources")
            } footer: {
                Text("Separate values with commas or new lines. Empty fields use normal Pi discovery.")
            }

            Section {
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Thinking", selection: $thinkingSelection) {
                    Text("Default").tag("")
                    ForEach(thinkingOptions, id: \.rawValue) { level in
                        Text(level.rawValue).tag(level.rawValue)
                    }
                }
                Picker("Tool filter", selection: $noToolsSelection) {
                    Text("Default").tag("")
                    ForEach(AgentNoToolsMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                TextField("Allowed tools", text: $toolsText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Excluded tools", text: $excludeToolsText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Session Defaults")
            } footer: {
                Text("Tool fields use Pi's tools, excludeTools, and noTools names.")
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.themeOrange)
                }
            }
        }
        .navigationTitle(agent == nil ? "New Agent" : "Edit Agent")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("agent.edit.save")
            }
        }
        .onAppear(perform: populate)
    }

    private func populate() {
        guard let definition = agent?.definition else { return }
        name = definition.name
        description = definition.description ?? ""
        instructionMode = definition.instructions?.mode ?? .append
        instructions = definition.instructions?.text ?? ""
        noContextFiles = definition.resources?.noContextFiles == true
        skillIdsText = Self.joinList(definition.resources?.skillIds)
        promptTemplateIdsText = Self.joinList(definition.resources?.promptTemplateIds)
        extensionIdsText = Self.joinList(definition.resources?.extensionIds)
        model = definition.sessionDefaults?.model ?? ""
        thinkingSelection = definition.sessionDefaults?.thinkingLevel?.rawValue ?? ""
        noToolsSelection = definition.sessionDefaults?.noTools?.rawValue ?? ""
        toolsText = Self.joinList(definition.sessionDefaults?.tools)
        excludeToolsText = Self.joinList(definition.sessionDefaults?.excludeTools)
    }

    @MainActor
    private func save() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let definition = buildDefinition()
            if let agent {
                _ = try await apiClient.updateAgent(agentId: agent.id, definition: definition)
            } else {
                _ = try await apiClient.createAgent(definition)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func buildDefinition() -> AgentDefinition {
        let cleanInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let resources = AgentResources(
            agentsFiles: nil,
            noContextFiles: noContextFiles ? true : nil,
            skillIds: Self.parseList(skillIdsText),
            promptTemplateIds: Self.parseList(promptTemplateIdsText),
            extensionIds: Self.parseList(extensionIdsText)
        )
        let defaults = AgentSessionDefaults(
            model: model.nilIfBlank,
            thinkingLevel: ThinkingLevel(rawValue: thinkingSelection),
            tools: Self.parseList(toolsText),
            excludeTools: Self.parseList(excludeToolsText),
            noTools: AgentNoToolsMode(rawValue: noToolsSelection)
        )

        return AgentDefinition(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.nilIfBlank,
            instructions: cleanInstructions.isEmpty ? nil : AgentInstructions(mode: instructionMode, text: cleanInstructions),
            resources: resources.isEmpty ? nil : resources,
            sessionDefaults: defaults.isEmpty ? nil : defaults
        )
    }

    private static func parseList(_ text: String) -> [String]? {
        let values = text
            .split { separator in
                separator == "," || separator == "\n" || separator == "\r"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private static func joinList(_ values: [String]?) -> String {
        values?.joined(separator: ", ") ?? ""
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

    private let thinkingOptions: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]

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
                    ForEach(thinkingOptions, id: \.rawValue) { level in
                        Text(level.rawValue).tag(level.rawValue)
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
