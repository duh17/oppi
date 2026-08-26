import SwiftUI

enum AgentToolSelectionMode: String, CaseIterable {
    case inherit
    case exact
    case existingPolicy

    var title: String {
        switch self {
        case .inherit: "Pi defaults"
        case .exact: "Choose tools"
        case .existingPolicy: "Existing policy"
        }
    }
}

struct AgentExtensionToolGroup: Identifiable {
    let id: String
    let name: String
    let tools: [ServerToolSummary]
}

private enum AgentResourceSelectionMode: String, CaseIterable {
    case inherit
    case exact

    var title: String {
        switch self {
        case .inherit: "Inherit Pi settings"
        case .exact: "Exact selection"
        }
    }
}

enum AgentResourceCatalogState: Equatable {
    case unavailable
    case loading
    case neverLoaded
    case failed
    case cachedOffline
    case empty
    case content

    static func resolve(
        hasLoaded: Bool,
        isSyncing: Bool,
        lastSyncFailed: Bool,
        hasRows: Bool
    ) -> Self {
        guard hasLoaded else {
            if isSyncing { return .loading }
            return lastSyncFailed ? .failed : .neverLoaded
        }
        if lastSyncFailed { return .cachedOffline }
        return hasRows ? .content : .empty
    }

    static func isExactSelectionSaveAllowed(
        initialSelectionWasInherited: Bool,
        catalogState: Self
    ) -> Bool {
        !initialSelectionWasInherited || [.empty, .content, .cachedOffline].contains(catalogState)
    }

    func statusMessage(for resourceName: String) -> String? {
        switch self {
        case .unavailable:
            return "Connect to load the server's \(resourceName) catalog."
        case .loading:
            return "Loading \(resourceName.lowercased())…"
        case .neverLoaded:
            return "The \(resourceName) catalog has not loaded yet."
        case .failed:
            return "Could not load the \(resourceName.lowercased()) catalog. Existing selections are kept."
        case .cachedOffline:
            return "Showing cached \(resourceName.lowercased()) settings. Pull to retry."
        case .empty, .content:
            return nil
        }
    }
}

struct AgentNativeEditView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss

    let agent: StoredAgentDefinition
    let onSaved: (StoredAgentDefinition) -> Void

    @State private var name: String
    @State private var description: String
    @State private var usesCustomInstructions: Bool
    @State private var instructionMode: AgentInstructionMode
    @State private var instructionText: String
    @State private var model: String
    @State private var thinkingLevel: ThinkingLevel?
    @State private var toolSelectionMode: AgentToolSelectionMode
    @State private var selectedToolNames: Set<String>
    @State private var extensionToolDetailsById: [String: ServerExtensionDetail] = [:]
    @State private var extensionToolInspectionIds: Set<String> = []
    @State private var isLoadingExtensionTools = false
    @State private var skillSelectionMode: AgentResourceSelectionMode
    @State private var selectedSkillPaths: Set<String>
    @State private var extensionSelectionMode: AgentResourceSelectionMode
    @State private var selectedExtensionIds: Set<String>
    @State private var workspaceConstraintMode: AgentResourceSelectionMode
    @State private var selectedAllowedWorkspaceIds: Set<String>
    @State private var requiredRuntime: WorkspaceRuntime?
    @State private var isShowingModelPicker = false
    @State private var isLoadingResources = false
    @State private var isSaving = false
    @State private var error: String?

    init(agent: StoredAgentDefinition, onSaved: @escaping (StoredAgentDefinition) -> Void) {
        self.agent = agent
        self.onSaved = onSaved
        let definition = agent.definition
        _name = State(initialValue: definition.name)
        _description = State(initialValue: definition.description ?? "")
        _usesCustomInstructions = State(initialValue: definition.instructions != nil)
        _instructionMode = State(initialValue: definition.instructions?.mode ?? .append)
        _instructionText = State(initialValue: definition.instructions?.text ?? "")
        _model = State(initialValue: definition.sessionDefaults?.model ?? "")
        _thinkingLevel = State(initialValue: definition.sessionDefaults?.thinkingLevel)
        let defaults = definition.sessionDefaults
        let toolMode: AgentToolSelectionMode = if defaults?.tools != nil {
            .exact
        } else if defaults?.excludeTools != nil || defaults?.noTools != nil {
            .existingPolicy
        } else {
            .inherit
        }
        _toolSelectionMode = State(initialValue: toolMode)
        _selectedToolNames = State(initialValue: Set(defaults?.tools ?? []))
        _skillSelectionMode = State(
            initialValue: definition.resources?.skillPaths == nil ? .inherit : .exact
        )
        _selectedSkillPaths = State(initialValue: Set(definition.resources?.skillPaths ?? []))
        _extensionSelectionMode = State(
            initialValue: definition.resources?.extensionIds == nil ? .inherit : .exact
        )
        _selectedExtensionIds = State(initialValue: Set(definition.resources?.extensionIds ?? []))
        _workspaceConstraintMode = State(
            initialValue: definition.launchConstraints?.allowedWorkspaceIds == nil ? .inherit : .exact
        )
        _selectedAllowedWorkspaceIds = State(
            initialValue: Set(definition.launchConstraints?.allowedWorkspaceIds ?? [])
        )
        _requiredRuntime = State(initialValue: definition.launchConstraints?.requiredRuntime)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!usesCustomInstructions
                || !instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && canSaveResourceSelections
            && canSaveLaunchConstraints
            && canSaveToolSelection
            && !isSaving
    }

    private var canSaveLaunchConstraints: Bool {
        guard workspaceConstraintMode == .exact else { return true }
        guard !selectedAllowedWorkspaceIds.isEmpty else { return false }
        return workspaceStore.workspaces.contains { workspace in
            selectedAllowedWorkspaceIds.contains(workspace.id)
                && (requiredRuntime.map { $0 == (workspace.runtime ?? .host) } ?? true)
        }
    }

    private var canSaveResourceSelections: Bool {
        let skillsAllowed = skillSelectionMode != .exact
            || AgentResourceCatalogState.isExactSelectionSaveAllowed(
                initialSelectionWasInherited: agent.definition.resources?.skillPaths == nil,
                catalogState: skillCatalogState
            )
        let extensionsAllowed = extensionSelectionMode != .exact
            || AgentResourceCatalogState.isExactSelectionSaveAllowed(
                initialSelectionWasInherited: agent.definition.resources?.extensionIds == nil,
                catalogState: extensionCatalogState
            )
        return skillsAllowed && extensionsAllowed
    }

    private var canSaveToolSelection: Bool {
        guard toolSelectionMode == .exact else { return true }
        return agent.definition.sessionDefaults?.tools != nil || !availableBuiltInTools.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("agent.nativeEdit.name")
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("agent.nativeEdit.description")
                }

                Section {
                    Toggle("Custom system prompt", isOn: $usesCustomInstructions)
                        .accessibilityIdentifier("agent.nativeEdit.customPrompt")

                    if usesCustomInstructions {
                        Picker("Behavior", selection: $instructionMode) {
                            Text("Append").tag(AgentInstructionMode.append)
                            Text("Replace").tag(AgentInstructionMode.replace)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("agent.nativeEdit.promptMode")

                        TextEditor(text: $instructionText)
                            .frame(minHeight: 180)
                            .accessibilityLabel("System prompt")
                            .accessibilityIdentifier("agent.nativeEdit.prompt")
                    }
                } header: {
                    Text("System Prompt")
                } footer: {
                    if usesCustomInstructions {
                        Text(instructionMode == .append
                            ? "Adds these instructions after the server's default system prompt."
                            : "Uses these instructions instead of the server's default system prompt.")
                    } else {
                        Text("Uses the server's default system prompt.")
                    }
                }

                Section("Pi Session Defaults") {
                    Button {
                        isShowingModelPicker = true
                    } label: {
                        LabeledContent("Model") {
                            Text(modelDisplayName)
                                .foregroundStyle(.themeFg)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent.nativeEdit.model")

                    if !model.isEmpty {
                        Button("Use Server Default Model") { model = "" }
                            .foregroundStyle(.themeBlue)
                    }

                    Picker("Thinking", selection: $thinkingLevel) {
                        Text("Default").tag(ThinkingLevel?.none)
                        ForEach(ThinkingLevel.allCases) { level in
                            Text(level.displayTitle).tag(Optional(level))
                        }
                    }
                    .accessibilityIdentifier("agent.nativeEdit.thinking")

                    NavigationLink {
                        AgentToolSelectionView(
                            mode: $toolSelectionMode,
                            selectedNames: $selectedToolNames,
                            builtInTools: availableBuiltInTools,
                            extensionGroups: effectiveExtensionToolGroups,
                            unavailableNames: unavailableSelectedToolNames,
                            defaultSelection: effectiveDefaultToolNames,
                            existingPolicySummary: existingToolPolicySummary,
                            isLoadingExtensionTools: isLoadingExtensionTools
                        )
                    } label: {
                        LabeledContent("Tools", value: toolSelectionSummary)
                    }
                    .accessibilityIdentifier("agent.nativeEdit.tools")
                }

                Section {
                    Picker("Skills", selection: $skillSelectionMode) {
                        ForEach(AgentResourceSelectionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("agent.nativeEdit.skillMode")

                    if skillSelectionMode == .exact {
                        NavigationLink {
                            AgentSkillSelectionView(
                                skills: availableSkills,
                                selectedPaths: $selectedSkillPaths,
                                catalogState: skillCatalogState
                            )
                        } label: {
                            LabeledContent("Selected Skills", value: selectionCount(selectedSkillPaths.count))
                        }
                        .accessibilityIdentifier("agent.nativeEdit.skills")
                    }

                    Picker("Extensions", selection: $extensionSelectionMode) {
                        ForEach(AgentResourceSelectionMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("agent.nativeEdit.extensionMode")

                    if extensionSelectionMode == .exact {
                        NavigationLink {
                            AgentExtensionSelectionView(
                                extensions: availableExtensions,
                                selectedIds: $selectedExtensionIds,
                                catalogState: extensionCatalogState
                            )
                        } label: {
                            LabeledContent(
                                "Selected Extensions",
                                value: selectionCount(selectedExtensionIds.count)
                            )
                        }
                        .accessibilityIdentifier("agent.nativeEdit.extensions")
                    }

                    if isLoadingResources {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Refreshing discovered resources…")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
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
                } header: {
                    Text("Resources")
                } footer: {
                    Text("Inherit follows normal Pi discovery. Exact selection can be empty to give this Agent no Skills or optional Extensions. Exact selections explicitly override server discovery, including resources currently Disabled or Off, for this Agent only.")
                }

                Section {
                    Picker("Runtime", selection: $requiredRuntime) {
                        Text("Any runtime").tag(WorkspaceRuntime?.none)
                        Text("Host").tag(Optional(WorkspaceRuntime.host))
                        Text("Sandbox").tag(Optional(WorkspaceRuntime.sandbox))
                    }
                    .accessibilityIdentifier("agent.nativeEdit.requiredRuntime")

                    Picker("Workspaces", selection: $workspaceConstraintMode) {
                        Text("Any workspace").tag(AgentResourceSelectionMode.inherit)
                        Text("Allowed list").tag(AgentResourceSelectionMode.exact)
                    }
                    .accessibilityIdentifier("agent.nativeEdit.workspaceMode")

                    if workspaceConstraintMode == .exact {
                        NavigationLink {
                            AgentWorkspaceSelectionView(
                                workspaces: workspaceStore.workspaces,
                                selectedIds: $selectedAllowedWorkspaceIds,
                                requiredRuntime: requiredRuntime
                            )
                        } label: {
                            LabeledContent(
                                "Allowed Workspaces",
                                value: selectionCount(selectedAllowedWorkspaceIds.count)
                            )
                        }
                        .accessibilityIdentifier("agent.nativeEdit.workspaces")
                    }
                } header: {
                    Text("Launch Constraints")
                } footer: {
                    Text("Only compatible workspaces appear when this Agent starts. The server enforces the same restrictions for API and scheduled launches.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.themeRed)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("Edit Agent")
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
                    .accessibilityIdentifier("agent.nativeEdit.save")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheet(currentModel: model.managementNilIfBlank) { selected in
                model = ModelSwitchPolicy.fullModelID(for: selected)
                AppPreferences.RecentModels.record(model)
            }
        }
        .task { await refreshResources() }
        .task(id: extensionToolRefreshKey) {
            await refreshSelectedExtensionToolDetails()
        }
    }

    private var availableBuiltInTools: [ServerToolSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.builtInTools(forServer: serverId)
    }

    private var availableSkills: [ServerSkillSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.skills(forServer: serverId)
    }

    private var availableExtensions: [ServerExtensionSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.extensions(forServer: serverId)
    }

    private var effectiveExtensionToolGroups: [AgentExtensionToolGroup] {
        let effectiveExtensions = availableExtensions.filter { resource in
            switch extensionSelectionMode {
            case .inherit:
                resource.state == .on
            case .exact:
                selectedExtensionIds.contains(resource.id)
            }
        }
        return effectiveExtensions.compactMap { resource in
            let details = extensionToolDetailsById[resource.id]
            let tools = details?.contributedToolDetails
                ?? resource.contributedToolDetails
                ?? (details?.contributedTools ?? resource.contributedTools ?? []).map {
                    ServerToolSummary(name: $0)
                }
            guard !tools.isEmpty else { return nil }
            return AgentExtensionToolGroup(id: resource.id, name: resource.name, tools: tools)
        }
    }

    private var knownToolNames: Set<String> {
        Set(availableBuiltInTools.map(\.name) + effectiveExtensionToolGroups.flatMap { $0.tools.map(\.name) })
    }

    private var unavailableSelectedToolNames: [String] {
        selectedToolNames
            .subtracting(knownToolNames)
            .sorted()
    }

    private var effectiveDefaultToolNames: Set<String> {
        var names = Set(availableBuiltInTools.filter { $0.defaultEnabled == true }.map(\.name))
        names.formUnion(effectiveExtensionToolGroups.flatMap { $0.tools.map(\.name) })
        names.subtract(agent.definition.sessionDefaults?.excludeTools ?? [])
        if agent.definition.sessionDefaults?.noTools == .all {
            names.removeAll()
        } else if agent.definition.sessionDefaults?.noTools == .builtin {
            names.subtract(availableBuiltInTools.map(\.name))
        }
        return names
    }

    private var toolSelectionSummary: String {
        switch toolSelectionMode {
        case .inherit:
            return "Pi defaults"
        case .exact:
            return selectedToolNames.isEmpty ? "None" : "\(selectedToolNames.count) selected"
        case .existingPolicy:
            return "Existing policy"
        }
    }

    private var existingToolPolicySummary: String? {
        guard agent.definition.sessionDefaults?.tools == nil,
              (agent.definition.sessionDefaults?.excludeTools != nil
                || agent.definition.sessionDefaults?.noTools != nil) else { return nil }
        if let noTools = agent.definition.sessionDefaults?.noTools {
            return noTools.displayName
        }
        if let excluded = agent.definition.sessionDefaults?.excludeTools, !excluded.isEmpty {
            return "Excludes \(excluded.joined(separator: ", "))"
        }
        return "Existing advanced policy"
    }

    private var extensionToolRefreshKey: String {
        let catalogIds = availableExtensions.map(\.id).sorted().joined(separator: ",")
        return "\(extensionSelectionMode.rawValue):\(selectedExtensionIds.sorted().joined(separator: ",")):\(catalogIds)"
    }

    private var skillCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let sync = connection.serverResourceStore.syncState(for: .skills, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: connection.serverResourceStore.hasLoadedSkills(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !availableSkills.isEmpty
        )
    }

    private var extensionCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let sync = connection.serverResourceStore.syncState(for: .extensions, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: connection.serverResourceStore.hasLoadedExtensions(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !availableExtensions.isEmpty
        )
    }

    private var modelDisplayName: String {
        guard let model = model.managementNilIfBlank else { return "Server default" }
        return SessionFormatting.shortModelName(model) ?? model
    }

    private func selectionCount(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }

    @MainActor
    private func refreshResources() async {
        guard let apiClient, let serverId = connection.currentServerId else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }
        await connection.serverResourceStore.load(serverId: serverId, api: apiClient)
    }

    @MainActor
    private func refreshSelectedExtensionToolDetails() async {
        guard extensionSelectionMode == .exact,
              let apiClient else { return }
        let resources = availableExtensions.filter {
            selectedExtensionIds.contains($0.id)
                && $0.contributedToolDetails == nil
                && $0.contributedTools == nil
                && extensionToolDetailsById[$0.id] == nil
                && !extensionToolInspectionIds.contains($0.id)
        }
        guard !resources.isEmpty else { return }

        isLoadingExtensionTools = true
        defer { isLoadingExtensionTools = false }
        for resource in resources {
            guard !Task.isCancelled else { return }
            guard extensionToolDetailsById[resource.id] == nil,
                  extensionToolInspectionIds.insert(resource.id).inserted else { continue }
            defer { extensionToolInspectionIds.remove(resource.id) }
            do {
                extensionToolDetailsById[resource.id] = try await apiClient.inspectAgentExtensionTools(
                    id: resource.id
                )
            } catch {
                // Keep the resource selection intact. The tool screen presents
                // saved unknown names as unavailable rather than dropping them.
            }
        }
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
            let originalDefaults = agent.definition.sessionDefaults
            let toolPolicy: (tools: [String]?, excluded: [String]?, noTools: AgentNoToolsMode?)
            switch toolSelectionMode {
            case .inherit:
                toolPolicy = (nil, nil, nil)
            case .exact:
                toolPolicy = (selectedToolNames.sorted(), nil, nil)
            case .existingPolicy:
                toolPolicy = (
                    originalDefaults?.tools,
                    originalDefaults?.excludeTools,
                    originalDefaults?.noTools
                )
            }

            let updated = try await apiClient.updateAgentNative(
                agentId: agent.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.managementNilIfBlank,
                instructions: usesCustomInstructions
                    ? AgentInstructions(mode: instructionMode, text: instructionText)
                    : nil,
                model: model.managementNilIfBlank,
                thinkingLevel: thinkingLevel,
                skillPaths: skillSelectionMode == .inherit ? nil : selectedSkillPaths.sorted(),
                extensionIds: extensionSelectionMode == .inherit ? nil : selectedExtensionIds.sorted(),
                launchConstraints: resolvedLaunchConstraints,
                previouslyHadLaunchConstraints: agent.definition.launchConstraints != nil,
                tools: toolPolicy.tools,
                excludeTools: toolPolicy.excluded,
                noTools: toolPolicy.noTools
            )
            onSaved(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var resolvedLaunchConstraints: AgentLaunchConstraints? {
        let constraints = AgentLaunchConstraints(
            allowedWorkspaceIds: workspaceConstraintMode == .inherit
                ? nil
                : selectedAllowedWorkspaceIds.sorted(),
            requiredRuntime: requiredRuntime
        )
        return constraints.isEmpty ? nil : constraints
    }
}

private struct AgentWorkspaceSelectionView: View {
    let workspaces: [Workspace]
    @Binding var selectedIds: Set<String>
    let requiredRuntime: WorkspaceRuntime?

    private var displayedWorkspaces: [Workspace] {
        workspaces.filter { workspace in
            selectedIds.contains(workspace.id)
                || (requiredRuntime.map { $0 == (workspace.runtime ?? .host) } ?? true)
        }
    }

    var body: some View {
        List {
            if displayedWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No Compatible Workspace",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Add a workspace that matches the required runtime, or choose Any runtime.")
                )
            } else {
                ForEach(displayedWorkspaces) { workspace in
                    let selected = selectedIds.contains(workspace.id)
                    Button {
                        if selected {
                            selectedIds.remove(workspace.id)
                        } else {
                            selectedIds.insert(workspace.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? .themeBlue : .themeComment)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.name)
                                    .foregroundStyle(.themeFg)
                                Text(workspaceRuntimeSummary(workspace))
                                    .font(.caption)
                                    .foregroundStyle(
                                        runtimeMatches(workspace) ? .themeComment : .themeOrange
                                    )
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
        }
        .navigationTitle("Allowed Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
    }

    private func runtimeMatches(_ workspace: Workspace) -> Bool {
        requiredRuntime.map { $0 == (workspace.runtime ?? .host) } ?? true
    }

    private func workspaceRuntimeSummary(_ workspace: Workspace) -> String {
        let runtime = (workspace.runtime ?? .host).rawValue.capitalized
        return runtimeMatches(workspace) ? runtime : "\(runtime) · Does not match required runtime"
    }
}

struct AgentToolSelectionView: View {
    @Binding var mode: AgentToolSelectionMode
    @Binding var selectedNames: Set<String>
    let builtInTools: [ServerToolSummary]
    let extensionGroups: [AgentExtensionToolGroup]
    let unavailableNames: [String]
    let defaultSelection: Set<String>
    let existingPolicySummary: String?
    let isLoadingExtensionTools: Bool
    var title = "Agent Tools"
    var inheritFooter =
        "Uses Pi's default coding tools and tools from effective extensions. Future extension tools follow discovery automatically."
    var exactFooter =
        "Only selected names are available. This freezes both built-in and extension tools until the Agent is edited again."
    var showsExtensionTools = true

    private var selectableModes: [AgentToolSelectionMode] {
        existingPolicySummary == nil
            ? [.inherit, .exact]
            : [.inherit, .exact, .existingPolicy]
    }

    private var knownNames: Set<String> {
        Set(builtInTools.map(\.name) + extensionGroups.flatMap { $0.tools.map(\.name) })
    }

    private var modeBinding: Binding<AgentToolSelectionMode> {
        Binding(
            get: { mode },
            set: { newMode in
                if newMode == .exact, mode != .exact {
                    selectedNames = defaultSelection
                }
                mode = newMode
            }
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Selection", selection: modeBinding) {
                    ForEach(selectableModes, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("agent.nativeEdit.toolMode")
            } footer: {
                switch mode {
                case .inherit:
                    Text(inheritFooter)
                case .exact:
                    Text(exactFooter)
                case .existingPolicy:
                    Text("This Agent uses \(existingPolicySummary ?? "an existing tool policy"). Choose another mode to replace it.")
                }
            }

            if mode == .exact {
                if builtInTools.isEmpty {
                    Section {
                        Label("Built-in tool catalog unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.themeOrange)
                    } footer: {
                        Text("Reconnect to a current server before creating a new exact selection.")
                    }
                } else {
                    Section("Built-in Pi Tools") {
                        ForEach(builtInTools) { tool in
                            toolButton(tool, source: nil, canAdd: true)
                        }
                    }
                }

                if showsExtensionTools, isLoadingExtensionTools {
                    Section {
                        ProgressView("Loading selected extension tools…")
                    }
                }

                if showsExtensionTools {
                    ForEach(extensionGroups) { group in
                        Section(group.name) {
                            ForEach(group.tools) { tool in
                                toolButton(tool, source: group.name, canAdd: true)
                            }
                        }
                    }
                }

                if !unavailableNames.isEmpty {
                    Section {
                        ForEach(unavailableNames, id: \.self) { name in
                            toolButton(
                                ServerToolSummary(
                                    name: name,
                                    description: "Not resolved by the server-global catalog"
                                ),
                                source: nil,
                                canAdd: false
                            )
                        }
                    } header: {
                        Text("Unavailable Selections")
                    } footer: {
                        Text("These saved names are preserved. Launch succeeds only in a workspace that supplies them; deselect a name to remove it.")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            if mode == .exact {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Select All") { selectedNames.formUnion(knownNames) }
                            .disabled(knownNames.isEmpty)
                        Button("Select None") { selectedNames.removeAll() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Tool selection actions")
                }
            }
        }
    }

    private func toolButton(
        _ tool: ServerToolSummary,
        source: String?,
        canAdd: Bool
    ) -> some View {
        let isSelected = selectedNames.contains(tool.name)
        return Button {
            if isSelected {
                selectedNames.remove(tool.name)
            } else if canAdd {
                selectedNames.insert(tool.name)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name)
                        .foregroundStyle(.themeFg)
                    if let description = tool.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(2)
                    }
                    if !canAdd {
                        Text("Unavailable")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.themeOrange)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !canAdd)
        .accessibilityLabel(tool.name)
        .accessibilityHint(tool.description ?? "")
        .accessibilityValue([
            isSelected ? "Selected" : "Not selected",
            source,
            canAdd ? nil : "Unavailable",
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent.nativeEdit.tool.\(tool.name)")
    }
}

extension AgentToolSelectionView {
    init(
        mode: Binding<AgentToolSelectionMode>,
        selectedNames: Binding<Set<String>>,
        builtInTools: [ServerToolSummary],
        defaultSelection: Set<String>,
        title: String,
        inheritFooter: String,
        exactFooter: String
    ) {
        self.init(
            mode: mode,
            selectedNames: selectedNames,
            builtInTools: builtInTools,
            extensionGroups: [],
            unavailableNames: [],
            defaultSelection: defaultSelection,
            existingPolicySummary: nil,
            isLoadingExtensionTools: false,
            title: title,
            inheritFooter: inheritFooter,
            exactFooter: exactFooter,
            showsExtensionTools: false
        )
    }
}

private struct AgentSkillSelectionView: View {
    let skills: [ServerSkillSummary]
    @Binding var selectedPaths: Set<String>
    let catalogState: AgentResourceCatalogState

    private var selectableSkills: [ServerSkillSummary] {
        skills.filter { $0.path != nil }
    }

    private var discoveredPaths: Set<String> {
        Set(selectableSkills.compactMap(\.path))
    }

    private var unavailablePaths: [String] {
        selectedPaths.subtracting(discoveredPaths).sorted()
    }

    var body: some View {
        List {
            catalogStatus

            if catalogState == .empty && selectableSkills.isEmpty && unavailablePaths.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Skills Found",
                        systemImage: "hammer",
                        description: Text("This server has no selectable Skills.")
                    )
                }
            } else if catalogState == .content && selectableSkills.isEmpty && unavailablePaths.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Selectable Skills",
                        systemImage: "hammer",
                        description: Text("The loaded Skills catalog has no selectable paths.")
                    )
                }
            }

            if !selectableSkills.isEmpty {
                Section("Discovered Skills") {
                    ForEach(selectableSkills) { skill in
                        if let path = skill.path {
                            resourceButton(
                                resourceKind: "skill",
                                id: path,
                                title: skill.name,
                                subtitle: skill.description,
                                status: skill.state == .error
                                    ? (skill.loadError ?? "Cannot load")
                                    : skill.state == .disabled ? "Disabled by default · selectable for this Agent" : nil,
                                canAdd: skill.state != .error
                            )
                        }
                    }
                }
            }

            if !unavailablePaths.isEmpty {
                Section {
                    ForEach(unavailablePaths, id: \.self) { path in
                        resourceButton(
                            resourceKind: "skill",
                            id: path,
                            title: path,
                            subtitle: "No longer discovered on this server",
                            status: "Unavailable",
                            canAdd: false
                        )
                    }
                } header: {
                    Text("Unavailable Selections")
                } footer: {
                    Text("Deselect these paths before saving, or restore them on the server.")
                }
            }
        }
        .navigationTitle("Agent Skills")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
    }

    @ViewBuilder
    private var catalogStatus: some View {
        switch catalogState {
        case .loading:
            Section {
                ProgressView("Loading Skills…")
            }
        case .neverLoaded:
            Section {
                Label("Skills catalog has not loaded", systemImage: "questionmark.circle")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Reconnect or retry before choosing a new exact selection.")
            }
        case .failed:
            Section {
                Label("Skills unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved. Retry before choosing new Skills.")
            }
        case .cachedOffline:
            Section {
                Label("Showing cached Skills", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.themeOrange)
            }
        case .unavailable:
            Section {
                Label("Skills unavailable offline", systemImage: "wifi.slash")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved, and unavailable selections can still be removed.")
            }
        case .empty, .content:
            EmptyView()
        }
    }

    private func resourceButton(
        resourceKind: String,
        id: String,
        title: String,
        subtitle: String,
        status: String?,
        canAdd: Bool
    ) -> some View {
        let isSelected = selectedPaths.contains(id)
        return Button {
            if isSelected {
                selectedPaths.remove(id)
            } else if canAdd {
                selectedPaths.insert(id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.themeFg)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                    if let status {
                        Text(status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.themeOrange)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !canAdd)
        .accessibilityLabel(title)
        .accessibilityValue([isSelected ? "Selected" : "Not selected", status].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent.nativeEdit.\(resourceKind).\(id)")
    }
}

private struct AgentExtensionSelectionView: View {
    let extensions: [ServerExtensionSummary]
    @Binding var selectedIds: Set<String>
    let catalogState: AgentResourceCatalogState

    private var discoveredIds: Set<String> { Set(extensions.map(\.id)) }

    private var unavailableIds: [String] {
        selectedIds.subtracting(discoveredIds).sorted()
    }

    var body: some View {
        List {
            catalogStatus

            if catalogState == .empty && extensions.isEmpty && unavailableIds.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Extensions Found",
                        systemImage: "puzzlepiece.extension",
                        description: Text("This server has no selectable Extensions.")
                    )
                }
            }

            if !extensions.isEmpty {
                Section("Discovered Extensions") {
                    ForEach(extensions) { resource in
                        resourceButton(
                            resourceKind: "extension",
                            id: resource.id,
                            title: resource.name,
                            subtitle: resource.description ?? resource.provenance.label,
                            status: resource.state == .error
                                ? (resource.loadError ?? "Cannot load")
                                : resource.state == .off ? "Off by default · selectable for this Agent" : nil,
                            canAdd: resource.state != .error
                        )
                    }
                }
            }

            if !unavailableIds.isEmpty {
                Section {
                    ForEach(unavailableIds, id: \.self) { id in
                        resourceButton(
                            resourceKind: "extension",
                            id: id,
                            title: id,
                            subtitle: "No longer discovered on this server",
                            status: "Unavailable",
                            canAdd: false
                        )
                    }
                } header: {
                    Text("Unavailable Selections")
                } footer: {
                    Text("Deselect these identifiers before saving, or restore them on the server.")
                }
            }
        }
        .navigationTitle("Agent Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
    }

    @ViewBuilder
    private var catalogStatus: some View {
        switch catalogState {
        case .loading:
            Section {
                ProgressView("Loading Extensions…")
            }
        case .neverLoaded:
            Section {
                Label("Extensions catalog has not loaded", systemImage: "questionmark.circle")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Reconnect or retry before choosing a new exact selection.")
            }
        case .failed:
            Section {
                Label("Extensions unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved. Retry before choosing new Extensions.")
            }
        case .cachedOffline:
            Section {
                Label("Showing cached Extensions", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.themeOrange)
            }
        case .unavailable:
            Section {
                Label("Extensions unavailable offline", systemImage: "wifi.slash")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved, and unavailable selections can still be removed.")
            }
        case .empty, .content:
            EmptyView()
        }
    }

    private func resourceButton(
        resourceKind: String,
        id: String,
        title: String,
        subtitle: String,
        status: String?,
        canAdd: Bool
    ) -> some View {
        let isSelected = selectedIds.contains(id)
        return Button {
            if isSelected {
                selectedIds.remove(id)
            } else if canAdd {
                selectedIds.insert(id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.themeFg)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                    if let status {
                        Text(status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.themeOrange)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !canAdd)
        .accessibilityLabel(title)
        .accessibilityValue([isSelected ? "Selected" : "Not selected", status].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent.nativeEdit.\(resourceKind).\(id)")
    }
}

extension String {
    var managementNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
