import Foundation
import Observation

/// Whether a value follows the server's default or is an exact list.
enum AgentSelectionMode: String, CaseIterable {
    case inherit
    case exact
}

/// One row of an Agent's capability page: a plugin, an MCP server, a server's tool,
/// or a Skill. `name` is what the definition stores.
struct AgentCapabilityChoice: Identifiable, Equatable {
    let name: String
    let title: String
    let subtitle: String?
    /// A row that cannot be chosen (a plugin whose last load failed).
    var isAvailable = true
    /// The row opens a page of its own (an MCP server and its tools).
    var opensPage = false
    var status: String?

    var id: String { name }
}

/// What Edit Agent edits: the draft Save sends and Cancel drops. The screen and
/// the capability pages it pushes read and change this one observable model, so a
/// change on a pushed page shows on the editor.
@MainActor @Observable
final class AgentNativeEditDraft {
    /// The scope an Agent's MCP servers live in: `capabilities.mcp` names servers from
    /// `mcp.json`, which the global scope holds. A project's own servers are named the
    /// same way, and one this scope does not list keeps its row so it can be turned off.
    static let mcpScopeId = "global"

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

    /// Edit files: a normal session's tools. Off is a read-only Agent: reading and
    /// searching, and whatever plugins and MCP servers it names here.
    var editsFiles: Bool
    var canAsk: Bool
    var canNotify: Bool
    var canDelegate: Bool
    /// An omitted list is every plugin or every configured MCP server; a list is those.
    var pluginsAll: Bool
    var selectedPlugins: Set<String>
    var mcpAll: Bool
    /// A server's tools: `.all`, or the exact names. A server with no tools is not reached,
    /// so it has no entry here.
    var mcpSelection: [String: AgentMcpTools]
    /// Skills by name (a Skill's folder). Omitted follows Pi discovery.
    var skillsAll: Bool
    var selectedSkills: Set<String>
    var contextFiles: Bool
    var sessionHistory: Bool

    var workspaceConstraintMode: AgentSelectionMode
    var selectedAllowedWorkspaceIds: Set<String>
    var requiredRuntime: WorkspaceRuntime?
    var requiredEngine: SessionEngine?

    /// One MCP server as this editor lists it, with the workspace whose `.pi/mcp.json` names it
    /// (nil for the global scope). A project server is still an Agent's to choose, and a row that
    /// pretended otherwise would invite deleting a server the Agent needs.
    struct ListedMcpServer: Identifiable {
        let server: McpServerSummary
        let workspaceName: String?

        var id: String { server.name }
        var name: String { server.name }
    }

    /// Every MCP server this server configures: the global scope's and each workspace's own,
    /// loaded with the editor's catalogs.
    var mcpServers: [ListedMcpServer] = []
    var isLoadingMcpServers = false
    var mcpCatalogError: String?
    var isLoadingResources = false
    var isSaving = false
    var error: String?

    init(agent: StoredAgentDefinition, connection: ServerConnection, serverName: String) {
        self.agent = agent
        self.connection = connection
        self.serverName = serverName
        let definition = agent.definition
        let capabilities = definition.capabilities
        let context = definition.context
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
        editsFiles = capabilities?.editsFiles ?? true
        canAsk = capabilities?.canAsk ?? true
        canNotify = capabilities?.canNotify ?? true
        canDelegate = capabilities?.canDelegate ?? true
        pluginsAll = capabilities?.plugins == nil
        selectedPlugins = Set(capabilities?.plugins ?? [])
        mcpAll = capabilities?.mcp == nil
        mcpSelection = capabilities?.mcp ?? [:]
        skillsAll = context?.skills == nil
        selectedSkills = Set(context?.skills ?? [])
        contextFiles = context?.readsContextFiles ?? true
        sessionHistory = context?.readsSessionHistory ?? true
        workspaceConstraintMode = definition.launchConstraints?.allowedWorkspaceIds == nil ? .inherit : .exact
        selectedAllowedWorkspaceIds = Set(definition.launchConstraints?.allowedWorkspaceIds ?? [])
        requiredRuntime = definition.launchConstraints?.requiredRuntime
        requiredEngine = definition.launchConstraints?.requiredEngine
    }

    // MARK: Validation

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!usesCustomInstructions
                || !instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && canSaveLaunchConstraints
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

    // MARK: Capabilities

    /// A read-only Agent names what it may reach: it never widens by omission, so
    /// turning Edit files off clears both lists.
    func setEditsFiles(_ edits: Bool) {
        editsFiles = edits
        guard !edits else { return }
        pluginsAll = false
        selectedPlugins = []
        mcpAll = false
        mcpSelection = [:]
    }

    /// `false` starts from nothing: an explicit list names what the Agent may use.
    func setPluginsAll(_ all: Bool) {
        pluginsAll = all
        if !all { selectedPlugins = [] }
    }

    func selectPlugin(_ name: String, _ selected: Bool) {
        if selected { selectedPlugins.insert(name) } else { selectedPlugins.remove(name) }
    }

    func setMcpAll(_ all: Bool) {
        mcpAll = all
        if !all { mcpSelection = [:] }
    }

    func selectMcpServer(_ name: String, _ selected: Bool) {
        mcpSelection[name] = selected ? mcpSelection[name] ?? .all : nil
    }

    /// A server's tools, when it is reached at all; nil when it has no entry.
    func mcpTools(_ server: String) -> AgentMcpTools? { mcpSelection[server] }

    func setMcpTools(_ server: String, _ tools: AgentMcpTools) {
        // The server refuses a tool list with no names; a server with no tools is not reached.
        mcpSelection[server] = tools == .tools([]) ? nil : tools
    }

    func setSkillsAll(_ all: Bool) {
        skillsAll = all
        if !all { selectedSkills = [] }
    }

    func selectSkill(_ name: String, _ selected: Bool) {
        if selected { selectedSkills.insert(name) } else { selectedSkills.remove(name) }
    }

    var resolvedCapabilities: AgentCapabilities {
        AgentCapabilities(
            core: editsFiles ? nil : .readonly,
            ask: canAsk,
            notify: canNotify,
            subagent: canDelegate,
            plugins: pluginsAll ? nil : selectedPlugins.sorted(),
            mcp: mcpAll ? nil : Dictionary(uniqueKeysWithValues: mcpSelection.keys.sorted().map {
                ($0, mcpSelection[$0] ?? .all)
            })
        )
    }

    var resolvedContext: AgentContext {
        AgentContext(
            skills: skillsAll ? nil : selectedSkills.sorted(),
            contextFiles: contextFiles,
            sessionHistory: sessionHistory
        )
    }

    // MARK: Catalogs

    var workspaces: [Workspace] { connection.workspaceStore.workspaces }

    var availableSkills: [ServerSkillSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.skills(forServer: serverId)
    }

    /// The plugins an Agent may name, in name order: the server marks them (`agentSelectable`),
    /// so a built-in plugin, a toggle's package, or a row with no tools is never offered, and a
    /// name the server does not offer shows as "Not on this server" instead. A row without a
    /// plugin summary is still a plugin (the live `secret` row is one): its tools are what it
    /// contributes. A plugin is selected by the name its installed extension has, which is the
    /// name a session selects it by.
    var availablePlugins: [ServerExtensionSummary] {
        guard let serverId = connection.currentServerId else { return [] }
        return connection.serverResourceStore.extensions(forServer: serverId)
            .filter { $0.agentSelectable == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The tools a plugin row offers, whether or not its plugin summary is attached.
    private func pluginTools(_ plugin: ServerExtensionSummary) -> [String] {
        plugin.plugin?.tools ?? plugin.contributedTools ?? []
    }

    private func pluginName(_ plugin: ServerExtensionSummary) -> String {
        plugin.plugin?.extensionName ?? plugin.name
    }

    var pluginChoices: [AgentCapabilityChoice] {
        var choices = availablePlugins.map { plugin in
            let tools = pluginTools(plugin)
            return AgentCapabilityChoice(
                name: pluginName(plugin),
                title: plugin.name,
                subtitle: tools.isEmpty
                    ? nil
                    : tools.prefix(3).joined(separator: ", ") + (tools.count > 3 ? ", …" : ""),
                isAvailable: plugin.state != .error,
                status: plugin.state == .error ? (plugin.loadError ?? "Cannot load") : nil
            )
        }
        choices += unlisted(selectedPlugins, listed: choices.map(\.name)) { name in
            AgentCapabilityChoice(name: name, title: name, subtitle: nil, isAvailable: false,
                                  status: "Not on this server")
        }
        return choices
    }

    /// A server's tools as chosen here: none, all of them, or some of them.
    private func mcpToolsSummary(_ listed: ListedMcpServer) -> String {
        let tools = listed.server.tools.count
        let summary: String
        switch mcpSelection[listed.name] {
        case .all: summary = String(localized: "All tools")
        case .tools(let names): summary = "\(names.count) of \(tools) tools"
        case .none: summary = "\(tools) tools"
        }
        guard let workspaceName = listed.workspaceName else { return summary }
        return "\(summary) \u{00B7} \(workspaceName) project"
    }

    var mcpServerChoices: [AgentCapabilityChoice] {
        var choices = mcpServers.map { listed in
            AgentCapabilityChoice(
                name: listed.name,
                title: listed.name,
                subtitle: mcpToolsSummary(listed),
                isAvailable: true,
                opensPage: true,
                status: listed.server.enabled
                    ? (listed.server.error == nil ? nil : listed.server.error)
                    : "Off on this server"
            )
        }
        choices += unlisted(mcpSelection.keys, listed: choices.map(\.name)) { name in
            AgentCapabilityChoice(name: name, title: name, subtitle: nil, isAvailable: false,
                                  opensPage: true, status: "Not on this server")
        }
        return choices
    }

    /// One MCP server's tools: what its last listing reported, and any saved name it
    /// no longer reports so it can be turned off.
    func mcpToolChoices(_ server: String) -> [AgentCapabilityChoice] {
        let listed = mcpServers.first { $0.name == server }?.server.tools ?? []
        var choices = listed.map { name in
            AgentCapabilityChoice(name: name, title: name, subtitle: nil)
        }
        let saved = mcpSelection[server]?.toolNames ?? []
        choices += unlisted(saved, listed: listed) { name in
            AgentCapabilityChoice(name: name, title: name, subtitle: nil, isAvailable: false,
                                  status: "Not on this server")
        }
        return choices
    }

    var skillChoices: [AgentCapabilityChoice] {
        var choices = availableSkills.map { skill in
            AgentCapabilityChoice(
                name: skill.name,
                title: skill.name,
                subtitle: skill.description,
                isAvailable: skill.state != .error,
                status: skill.state == .error ? (skill.loadError ?? "Cannot load") : nil
            )
        }
        choices += unlisted(selectedSkills, listed: choices.map(\.name)) { name in
            AgentCapabilityChoice(name: name, title: name, subtitle: nil, isAvailable: false,
                                  status: "Not on this server")
        }
        return choices
    }

    /// Chosen names the catalog no longer lists, in name order: each keeps a row so a
    /// stale choice can be turned off.
    private func unlisted(
        _ selected: some Sequence<String>,
        listed: [String],
        make: (String) -> AgentCapabilityChoice
    ) -> [AgentCapabilityChoice] {
        let known = Set(listed)
        return Set(selected).filter { !known.contains($0) }.sorted().map(make)
    }

    // MARK: Summaries

    var modelDisplayName: String {
        guard let model = model.managementNilIfBlank else { return "Server default" }
        return SessionFormatting.shortModelName(model) ?? model
    }

    var pluginsSummary: String { selectionSummary(all: pluginsAll, selected: selectedPlugins.count) }
    var mcpSummary: String { selectionSummary(all: mcpAll, selected: mcpSelection.count) }
    var skillsSummary: String { selectionSummary(all: skillsAll, selected: selectedSkills.count) }

    private func selectionSummary(all: Bool, selected: Int) -> String {
        if all { return String(localized: "All") }
        return selected == 0 ? String(localized: "None") : "\(selected) selected"
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

    var pluginCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let store = connection.serverResourceStore
        let sync = store.syncState(for: .extensions, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: store.hasLoadedExtensions(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !availablePlugins.isEmpty
        )
    }

    var mcpCatalogStatus: String? {
        if isLoadingMcpServers { return String(localized: "Loading MCP servers…") }
        guard mcpCatalogError != nil, mcpServers.isEmpty else { return nil }
        return String(localized: "Could not load this server's MCP servers.")
    }

    // MARK: Loading

    func refreshResources(apiClient: APIClient?) async {
        guard let apiClient, let serverId = connection.currentServerId else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }
        await connection.serverResourceStore.load(serverId: serverId, api: apiClient)
    }

    func refreshMcpServers(apiClient: APIClient?) async {
        guard let apiClient else { return }
        isLoadingMcpServers = true
        defer { isLoadingMcpServers = false }
        var listed: [ListedMcpServer] = []
        var failure: String?
        // The global scope, then each workspace's own `.pi/mcp.json`: a project server an Agent
        // names is a server it may reach, so the picker lists it too.
        let scopes: [(id: String, workspaceName: String?)] = [Self.mcpScopeId].map { ($0, nil) }
            + workspaces.map { ($0.id, $0.name) }
        for scope in scopes {
            do {
                let response = try await apiClient.listMcpServers(scopeId: scope.id)
                listed += response.scope.servers.map {
                    ListedMcpServer(server: $0, workspaceName: scope.workspaceName)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
        // One server configured in several scopes is one choice: the first listing (global) keeps
        // its tool list, and a project one labels it.
        var byName: [String: ListedMcpServer] = [:]
        for entry in listed where byName[entry.name] == nil { byName[entry.name] = entry }
        mcpServers = byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // The rows it already has stay: a saved server is still turned off from here.
        mcpCatalogError = failure
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

        do {
            let updated = try await apiClient.updateAgentNative(
                agentId: agent.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.managementNilIfBlank,
                instructions: usesCustomInstructions
                    ? AgentInstructions(mode: instructionMode, text: instructionText)
                    : nil,
                capabilities: resolvedCapabilities,
                context: resolvedContext,
                model: model.managementNilIfBlank,
                thinkingLevel: thinkingLevel,
                launchConstraints: resolvedLaunchConstraints,
                previouslyHadLaunchConstraints: agent.definition.launchConstraints != nil,
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
            requiredRuntime: requiredRuntime,
            requiredEngine: requiredEngine
        )
        return constraints.isEmpty ? nil : constraints
    }
}
