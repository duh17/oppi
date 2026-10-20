import UIKit

/// The workspaces of one server in the workspace picker.
struct QuickSessionWorkspacePickerSection {
    let id: String
    let name: String
    let workspaces: [Workspace]
    let iconAssetCache: IconAssetCache?
}

/// Quick Session's state and actions: the destination (workspace, worktree,
/// Agent, thread), the model and thinking level, the draft, and the launch.
///
/// Presented from Oppi, the Control widget, App Intents, or saved share intake.
/// It stays focused on one task: pick workspace (and a worktree when the
/// workspace has more than one checkout), optionally pick an Agent, compose the
/// first message, then create and navigate to the new session.
///
/// **Flow**: Pick workspace/worktree/Agent → compose message → send → session created →
/// navigate to ChatViewController. Create and Agent launch send the resolved checkout.
/// Hidden single-checkout workspaces still bind to Main. Plain Pi uses workspace
/// session create + optional auto-send. A selected Agent uses `launchAgentSession`
/// so definition defaults apply.
///
/// This file holds the state, what it derives, and the destination choices.
/// The rest is split by concern: `+Setup` (the start and the initial
/// destination), `+Loads` (Agents, worktrees, slash commands, file index),
/// `+Draft` (draft persistence), and `+Launch` (create or launch the session).
///
/// `QuickSessionViewController` shows it and feeds its draft to the composer;
/// both read it in `updateProperties()`, so a change re-runs only what reads it.
@MainActor @Observable
final class QuickSessionModel {
    @ObservationIgnored let coordinator: ConnectionCoordinator
    @ObservationIgnored let navigation: AppNavigation
    @ObservationIgnored let composerDraftStore: ComposerDraftStore?
    /// Closes Quick Session; set by its view controller.
    @ObservationIgnored var onDismiss: () -> Void = {}
    @ObservationIgnored private let durableExperimentEnabled = AppPreferences.Experiments.durableSessionsEnabled
    @ObservationIgnored private let durableByDefault = UserDefaults.standard.bool(
        forKey: AppPreferences.Experiments.durableSessionsDefaultKey
    )

    // MARK: Draft

    // The composer edits these through `editText`, `editAttachments`, and
    // `editRepoPointers`, which save the draft. Loading the saved draft sets
    // them directly and saves nothing; a restore or a start's own content sets
    // them all, then saves once. A save from a property observer ran after
    // only one field was set, so it saved a draft without the rest and its
    // attachment files went with it.
    var text = ""
    var textBeforeRecording: String?
    var pendingAttachments: [PendingAttachment] = []
    var pendingRepoPointers: [PendingFileReference] = []
    var busyStreamingBehavior: StreamingBehavior = .followUp
    /// The message a successful launch sent. The closing sheet must not save it back as a draft.
    @ObservationIgnored var launchedDraftPayload: ComposerDraftPayload?
    /// This sheet neither loads nor saves the Quick Session draft (a Live Voice start,
    /// until it stops with an error).
    @ObservationIgnored var keepsStoredDraft = false

    // MARK: Destination

    var selectedServerId: String? {
        didSet {
            guard selectedServerId != oldValue else { return }
            configureVoiceInputForSelectedServer()
            guard isInitialized else { return }
            Task {
                await loadAgentsForSelectedServer()
                if let api = selectedServerConnection()?.apiClient {
                    await selectedChatState.refreshModelCache(api: api)
                }
            }
        }
    }
    var selectedWorkspace: Workspace?
    @ObservationIgnored var selectedWorkspaceSelectionSource = "unknown"
    var selectedWorktreeId = WorkspaceWorktree.mainId
    var worktrees: [WorkspaceWorktree] = []
    var isLoadingWorktrees = false
    @ObservationIgnored var worktreeLoadGeneration: UInt64 = 0
    /// Set when launched from a thread; the new session joins that thread.
    var threadParent: QuickSessionThreadParent?
    /// A Live Voice start's workspace is the one it asked for, or Quick Session's own
    /// remembered pick, not a fallback.
    @ObservationIgnored var liveVoicePickIsRequested = false

    // MARK: Agent, model, and engine

    /// `nil` = plain Pi. Remembered last Agent is restored after agents load.
    var selectedAgentId: String?
    var availableAgents: [AgentDefinitionSummary] = []
    var isLoadingAgents = false
    @ObservationIgnored var agentLoadGeneration: UInt64 = 0
    @ObservationIgnored var shouldRememberAgentSelection = true
    /// Whether the launch context's or remembered Agent has been applied. A launch is
    /// blocked while it is not, so a saved Agent's launch never goes out as a plain session.
    var agentResolution: DurableSessions.AgentResolution = .resolved
    /// When an Agent is selected, model/thinking only apply if the user sets them.
    var agentModelOverride: String?
    var agentThinkingOverride: ThinkingLevel?
    private var selectedModelId: String?
    private(set) var thinkingLevel: ThinkingLevel = AppPreferences.QuickSession.lastThinkingLevel
    /// The engine the user picked with the pill for this one launch; `nil` follows the default.
    private var chosenEngine: SessionEngine?
    /// The Incognito pill's choice for this one launch. Applies to plain Pi only:
    /// a saved Agent launch has to resume its created session, which an
    /// incognito session refuses.
    private(set) var incognitoChosen = false

    // MARK: Composer content

    var promptTemplateSlashCommands: [SlashCommand] = []
    var skillSlashCommands: [SlashCommand] = []
    @ObservationIgnored var slashCommandLoadGeneration: UInt64 = 0
    var voiceInputManager: VoiceInputManager?
    @ObservationIgnored private var voiceComposerGeneration: Int?

    // MARK: Presentation and launch

    var showModelPicker = false
    var showExpandedComposer = false
    var showWorkspacePicker = false
    var showWorktreePicker = false
    var showAgentPicker = false
    var isInitialized = false
    var isCreating = false
    @ObservationIgnored var agentSubmitAttempt: AgentQuickSessionSubmitAttempt?
    var error: String? {
        didSet {
            if error != oldValue, error != nil { restoreStoredDraftAfterLiveVoiceStart() }
        }
    }
    var launchFailure: AgentLaunchFailureResponse?

    @ObservationIgnored var slashCommandTask: (key: QuickSessionSlashCommandLoadKey, task: Task<Void, Never>)?
    @ObservationIgnored var worktreeTask: Task<Void, Never>?
    @ObservationIgnored var fileIndexTask: (key: QuickSessionFileIndexLoadKey, task: Task<Void, Never>)?

    init(root: AppRootEnvironment) {
        coordinator = root.coordinator
        navigation = root.navigation
        composerDraftStore = root.composerDraftStore
    }

    // MARK: Derived values

    /// All workspaces across all connected servers.
    var rawServerWorkspaces: [(serverId: String, workspace: Workspace)] {
        coordinator.connections.flatMap { serverId, conn in
            conn.workspaceStore.workspaces.map { (serverId: serverId, workspace: $0) }
        }
    }

    private var effectiveLaunchConstraints: AgentLaunchConstraints? {
        guard let recovery = launchFailure?.recovery,
              recovery.allowedWorkspaceIds != nil || recovery.requiredRuntime != nil else {
            return selectedAgent?.launchConstraints
        }
        return AgentLaunchConstraints(
            allowedWorkspaceIds: recovery.allowedWorkspaceIds,
            requiredRuntime: recovery.requiredRuntime
        )
    }

    private var allServerWorkspaces: [(serverId: String, workspace: Workspace)] {
        guard let constraints = effectiveLaunchConstraints else { return rawServerWorkspaces }
        return rawServerWorkspaces.filter { entry in
            entry.serverId == selectedServerId && constraints.allows(entry.workspace)
        }
    }

    /// Durability is per server, so it follows the selected workspace's server.
    var engineDecision: DurableSessions.LaunchDecision {
        DurableSessions.launchDecision(
            experimentEnabled: durableExperimentEnabled,
            serverOffersDurable: selectedServerConnection()?.durableSessionsAvailable == true,
            durableByDefault: durableByDefault,
            savedAgentSelected: selectedAgentId != nil,
            incognito: launchesIncognito,
            chosenEngine: chosenEngine,
            agentResolution: agentResolution
        )
    }

    /// The Incognito pill shows, and its choice applies, only for a plain Pi launch.
    var offersIncognito: Bool {
        selectedAgentId == nil
    }

    var launchesIncognito: Bool {
        incognitoChosen && offersIncognito
    }

    var engine: SessionEngine {
        engineDecision.engine
    }

    var workspacePickerSections: [QuickSessionWorkspacePickerSection] {
        let grouped = Dictionary(grouping: allServerWorkspaces, by: \.serverId)
        return grouped.keys.sorted().map { serverId in
            QuickSessionWorkspacePickerSection(
                id: serverId,
                name: coordinator.serverStore.server(for: serverId)?.name ?? serverId,
                workspaces: (grouped[serverId] ?? []).map(\.workspace),
                iconAssetCache: coordinator.connection(for: serverId)?.iconAssetCache
            )
        }
    }

    var workspacePickerEmptyMessage: String {
        selectedAgent == nil
            ? "Pair or refresh a server, then try again."
            : "\(selectedAgent?.name ?? "This Agent") requires a compatible workspace. Edit the Agent or add one, then try again."
    }

    /// Plain Pi and Agent launches send a model only after an explicit picker choice.
    var modelPresentation: NewSessionModelPresentation {
        NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: selectedAgentId != nil
                ? agentModelOverride
                : selectedModelId,
            isAgent: selectedAgentId != nil,
            catalogModels: selectedChatState.cachedModels,
            agentConfiguredModelId: selectedAgent?.sessionDefaults?.model
        )
    }

    var effectiveModelId: String? {
        modelPresentation.requestModelId
    }

    var displayedModelId: String? {
        modelPresentation.displayModelId
    }

    var effectiveThinkingLevel: ThinkingLevel {
        if selectedAgentId != nil {
            return NewSessionThinkingPresentation.displayedLevel(
                explicitlySelected: agentThinkingOverride,
                agentConfigured: selectedAgent?.sessionDefaults?.thinkingLevel
            )
        }
        return thinkingLevel
    }

    var supportedThinkingLevels: [ThinkingLevel] {
        ThinkingLevelMenuSource.levels(for: displayedModelId, in: selectedChatState.cachedModels)
    }

    /// Plain Pi may start without a first message; an Agent needs one.
    var allowsEmptySubmit: Bool {
        selectedAgentId == nil && !engineDecision.blocksLaunch
    }

    var selectedAgent: AgentDefinitionSummary? {
        guard let selectedAgentId else { return nil }
        return availableAgents.first(where: { $0.id == selectedAgentId })
    }

    var selectedChatState: ChatSessionState {
        selectedServerConnection()?.chatState ?? coordinator.activeConnection.chatState
    }

    /// Loads the selected server's Genmoji workspace and Agent icons.
    var selectedServerIconAssetCache: IconAssetCache? {
        selectedServerConnection()?.iconAssetCache
    }

    var showsWorktreePicker: Bool {
        QuickSessionWorktreePickerPolicy.shouldShowPicker(worktreeCount: worktrees.count)
    }

    var selectedWorktree: WorkspaceWorktree? {
        let resolvedId = QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
            selectedId: selectedWorktreeId,
            worktrees: worktrees
        )
        return worktrees.first { $0.id == resolvedId }
    }

    var slashCommands: [SlashCommand] {
        promptTemplateSlashCommands + skillSlashCommands
    }

    /// The error's recovery actions.
    var offersChooseCompatibleWorkspace: Bool {
        launchFailure?.recovery.actions.contains(.chooseWorkspace) == true
    }

    var offersOpenAgents: Bool {
        launchFailure?.recovery.actions.contains(.editAgent) == true
            || (selectedAgent != nil && allServerWorkspaces.isEmpty)
    }

    func selectedServerConnection() -> ServerConnection? {
        if let selectedServerId {
            return coordinator.connection(for: selectedServerId)
        }
        return coordinator.activeConnection
    }

    /// Starts the session and opens it straight into a Live Voice call; none while the
    /// selected server's voice backend is not set up.
    var liveVoiceEntry: (() -> Void)? {
        guard selectedServerConnection()?.liveVoiceAvailable == true else { return nil }
        return { [weak self] in self?.handleSend(startsLiveVoice: true) }
    }

    /// Quick Session closed: stop its loads and hand back the microphone.
    /// Keeps the manager alive until cancel finishes so the SpeechAnalyzer and
    /// mic tap cannot outlive the sheet and fail the next start.
    func tearDown() {
        slashCommandTask?.task.cancel()
        worktreeTask?.cancel()
        fileIndexTask?.task.cancel()
        let manager = voiceInputManager
        textBeforeRecording = nil
        let takeIdentity = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: voiceComposerGeneration
        )
        if let generation = voiceComposerGeneration {
            manager?.endComposer(generation: generation)
            voiceComposerGeneration = nil
        }
        Task {
            await ComposerShared.cancelVoiceInputOnDismiss(
                manager: manager,
                matching: takeIdentity
            )
        }
    }

    // MARK: Model and thinking

    func selectModel(_ model: ModelInfo) {
        let modelId = ModelSwitchPolicy.fullModelID(for: model)
        if selectedAgentId != nil {
            agentModelOverride = modelId
        } else {
            selectedModelId = modelId
        }
        AppPreferences.RecentModels.record(modelId)
    }

    /// The model picker's star: saves `model` as Pi's or the selected Agent's default.
    func saveModelAsDefault(_ model: ModelInfo) async throws {
        guard let api = selectedServerConnection()?.apiClient else {
            throw QuickSessionError.noConnection
        }
        let agentId = selectedAgentId
        try await ModelDefaultPersistence.save(model, agentId: agentId, api: api)
        if agentId == selectedAgentId {
            if let agentId {
                agentModelOverride = nil
                rememberAgentConfiguredModel(
                    agentId: agentId,
                    modelId: ModelSwitchPolicy.fullModelID(for: model)
                )
            } else {
                selectedModelId = nil
            }
        }
        if agentId == nil, let models = try? await api.listModels() {
            selectedChatState.cachedModels = models
        }
    }

    func selectThinkingLevel(_ level: ThinkingLevel) {
        if selectedAgentId != nil {
            agentThinkingOverride = level
        } else {
            thinkingLevel = level
            AppPreferences.QuickSession.saveThinkingLevel(level)
        }
    }

    // MARK: Agent

    func selectAgent(_ agentId: String?) {
        selectedAgentId = agentId
        // An explicit choice, including "no Agent", ends any hold on the launch.
        agentResolution = .resolved
        agentModelOverride = nil
        agentThinkingOverride = nil
        shouldRememberAgentSelection = true
        showAgentPicker = false
        error = nil
        launchFailure = nil
        AppPreferences.QuickSession.saveAgentId(agentId)
        requireExplicitCompatibleWorkspaceIfNeeded()
    }

    private func rememberAgentConfiguredModel(agentId: String, modelId: String) {
        guard let index = availableAgents.firstIndex(where: { $0.id == agentId }) else { return }
        var updated = availableAgents[index]
        let current = updated.sessionDefaults
        updated.sessionDefaults = AgentSessionDefaults(
            model: modelId,
            thinkingLevel: current?.thinkingLevel,
            tools: current?.tools,
            excludeTools: current?.excludeTools,
            noTools: current?.noTools
        )
        availableAgents[index] = updated
    }

    func requireExplicitCompatibleWorkspaceIfNeeded() {
        guard let constraints = effectiveLaunchConstraints else { return }
        if let selectedWorkspace, constraints.allows(selectedWorkspace) { return }
        if selectedWorkspaceSelectionSource == "inbox_workspace" {
            selectedAgentId = nil
            return
        }
        selectedWorkspace = nil
        selectedWorkspaceSelectionSource = "agent_constraint_required"
        resetWorktreeSelection()
        error = "Choose a workspace compatible with \(selectedAgent?.name ?? "this Agent")."
        showWorkspacePicker = true
        showWorktreePicker = false
    }

    // MARK: Workspace and worktree

    func selectWorkspace(_ workspace: Workspace, serverId: String) {
        let workspaceChanged = selectedWorkspace?.id != workspace.id || selectedServerId != serverId
        if selectedServerId != serverId {
            selectedAgentId = nil
            // The replacement Agent loads from the new server; hold the launch until it does.
            agentResolution = pendingAgentResolution(requestedAgentId: nil)
            agentModelOverride = nil
            agentThinkingOverride = nil
            shouldRememberAgentSelection = true
        }
        if threadParent?.serverId != serverId {
            threadParent = nil
        }
        selectedWorkspace = workspace
        selectedWorkspaceSelectionSource = "manual"
        selectedServerId = serverId
        if workspaceChanged {
            resetWorktreeSelection()
        }
        showWorkspacePicker = false
        showWorktreePicker = false
        error = nil
        launchFailure = nil
        configureVoiceInputForSelectedServer()
        AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
    }

    func selectWorktree(_ worktreeId: String) {
        selectedWorktreeId = worktreeId
        showWorktreePicker = false
    }

    private func resetWorktreeSelection() {
        selectedWorktreeId = WorkspaceWorktree.mainId
        worktrees = []
        isLoadingWorktrees = false
        worktreeLoadGeneration &+= 1
    }

    // MARK: Thread, engine, incognito

    /// Starts a standalone session instead of joining the thread.
    func clearThreadParent() {
        threadParent = nil
    }

    /// No change while the launch can only be Classic.
    func toggleEngine() {
        let decision = engineDecision
        guard decision.canToggle else { return }
        chosenEngine = decision.engine == .durable ? .classic : .durable
    }

    func toggleIncognito() {
        incognitoChosen.toggle()
    }

    // MARK: Voice

    func configureVoiceInputForSelectedServer(_ manager: VoiceInputManager? = nil) {
        guard let manager = manager ?? voiceInputManager else { return }
        guard let targetConnection = selectedServerConnection() else { return }
        let serverId = targetConnection.currentServerId
            ?? selectedServerId
            ?? targetConnection.credentials.map { "\($0.host):\($0.port)" }
            ?? ""
        voiceComposerGeneration = ComposerShared.prepareStandaloneVoiceInput(
            manager: manager,
            serverId: serverId,
            credentials: targetConnection.credentials,
            connection: targetConnection,
            playbackInterrupter: targetConnection.audioPlayer,
            workspaceId: selectedWorkspace?.id,
            ownedGeneration: voiceComposerGeneration
        )
    }
}

// MARK: - Urgency scoring (extracted for testability)

/// Urgency score for session sorting — higher = more urgent.
///
/// Priority order: asks (20) > error (15) > busy/starting/stopping (10) > ready (5) > stopped (0).
/// Used by session list surfaces to rank active sessions before recent ones.
func quickSessionUrgencyScore(
    status: SessionStatus,
    hasAsk: Bool
) -> Int {
    if hasAsk { return 20 }
    switch status {
    case .error: return 15
    case .busy, .starting, .stopping: return 10
    case .ready: return 5
    case .stopped: return 0
    }
}

/// Sort sessions by urgency (descending), then by last activity (descending).
///
/// Each session's urgency is determined by `quickSessionUrgencyScore`.
/// Callers provide closures to resolve ask state per session so sorting stays
/// decoupled from store types.
func quickSessionSorted(
    _ sessions: [Session],
    hasAsk: (String) -> Bool
) -> [Session] {
    sessions.sorted { lhs, rhs in
        let lhsScore = quickSessionUrgencyScore(
            status: lhs.status,
            hasAsk: hasAsk(lhs.id)
        )
        let rhsScore = quickSessionUrgencyScore(
            status: rhs.status,
            hasAsk: hasAsk(rhs.id)
        )
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.lastActivity > rhs.lastActivity
    }
}
