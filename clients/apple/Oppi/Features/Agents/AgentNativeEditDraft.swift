import Foundation
import Observation

enum AgentResourceSelectionMode: String, CaseIterable {
    case inherit
    case exact

    var title: String {
        switch self {
        case .inherit: "Inherit Pi settings"
        case .exact: "Exact selection"
        }
    }
}

/// What Edit Agent edits: the draft Save sends and Cancel drops. The screen
/// and the selection pages it pushes read and change this one observable
/// model, so a change on a pushed page shows on the editor.
@MainActor @Observable
final class AgentNativeEditDraft {
    let agent: StoredAgentDefinition
    let connection: ServerConnection
    /// The server the Agent is saved on, for the pages' scope sentences.
    let serverName: String

    var name: String
    var description: String
    var usesCustomInstructions: Bool
    var instructionMode: AgentInstructionMode
    var instructionText: String
    var model: String
    var thinkingLevel: ThinkingLevel?
    /// This device's chat style for the Agent's sessions; nil follows
    /// Settings → Chat → Style. Never sent to the server.
    var chatStyle: AppPreferences.ChatDisplay.Style?
    var toolSelectionMode: AgentToolSelectionMode
    var selectedToolNames: Set<String>
    var skillSelectionMode: AgentResourceSelectionMode
    var selectedSkillPaths: Set<String>
    var extensionSelectionMode: AgentResourceSelectionMode
    var selectedExtensionIds: Set<String>
    var workspaceConstraintMode: AgentResourceSelectionMode
    var selectedAllowedWorkspaceIds: Set<String>
    var requiredRuntime: WorkspaceRuntime?
    var extensionToolDetailsById: [String: ServerExtensionDetail] = [:]
    var isLoadingExtensionTools = false
    var isLoadingResources = false
    var isSaving = false
    var error: String?
    @ObservationIgnored private var extensionToolInspectionIds: Set<String> = []

    init(agent: StoredAgentDefinition, connection: ServerConnection, serverName: String) {
        self.agent = agent
        self.connection = connection
        self.serverName = serverName
        let definition = agent.definition
        let defaults = definition.sessionDefaults
        name = definition.name
        description = definition.description ?? ""
        usesCustomInstructions = definition.instructions != nil
        instructionMode = definition.instructions?.mode ?? .append
        instructionText = definition.instructions?.text ?? ""
        model = defaults?.model ?? ""
        thinkingLevel = defaults?.thinkingLevel
        chatStyle = connection.currentServerId.flatMap {
            AppPreferences.ChatDisplay.agentStyle(serverId: $0, agentId: agent.id)
        }
        toolSelectionMode = if defaults?.tools != nil {
            .exact
        } else if defaults?.excludeTools != nil || defaults?.noTools != nil {
            .existingPolicy
        } else {
            .inherit
        }
        selectedToolNames = Set(defaults?.tools ?? [])
        skillSelectionMode = definition.resources?.skillPaths == nil ? .inherit : .exact
        selectedSkillPaths = Set(definition.resources?.skillPaths ?? [])
        extensionSelectionMode = definition.resources?.extensionIds == nil ? .inherit : .exact
        selectedExtensionIds = Set(definition.resources?.extensionIds ?? [])
        workspaceConstraintMode = definition.launchConstraints?.allowedWorkspaceIds == nil ? .inherit : .exact
        selectedAllowedWorkspaceIds = Set(definition.launchConstraints?.allowedWorkspaceIds ?? [])
        requiredRuntime = definition.launchConstraints?.requiredRuntime
    }

    // MARK: Validation

    var canSave: Bool {
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
        return workspaces.contains { workspace in
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

    // MARK: Catalogs

    var workspaces: [Workspace] { connection.workspaceStore.workspaces }

    var availableBuiltInTools: [ServerToolSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.builtInTools(forServer: serverId)
    }

    var availableSkills: [ServerSkillSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.skills(forServer: serverId)
    }

    /// The Pi extensions an Agent can select: a row that is only a plugin loads in durable
    /// sessions, never through an Agent's classic selection.
    var availableExtensions: [ServerExtensionSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.extensions(forServer: serverId).filter(\.isPiExtension)
    }

    var effectiveExtensionToolGroups: [AgentExtensionToolGroup] {
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

    var unavailableSelectedToolNames: [String] {
        let known = Set(availableBuiltInTools.map(\.name) + effectiveExtensionToolGroups.flatMap { $0.tools.map(\.name) })
        return selectedToolNames.subtracting(known).sorted()
    }

    var effectiveDefaultToolNames: Set<String> {
        let defaults = agent.definition.sessionDefaults
        var names = Set(availableBuiltInTools.filter { $0.defaultEnabled == true }.map(\.name))
        names.formUnion(effectiveExtensionToolGroups.flatMap { $0.tools.map(\.name) })
        names.subtract(defaults?.excludeTools ?? [])
        if defaults?.noTools == .all {
            names.removeAll()
        } else if defaults?.noTools == .builtin {
            names.subtract(availableBuiltInTools.map(\.name))
        }
        return names
    }

    var existingToolPolicySummary: String? {
        let defaults = agent.definition.sessionDefaults
        guard defaults?.tools == nil,
              defaults?.excludeTools != nil || defaults?.noTools != nil else { return nil }
        if let noTools = defaults?.noTools {
            return noTools.displayName
        }
        if let excluded = defaults?.excludeTools, !excluded.isEmpty {
            return "Excludes \(excluded.joined(separator: ", "))"
        }
        return "Existing advanced policy"
    }

    var skillCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let store = connection.serverResourceStore
        let sync = store.syncState(for: .skills, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: store.hasLoadedSkills(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !availableSkills.isEmpty
        )
    }

    var extensionCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let store = connection.serverResourceStore
        let sync = store.syncState(for: .extensions, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: store.hasLoadedExtensions(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !availableExtensions.isEmpty
        )
    }

    // MARK: Summaries

    var modelDisplayName: String {
        guard let model = model.managementNilIfBlank else { return "Server default" }
        return SessionFormatting.shortModelName(model) ?? model
    }

    var toolSelectionSummary: String {
        switch toolSelectionMode {
        case .inherit:
            return "Pi defaults"
        case .exact:
            return selectedToolNames.isEmpty ? "None" : "\(selectedToolNames.count) selected"
        case .existingPolicy:
            return "Existing policy"
        }
    }

    /// Changes when the selected extensions or the catalog do, which is when
    /// the screen re-inspects selected extensions for their tools.
    var extensionToolRefreshKey: String {
        let catalogIds = availableExtensions.map(\.id).sorted().joined(separator: ",")
        let selectedIds = selectedExtensionIds.sorted().joined(separator: ",")
        return "\(extensionSelectionMode.rawValue):\(selectedIds):\(catalogIds)"
    }

    // MARK: Loading

    func refreshResources(apiClient: APIClient?) async {
        guard let apiClient, let serverId = connection.currentServerId else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }
        await connection.serverResourceStore.load(serverId: serverId, api: apiClient)
    }

    func refreshSelectedExtensionToolDetails(apiClient: APIClient?) async {
        guard extensionSelectionMode == .exact, let apiClient else { return }
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
                extensionToolDetailsById[resource.id] = try await apiClient.inspectAgentExtensionTools(id: resource.id)
            } catch {
                // Keep the resource selection intact. The tool screen presents
                // saved unknown names as unavailable rather than dropping them.
            }
        }
    }

    // MARK: Saving

    /// Sends the definition, then keeps the chat style on this device.
    /// Nil when the save failed; `error` says why.
    func save(apiClient: APIClient?) async -> StoredAgentDefinition? {
        guard let apiClient else {
            error = "Server is offline"
            return nil
        }
        isSaving = true
        defer { isSaving = false }

        let originalDefaults = agent.definition.sessionDefaults
        let toolPolicy: (tools: [String]?, excluded: [String]?, noTools: AgentNoToolsMode?)
        switch toolSelectionMode {
        case .inherit:
            toolPolicy = (nil, nil, nil)
        case .exact:
            toolPolicy = (selectedToolNames.sorted(), nil, nil)
        case .existingPolicy:
            toolPolicy = (originalDefaults?.tools, originalDefaults?.excludeTools, originalDefaults?.noTools)
        }

        do {
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
                noTools: toolPolicy.noTools,
                // The version this form opened: a prompt edited in the editor
                // meanwhile is a conflict, not a silent overwrite.
                expectedVersion: agent.version
            )
            if let serverId = connection.currentServerId {
                AppPreferences.ChatDisplay.setAgentStyle(chatStyle, serverId: serverId, agentId: agent.id)
            }
            return updated
        } catch {
            self.error = RecordVersionConflict.message(for: error) ?? error.localizedDescription
            return nil
        }
    }

    private var resolvedLaunchConstraints: AgentLaunchConstraints? {
        let constraints = AgentLaunchConstraints(
            allowedWorkspaceIds: workspaceConstraintMode == .inherit ? nil : selectedAllowedWorkspaceIds.sorted(),
            requiredRuntime: requiredRuntime
        )
        return constraints.isEmpty ? nil : constraints
    }
}
