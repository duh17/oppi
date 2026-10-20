import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSession")

struct QuickSessionSlashCommandLoadKey: Equatable {
    let serverId: String?
    let workspaceId: String?
    let apiClientIdentifier: ObjectIdentifier?
}

struct QuickSessionFileIndexLoadKey: Equatable {
    let serverId: String?
    let workspaceId: String?
    let worktreeId: String
    let apiClientIdentifier: ObjectIdentifier?
}

private enum QuickSessionSlashCommandLoadResult: Sendable {
    case promptTemplates([SlashCommand])
    case skills([SlashCommand])
    case promptTemplateFailure(String)
    case skillFailure(String)
}

/// What Quick Session loads for its destination: the server's Agents, the
/// workspace's worktrees, its prompt templates and skills, and the checkout's
/// file index for @ mentions.
extension QuickSessionModel {
    private var slashCommandLoadKey: QuickSessionSlashCommandLoadKey {
        let apiClient = selectedServerId.flatMap {
            coordinator.connection(for: $0)?.apiClient
        }
        return QuickSessionSlashCommandLoadKey(
            serverId: selectedServerId,
            workspaceId: selectedWorkspace?.id,
            apiClientIdentifier: apiClient.map(ObjectIdentifier.init)
        )
    }

    private var fileIndexLoadKey: QuickSessionFileIndexLoadKey {
        QuickSessionFileIndexLoadKey(
            serverId: selectedServerId,
            workspaceId: selectedWorkspace?.id,
            worktreeId: QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                selectedId: selectedWorktreeId,
                worktrees: worktrees
            ),
            apiClientIdentifier: slashCommandLoadKey.apiClientIdentifier
        )
    }

    /// Starts the slash-command, worktree, and file-index loads for the current
    /// destination, replacing loads for an earlier one. The view controller
    /// calls this from `updateProperties()`, so a change to anything a load key
    /// reads (the server, workspace, worktree, or API client) calls it again.
    func syncLoads() {
        let slashKey = slashCommandLoadKey
        if slashCommandTask?.key != slashKey {
            slashCommandTask?.task.cancel()
            worktreeTask?.cancel()
            slashCommandTask = (slashKey, Task { [weak self] in
                await self?.loadSlashCommands(for: slashKey)
            })
            let workspace = selectedWorkspace
            worktreeTask = Task { [weak self] in
                await self?.loadWorktrees(for: workspace)
            }
        }
        let indexKey = fileIndexLoadKey
        if fileIndexTask?.key != indexKey {
            fileIndexTask?.task.cancel()
            fileIndexTask = (indexKey, Task { [weak self] in
                await self?.ensureFileIndex(for: indexKey)
            })
        }
    }

    // MARK: Worktrees

    private func loadWorktrees(for workspace: Workspace?) async {
        worktreeLoadGeneration &+= 1
        let generation = worktreeLoadGeneration
        guard let workspace else {
            worktrees = []
            selectedWorktreeId = WorkspaceWorktree.mainId
            isLoadingWorktrees = false
            return
        }
        // A locked workspace (or server) asks first; nothing from the
        // previous workspace stays in the picker while it does, or after a cancel.
        if let serverId = selectedServerId ?? coordinator.activeServerId {
            let lockTarget = ScopedLockTarget.workspace(serverId: serverId, workspaceId: workspace.id)
            if ScopedLockService.shared.isLocked(lockTarget) {
                worktrees = []
                selectedWorktreeId = WorkspaceWorktree.mainId
                guard await ScopedLockService.shared.authorize(lockTarget),
                      generation == worktreeLoadGeneration else { return }
            }
        }

        isLoadingWorktrees = worktrees.isEmpty
        defer {
            if generation == worktreeLoadGeneration {
                isLoadingWorktrees = false
            }
        }

        guard let api = selectedServerConnection()?.apiClient else {
            if generation == worktreeLoadGeneration {
                worktrees = []
            }
            return
        }

        do {
            let fetched = try await api.listWorkspaceWorktrees(workspaceId: workspace.id)
            guard generation == worktreeLoadGeneration else { return }
            worktrees = fetched
            selectedWorktreeId = QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                selectedId: selectedWorktreeId,
                worktrees: fetched
            )
        } catch {
            guard generation == worktreeLoadGeneration else { return }
            logger.warning("Failed to load worktrees for quick session: \(error.localizedDescription, privacy: .public)")
            worktrees = []
        }
    }

    // MARK: Slash commands and file suggestions

    private func loadSlashCommands(for key: QuickSessionSlashCommandLoadKey) async {
        slashCommandLoadGeneration &+= 1
        let generation = slashCommandLoadGeneration
        promptTemplateSlashCommands = []
        skillSlashCommands = []

        guard let serverId = key.serverId,
              let workspaceId = key.workspaceId,
              let apiClientIdentifier = key.apiClientIdentifier,
              key == slashCommandLoadKey,
              let api = coordinator.connection(for: serverId)?.apiClient,
              ObjectIdentifier(api) == apiClientIdentifier else {
            return
        }
        // Prompt templates and skills are workspace content: a locked
        // workspace (or server) asks first and cancel loads nothing.
        guard await ScopedLockService.shared.authorize(.workspace(serverId: serverId, workspaceId: workspaceId)),
              generation == slashCommandLoadGeneration,
              key == slashCommandLoadKey else {
            return
        }

        await withTaskGroup(of: QuickSessionSlashCommandLoadResult.self) { group in
            group.addTask {
                do {
                    let options = try await api.getWorkspaceQuickActions(workspaceId: workspaceId).actions
                    return .promptTemplates(SlashCommand.promptTemplates(from: options))
                } catch {
                    return .promptTemplateFailure(error.localizedDescription)
                }
            }
            group.addTask {
                do {
                    let skills = try await api.listSkills(workspaceId: workspaceId)
                    return .skills(SlashCommand.skills(from: skills))
                } catch {
                    return .skillFailure(error.localizedDescription)
                }
            }

            for await result in group {
                guard !Task.isCancelled,
                      generation == slashCommandLoadGeneration,
                      key == slashCommandLoadKey else {
                    group.cancelAll()
                    return
                }

                switch result {
                case .promptTemplates(let commands):
                    promptTemplateSlashCommands = commands
                case .skills(let commands):
                    skillSlashCommands = commands
                case .promptTemplateFailure(let message):
                    logger.warning("Failed to load prompt templates for quick session: \(message, privacy: .public)")
                case .skillFailure(let message):
                    logger.warning("Failed to load skills for quick session: \(message, privacy: .public)")
                }
            }
        }
    }

    private func ensureFileIndex(for key: QuickSessionFileIndexLoadKey) async {
        guard key == fileIndexLoadKey, let serverId = key.serverId,
              let workspaceId = key.workspaceId,
              let connection = coordinator.connection(for: serverId) else { return }
        connection.clearFileSuggestions()
        // File paths are workspace content: a locked workspace (or server)
        // asks first and cancel loads nothing.
        guard await ScopedLockService.shared.authorize(.workspace(serverId: serverId, workspaceId: workspaceId)),
              key == fileIndexLoadKey else { return }
        guard let api = connection.apiClient,
              ObjectIdentifier(api) == key.apiClientIdentifier else { return }
        connection.fileIndexStore.ensureLoaded(
            workspaceId: workspaceId,
            worktreeId: key.worktreeId,
            apiClient: api
        )
        if case .atFile(let query) = ComposerAutocomplete.context(for: text) {
            connection.fetchFileSuggestions(query: query)
        }
    }

    /// The first @ query can arrive before /paths finishes loading.
    func fileIndexPathsDidChange() {
        if case .atFile(let query) = ComposerAutocomplete.context(for: text) {
            updateFileSuggestions(query)
        }
    }

    func updateFileSuggestions(_ query: String?) {
        guard let connection = selectedServerConnection() else { return }
        guard let query else {
            connection.clearFileSuggestions()
            return
        }
        let key = fileIndexLoadKey
        guard let workspaceId = key.workspaceId,
              let serverId = key.serverId,
              // An index loaded before the workspace locked stays unused.
              !ScopedLockService.shared.isLocked(.workspace(serverId: serverId, workspaceId: workspaceId)),
              connection.fileIndexStore.workspaceId == workspaceId,
              connection.fileIndexStore.worktreeId == key.worktreeId else {
            connection.clearFileSuggestions()
            return
        }
        connection.fetchFileSuggestions(query: query)
    }

    // MARK: Agents

    /// `.pending` when an Agent is still to be applied (the launch context's, else the remembered one).
    func pendingAgentResolution(requestedAgentId: String?) -> DurableSessions.AgentResolution {
        requestedAgentId != nil || AppPreferences.QuickSession.lastAgentId != nil ? .pending : .resolved
    }

    /// The Agent list did not load. If an Agent was wanted, keep the launch blocked until
    /// the user clears it rather than let it go out as a plain session.
    private func holdLaunchAfterAgentLoadFailure(requestedAgentId: String?, detail: String?) {
        guard pendingAgentResolution(requestedAgentId: requestedAgentId) == .pending else {
            agentResolution = .resolved
            return
        }
        agentResolution = .failed
        let reason = detail.map { ": \($0)" } ?? "."
        error = requestedAgentId != nil
            ? "Could not load this Agent\(reason)"
            : "Could not load your saved Agent\(reason) Choose Pi to start without it."
    }

    func loadAgentsForSelectedServer(requestedAgentId: String? = nil) async {
        guard let targetServerId = selectedServerId ?? coordinator.activeServerId else {
            availableAgents = []
            selectedAgentId = nil
            holdLaunchAfterAgentLoadFailure(requestedAgentId: requestedAgentId, detail: nil)
            return
        }
        if selectedServerId == nil { selectedServerId = targetServerId }
        agentLoadGeneration &+= 1
        let generation = agentLoadGeneration
        isLoadingAgents = true
        agentResolution = pendingAgentResolution(requestedAgentId: requestedAgentId)
        // `selectAgent` resolves a pending load. A choice made while the list is
        // in flight, including Pi, must survive the load's completion.
        let startedPending = agentResolution == .pending
        var userChoseDuringLoad: Bool { startedPending && agentResolution == .resolved }

        guard let connection = coordinator.connection(for: targetServerId),
              let api = connection.apiClient else {
            if generation == agentLoadGeneration, selectedServerId == targetServerId {
                availableAgents = []
                selectedAgentId = nil
                holdLaunchAfterAgentLoadFailure(requestedAgentId: requestedAgentId, detail: nil)
                isLoadingAgents = false
            }
            return
        }

        do {
            let agents = try await api.listAgents()
                .filter { $0.status == .active }
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            guard generation == agentLoadGeneration, selectedServerId == targetServerId else {
                return
            }
            availableAgents = agents
            if userChoseDuringLoad {
                // Keep the user's pick; only drop it if this server no longer has it.
                if let picked = selectedAgentId, !agents.contains(where: { $0.id == picked }) {
                    selectedAgentId = nil
                    error = "This Agent is no longer available on the selected server."
                }
                requireExplicitCompatibleWorkspaceIfNeeded()
                isLoadingAgents = false
                return
            } else if let requestedAgentId {
                if agents.contains(where: { $0.id == requestedAgentId }) {
                    selectedAgentId = requestedAgentId
                } else {
                    selectedAgentId = nil
                    error = "This Agent is no longer available on the selected server."
                }
            } else {
                selectedAgentId = QuickSessionLaunchRouting.preferredAgentId(
                    lastAgentId: AppPreferences.QuickSession.lastAgentId,
                    availableAgentIds: agents.map(\.id)
                )
            }
            agentModelOverride = nil
            agentThinkingOverride = nil
            agentResolution = .resolved
            requireExplicitCompatibleWorkspaceIfNeeded()
            isLoadingAgents = false
        } catch {
            guard generation == agentLoadGeneration, selectedServerId == targetServerId else {
                return
            }
            logger.warning("Failed to load agents for quick session: \(error.localizedDescription, privacy: .public)")
            availableAgents = []
            if userChoseDuringLoad, selectedAgentId == nil {
                // The user already chose Pi; a failed list cannot block that launch.
                isLoadingAgents = false
                return
            }
            selectedAgentId = nil
            holdLaunchAfterAgentLoadFailure(requestedAgentId: requestedAgentId, detail: error.localizedDescription)
            isLoadingAgents = false
        }
    }
}
