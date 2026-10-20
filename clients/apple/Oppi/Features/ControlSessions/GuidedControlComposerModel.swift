import UIKit

/// What a screen asks of its guided control-session composer: the definition
/// it creates or revises, the starting request, and staged review comments.
struct GuidedControlComposerConfiguration {
    let domain: ControlSessionDomain
    let intent: ControlSessionIntent
    var targetId: String?
    var targetName: String?
    var targetPath: String?
    var initialRequest = ""
    var allowsEmptyRequest = false
    var placeholder: String
    var stagedComments: ChatReviewCommentsController?
}

/// The guided control-session composer's state and actions: Quick Session-style
/// intake for server-scoped Agent, Schedule, Skill, Theme, Extension, and
/// Workspace control sessions. `GuidedControlComposerController` draws it on
/// the chat's composer owner.
///
/// The selected workspace is prompt context only. Control sessions stay
/// workspace-less so Pi can inspect and change server-owned definitions with
/// ordinary host tools, including `bash` and the installed `oppi` CLI.
@MainActor @Observable
final class GuidedControlComposerModel {
    let configuration: GuidedControlComposerConfiguration
    /// The server the session starts on. Screens pass the active server (read
    /// each time, so a server switch follows); sheets opened for one server
    /// (a chat's extension, a Skill file) pass that server.
    @ObservationIgnored private let serverConnection: @MainActor () -> ServerConnection
    @ObservationIgnored private let navigation: AppNavigation
    /// Where a prepared session goes; nil opens it in the app's navigation.
    @ObservationIgnored var onSessionPrepared: ((WorkspaceSessionNavTarget) -> Void)?

    var request = ""
    var textBeforeRecording: String?
    var streamingBehavior: StreamingBehavior = .followUp
    private(set) var selectedWorkspace: Workspace?
    private(set) var selectedModelId: String?
    private(set) var thinkingLevel: ThinkingLevel = AppPreferences.QuickSession.lastThinkingLevel
    private(set) var voiceInputManager: VoiceInputManager?
    private(set) var isInitialized = false
    private(set) var isCreating = false
    var error: String?
    var showModelPicker = false
    var reviewCommentDrawerExpanded = false
    var reviewCommentStashPresentation: ReviewCommentStripChrome.StashPresentation?

    @ObservationIgnored private var voiceComposerGeneration: Int?
    @ObservationIgnored private var revisionLaunchState = ControlRevisionSessionRetryState()
    @ObservationIgnored private var initializeTask: Task<Void, Never>?

    init(
        configuration: GuidedControlComposerConfiguration,
        connection: @escaping @MainActor () -> ServerConnection,
        navigation: AppNavigation
    ) {
        self.configuration = configuration
        serverConnection = connection
        self.navigation = navigation
    }

    var connection: ServerConnection { serverConnection() }

    var identifierPrefix: String {
        "guided.\(configuration.domain.rawValue).\(configuration.intent.rawValue)"
    }

    var workspaces: [Workspace] { connection.workspaceStore.workspaces }

    var reviewCommentPresentation: GuidedControlSessionComposerReviewComments.Presentation {
        GuidedControlSessionComposerReviewComments.presentation(
            stagedCount: configuration.stagedComments?.stagedCount ?? 0
        )
    }

    var modelPresentation: NewSessionModelPresentation {
        NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: selectedModelId,
            isAgent: false,
            catalogModels: connection.chatState.cachedModels
        )
    }

    var effectiveModelId: String? { modelPresentation.requestModelId }

    var supportedThinkingLevels: [ThinkingLevel] {
        ThinkingLevelMenuSource.levels(for: effectiveModelId, in: connection.chatState.cachedModels)
    }

    /// The composer takes input once it is set up and has a server and a workspace.
    var acceptsInput: Bool {
        isInitialized && connection.apiClient != nil && selectedWorkspace != nil
    }

    var placeholder: String {
        guard connection.apiClient != nil else {
            return "Connect to use guided \(configuration.domain.title.lowercased()) setup"
        }
        guard selectedWorkspace != nil else { return "Choose a workspace first" }
        return configuration.placeholder
    }

    // MARK: - Choices

    func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspace = workspace
        AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
        error = nil
    }

    func selectModel(_ model: ModelInfo) {
        let modelId = ModelSwitchPolicy.fullModelID(for: model)
        selectedModelId = modelId
        AppPreferences.RecentModels.record(modelId)
    }

    func selectThinkingLevel(_ level: ThinkingLevel) {
        thinkingLevel = level
        AppPreferences.QuickSession.saveThinkingLevel(level)
    }

    // MARK: - Review comments

    /// The staged-comment pill and drawer go when the last comment does.
    func reconcileReviewCommentDrawer() {
        if !reviewCommentPresentation.showsPill, reviewCommentDrawerExpanded {
            reviewCommentDrawerExpanded = false
        }
    }

    func toggleReviewCommentDrawer() {
        reviewCommentDrawerExpanded.toggle()
        if reviewCommentDrawerExpanded { Self.dismissKeyboard() }
    }

    func presentReviewCommentStash(editing comment: ReviewComment? = nil) {
        reviewCommentDrawerExpanded = false
        reviewCommentStashPresentation = ReviewCommentStripChrome.StashPresentation(editing: comment)
        Self.dismissKeyboard()
    }

    private static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - Lifecycle

    /// The composer came on screen: set it up once (draft, workspace, the
    /// microphone, the model catalog).
    func appear() {
        guard !isInitialized, initializeTask == nil else { return }
        initializeTask = Task { [weak self] in
            await self?.initialize()
            // `disappear()` already dropped a cancelled task's handle; the
            // field may hold the newer task that replaced it.
            guard !Task.isCancelled else { return }
            self?.initializeTask = nil
        }
    }

    /// The composer left the screen: stop setting up and hand the microphone
    /// back, cancelling a take this composer started.
    func disappear() {
        initializeTask?.cancel()
        initializeTask = nil
        let manager = voiceInputManager
        let takeIdentity = ComposerShared.takeIdentityForDismissedComposer(
            manager: manager,
            generation: voiceComposerGeneration
        )
        if let generation = voiceComposerGeneration {
            manager?.endComposer(generation: generation)
            voiceComposerGeneration = nil
        }
        Task {
            await ComposerShared.cancelVoiceInputOnDismiss(manager: manager, matching: takeIdentity)
        }
    }

    private func initialize() async {
        request = configuration.initialRequest

        let workspaces = workspaces
        if let preferred = AppPreferences.QuickSession.preferredWorkspaceSelection(
            in: workspaces.map { (id: $0.id, name: $0.name) }
        ) {
            selectedWorkspace = workspaces.first(where: { $0.id == preferred.id })
        }
        if selectedWorkspace == nil {
            selectedWorkspace = workspaces.first
        }

        let manager = VoiceInputManager.shared
        await ComposerShared.cancelVoiceInputOnDismiss(manager: manager)
        if Task.isCancelled { return }
        configureVoiceInput(manager)
        voiceInputManager = manager

        if let apiClient = connection.apiClient {
            await connection.chatState.refreshModelCache(api: apiClient)
        }
        isInitialized = true
    }

    func configureVoiceInput(_ manager: VoiceInputManager) {
        let connection = connection
        let serverId = connection.currentServerId
            ?? connection.credentials.map { "\($0.host):\($0.port)" }
            ?? ""
        voiceComposerGeneration = ComposerShared.prepareStandaloneVoiceInput(
            manager: manager,
            serverId: serverId,
            credentials: connection.credentials,
            connection: connection,
            playbackInterrupter: connection.audioPlayer,
            ownedGeneration: voiceComposerGeneration
        )
    }

    // MARK: - Launch

    func send() {
        Task { await createControlSession() }
    }

    private func createControlSession() async {
        let connection = connection
        guard let apiClient = connection.apiClient, let selectedWorkspace, !isCreating else { return }
        let cleanRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.allowsEmptyRequest || !cleanRequest.isEmpty else { return }

        isCreating = true
        defer { isCreating = false }

        let sessionStore = connection.sessionStore
        let comments = configuration.stagedComments
        do {
            let candidateLaunch = GuidedControlSessionAtomicLaunch.make(
                domain: configuration.domain,
                intent: configuration.intent,
                targetId: configuration.targetId,
                targetName: configuration.targetName,
                targetPath: configuration.targetPath,
                workspaceId: selectedWorkspace.id,
                workspaceName: selectedWorkspace.name,
                sourceDraftText: request,
                cleanRequest: cleanRequest,
                sessionName: sessionName(request: cleanRequest),
                model: effectiveModelId,
                thinking: thinkingLevel,
                requestId: revisionLaunchState.requestId,
                comments: comments
            )
            // Freeze every POST field and the exact comment snapshots before
            // the first network attempt. A lost response cannot bind revised
            // draft content to the old idempotency key.
            let launch = revisionLaunchState.freeze(candidateLaunch)
            let completion = try await GuidedControlSessionLaunchCoordinator.prepare(
                launch: launch,
                existingSession: revisionLaunchState.createdSession,
                starterPromptDelivered: revisionLaunchState.starterPromptDelivered,
                serverId: connection.currentServerId,
                fallbackServerId: sessionStore.activeServerId,
                currentDraftText: request,
                currentComments: comments?.stagedComments ?? [],
                create: { request in
                    let response = try await apiClient.createControlSession(request)
                    return (
                        response.session,
                        response.prompted ?? (response.session.firstMessage != nil)
                    )
                },
                onSessionCreated: { [weak self] session, delivered in
                    self?.revisionLaunchState.recordCreatedSession(session, promptDelivered: delivered)
                    sessionStore.cacheSessionForNavigation(session)
                }
            )
            revisionLaunchState.starterPromptDelivered = completion.starterPromptDelivered
            comments?.clearSent(ids: completion.sentCommentIdsToDispose)
            sessionStore.cacheSessionForNavigation(completion.session)

            if completion.shouldClearDraft {
                request = ""
            }
            revisionLaunchState.resetForNextLaunch()
            if completion.hasUnsentContentAfterDisposal {
                error = "Your earlier request was delivered. Revised text or comments are still ready to send."
                return
            }

            error = nil
            if let onSessionPrepared {
                onSessionPrepared(completion.sessionTarget)
            } else {
                navigation.openWorkspaceSession(completion.sessionTarget)
            }
        } catch {
            self.error = configuration.targetId == nil
                ? error.localizedDescription
                : "\(error.localizedDescription) Your staged comments are still saved."
        }
    }

    private func sessionName(request: String) -> String {
        let title = configuration.domain.title
        if configuration.intent == .revise {
            return "Revise \(configuration.targetName ?? title)"
        }
        let fallback = "Create \(title)"
        guard !request.isEmpty else { return fallback }
        return "\(title): \(String(request.prefix(48)))"
    }
}
