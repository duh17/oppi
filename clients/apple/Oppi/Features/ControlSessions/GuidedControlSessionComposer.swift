import SwiftUI

@MainActor
enum GuidedControlSessionInitialPrompt {
    struct PreparedPrompt: Equatable {
        let message: String
        let sentComments: [ReviewComment]

        var sentCommentIds: [String] { sentComments.map(\.id) }
    }

    static func make(
        domain: ControlSessionDomain,
        intent: ControlSessionIntent,
        targetId: String?,
        targetName: String?,
        targetPath: String?,
        workspaceId: String,
        workspaceName: String,
        userRequest: String,
        comments: ChatReviewCommentsController?
    ) -> PreparedPrompt {
        let completeRequest = comments?.appendReviewBlock(
            to: userRequest,
            pathFormatting: ChatView.reviewCommentPathFormattingPolicy(controlDomain: domain)
        ) ?? userRequest
        return PreparedPrompt(
            message: ControlSessionStarterPrompt.make(
                domain: domain,
                intent: intent,
                targetId: targetId,
                targetName: targetName,
                targetPath: targetPath,
                workspaceId: workspaceId,
                workspaceName: workspaceName,
                userRequest: completeRequest
            ),
            sentComments: comments?.stagedComments ?? []
        )
    }
}

@MainActor
struct GuidedControlSessionAtomicLaunch {
    let request: APIClient.CreateControlSessionRequest
    let sourceDraftText: String
    let initialPrompt: GuidedControlSessionInitialPrompt.PreparedPrompt

    static func make(
        domain: ControlSessionDomain,
        intent: ControlSessionIntent,
        targetId: String?,
        targetName: String?,
        targetPath: String?,
        workspaceId: String,
        workspaceName: String,
        sourceDraftText: String,
        cleanRequest: String,
        sessionName: String,
        model: String?,
        thinking: ThinkingLevel,
        requestId: String,
        comments: ChatReviewCommentsController?
    ) -> Self {
        let initialPrompt = GuidedControlSessionInitialPrompt.make(
            domain: domain,
            intent: intent,
            targetId: targetId,
            targetName: targetName,
            targetPath: targetPath,
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            userRequest: cleanRequest,
            comments: comments
        )
        return Self(
            request: .init(
                domain: domain,
                intent: intent,
                targetId: targetId,
                targetName: targetName,
                name: sessionName,
                model: model,
                thinking: thinking,
                prompt: initialPrompt.message,
                launchIdempotencyKey: requestId
            ),
            sourceDraftText: sourceDraftText,
            initialPrompt: initialPrompt
        )
    }

    func unchangedSentCommentIds(in currentComments: [ReviewComment]) -> [String] {
        initialPrompt.sentComments.compactMap { sentComment in
            currentComments.first(where: { $0.id == sentComment.id }) == sentComment
                ? sentComment.id
                : nil
        }
    }

    func shouldClearDraft(currentText: String) -> Bool {
        currentText == sourceDraftText
    }
}

@MainActor
enum GuidedControlSessionLaunchCoordinator {
    struct Completion {
        let session: Session
        let starterPromptDelivered: Bool
        let sessionTarget: WorkspaceSessionNavTarget
        let sentCommentIdsToDispose: [String]
        let shouldClearDraft: Bool
        let hasUnsentContentAfterDisposal: Bool
    }

    static func prepare(
        launch: GuidedControlSessionAtomicLaunch,
        existingSession: Session?,
        starterPromptDelivered: Bool,
        serverId: String?,
        fallbackServerId: String?,
        currentDraftText: String,
        currentComments: [ReviewComment],
        create: (APIClient.CreateControlSessionRequest) async throws -> (session: Session, prompted: Bool),
        onSessionCreated: (Session, Bool) -> Void
    ) async throws -> Completion {
        let prepared = try await ControlRevisionSessionLaunchCoordinator.prepare(
            existingSession: existingSession,
            starterPromptDelivered: starterPromptDelivered,
            create: { try await create(launch.request) },
            onSessionCreated: onSessionCreated
        )
        let target = try ControlRevisionCommentNavigation.makeAtomicLaunchSessionTarget(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            toSessionId: prepared.session.id
        )
        let sentCommentIdsToDispose = launch.unchangedSentCommentIds(in: currentComments)
        let sentCommentIdSet = Set(sentCommentIdsToDispose)
        let shouldClearDraft = launch.shouldClearDraft(currentText: currentDraftText)
        let hasRemainingComments = currentComments.contains { !sentCommentIdSet.contains($0.id) }
        return Completion(
            session: prepared.session,
            starterPromptDelivered: prepared.starterPromptDelivered,
            sessionTarget: target,
            sentCommentIdsToDispose: sentCommentIdsToDispose,
            shouldClearDraft: shouldClearDraft,
            hasUnsentContentAfterDisposal: !shouldClearDraft || hasRemainingComments
        )
    }
}

enum GuidedControlSessionComposerReviewComments {
    struct Presentation: Equatable {
        let pendingCount: Int
        let showsStash: Bool
        let title: String?
    }

    static func presentation(stagedCount: Int) -> Presentation {
        Presentation(
            pendingCount: stagedCount,
            showsStash: stagedCount > 0,
            title: stagedCount > 0
                ? ChatInputBar<EmptyView>.reviewCommentStashTitle(count: stagedCount)
                : nil
        )
    }
}

/// Quick Session-style intake for server-scoped Agent, Schedule, and Skill control sessions.
///
/// The selected workspace is prompt context only. Control sessions intentionally
/// remain workspace-less so the Oppi agent can inspect and mutate server-owned
/// definitions through its restricted `oppi` CLI tool.
struct GuidedControlSessionComposer: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ChatSessionState.self) private var chatState
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let domain: ControlSessionDomain
    let intent: ControlSessionIntent
    var targetId: String?
    var targetName: String?
    var targetPath: String?
    var initialRequest = ""
    var allowsEmptyRequest = false
    var placeholder: String
    var stagedComments: ChatReviewCommentsController?
    var onSessionPrepared: ((WorkspaceSessionNavTarget) -> Void)?

    @State private var request = ""
    @State private var textBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pendingRepoPointers: [PendingFileReference] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedModelId: String?
    @State private var thinkingLevel: ThinkingLevel = AppPreferences.QuickSession.lastThinkingLevel
    @State private var voiceInputManager: VoiceInputManager?
    @State private var streamingBehavior: StreamingBehavior = .followUp
    @State private var showModelPicker = false
    @State private var isInitialized = false
    @State private var isCreating = false
    @State private var revisionLaunchState = ControlRevisionSessionRetryState()
    @State private var showReviewCommentStash = false
    @State private var error: String?

    private var reviewCommentPresentation: GuidedControlSessionComposerReviewComments.Presentation {
        GuidedControlSessionComposerReviewComments.presentation(
            stagedCount: stagedComments?.stagedCount ?? 0
        )
    }

    private var modelPresentation: NewSessionModelPresentation {
        NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: selectedModelId,
            isAgent: false,
            catalogModels: chatState.cachedModels
        )
    }

    private var effectiveModelId: String? {
        modelPresentation.requestModelId
    }

    private var isAvailable: Bool {
        apiClient != nil && connection.controlSessionsAvailable && selectedWorkspace != nil
    }

    private var stacksControls: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("\(identifierPrefix).error")
            }

            ChatInputBar(
                text: $request,
                textBeforeRecording: $textBeforeRecording,
                pendingAttachments: $pendingAttachments,
                pendingRepoPointers: $pendingRepoPointers,
                isBusy: false,
                busyStreamingBehavior: $streamingBehavior,
                isSending: isCreating,
                pendingReviewCommentCount: reviewCommentPresentation.pendingCount,
                onReviewCommentsTap: { showReviewCommentStash = true },
                placeholderOverride: resolvedPlaceholder,
                allowsEmptySubmit: allowsEmptyRequest,
                sendProgressText: nil,
                isStopping: false,
                voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                onPrepareVoiceInput: prepareVoiceInput,
                showForceStop: false,
                isForceStopInFlight: false,
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                onSend: { Task { await createControlSession() } },
                onStop: {},
                onForceStop: {},
                onExpand: {},
                externalFocusRequestID: 0,
                appliesOuterPadding: true,
                alwaysShowActionRow: !stacksControls,
                allowsExpansion: false,
                allowsAttachments: false,
                showsAccessoryRow: !stacksControls,
                actionRow: {
                    if !stacksControls {
                        composerControls
                    }
                }
            )
            .disabled(!isAvailable || !isInitialized)

            if stacksControls {
                VStack(alignment: .leading, spacing: 6) {
                    workspacePicker
                    HStack(spacing: 6) {
                        sessionToolbar
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(currentModel: effectiveModelId, onSelect: selectModel)
        }
        .sheet(isPresented: $showReviewCommentStash) {
            if let stagedComments {
                ReviewCommentStashSheet(
                    comments: stagedComments.stagedComments,
                    focusedCommentId: nil,
                    onEdit: { comment, body in
                        if let updateError = stagedComments.update(comment, body: body) {
                            error = updateError
                            return false
                        }
                        return true
                    },
                    onDelete: { stagedComments.delete($0) },
                    onClose: { showReviewCommentStash = false }
                )
            }
        }
        .task { await initialize() }
    }

    @ViewBuilder
    private var composerControls: some View {
        workspacePicker
        sessionToolbar
    }

    private var sessionToolbar: some View {
        SessionToolbar(
            session: nil,
            modelOverride: effectiveModelId ?? modelPresentation.pillText,
            thinkingLevel: thinkingLevel,
            supportedThinkingLevels: ThinkingLevelMenuSource.levels(
                for: effectiveModelId,
                in: chatState.cachedModels
            ),
            onModelTap: { showModelPicker = true },
            onThinkingSelect: selectThinkingLevel
        )
    }

    private var workspacePicker: some View {
        Menu {
            ForEach(workspaceStore.workspaces) { workspace in
                Button {
                    selectWorkspace(workspace)
                } label: {
                    Label {
                        Text(workspace.name)
                    } icon: {
                        if workspace.id == selectedWorkspace?.id {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: "folder")
                        }
                    }
                }
                .accessibilityIdentifier("\(identifierPrefix).workspace.\(workspace.id)")
            }
        } label: {
            SessionWorkspacePillLabel(workspace: selectedWorkspace)
        }
        .accessibilityLabel(selectedWorkspace.map { "Workspace picker, current workspace \($0.name)" } ?? "Workspace picker")
        .accessibilityIdentifier("\(identifierPrefix).workspacePicker")
    }

    private var resolvedPlaceholder: String {
        guard apiClient != nil, connection.controlSessionsAvailable else {
            return "Connect to use guided \(domainTitle.lowercased()) setup"
        }
        guard selectedWorkspace != nil else { return "Choose a workspace first" }
        return placeholder
    }

    private var identifierPrefix: String {
        "guided.\(domain.rawValue).\(intent.rawValue)"
    }

    private var domainTitle: String {
        switch domain {
        case .agents: "Agent"
        case .schedules: "Schedule"
        case .skills: "Skill"
        case .workspaces: "Workspace"
        }
    }

    private func selectWorkspace(_ workspace: Workspace) {
        selectedWorkspace = workspace
        AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
        error = nil
    }

    private func selectModel(_ model: ModelInfo) {
        let modelId = ModelSwitchPolicy.fullModelID(for: model)
        selectedModelId = modelId
        AppPreferences.RecentModels.record(modelId)
    }

    private func selectThinkingLevel(_ level: ThinkingLevel) {
        thinkingLevel = level
        AppPreferences.QuickSession.saveThinkingLevel(level)
    }

    @MainActor
    private func initialize() async {
        guard !isInitialized else { return }
        request = initialRequest

        let workspaces = workspaceStore.workspaces
        if let preferred = AppPreferences.QuickSession.preferredWorkspaceSelection(
            in: workspaces.map { (id: $0.id, name: $0.name) }
        ) {
            selectedWorkspace = workspaces.first(where: { $0.id == preferred.id })
        }
        if selectedWorkspace == nil {
            selectedWorkspace = workspaces.first
        }

        if ReleaseFeatures.voiceInputEnabled {
            let manager = VoiceInputManager()
            configureVoiceInput(manager)
            voiceInputManager = manager
        }

        if let apiClient {
            await chatState.refreshModelCache(api: apiClient)
        }
        isInitialized = true
    }

    private func configureVoiceInput(_ manager: VoiceInputManager) {
        manager.setServerCredentials(connection.credentials)
        manager.setServerConnection(connection)
        manager.setPlaybackInterrupter(connection.audioPlayer)
    }

    private func prepareVoiceInput(_ manager: VoiceInputManager) async throws {
        configureVoiceInput(manager)
        manager.setServerDictationTarget(nil)
    }

    @MainActor
    private func createControlSession() async {
        guard let apiClient, let selectedWorkspace, !isCreating else { return }
        let cleanRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsEmptyRequest || !cleanRequest.isEmpty else { return }

        isCreating = true
        defer { isCreating = false }

        do {
            let candidateLaunch = GuidedControlSessionAtomicLaunch.make(
                domain: domain,
                intent: intent,
                targetId: targetId,
                targetName: targetName,
                targetPath: targetPath,
                workspaceId: selectedWorkspace.id,
                workspaceName: selectedWorkspace.name,
                sourceDraftText: request,
                cleanRequest: cleanRequest,
                sessionName: sessionName(request: cleanRequest),
                model: effectiveModelId,
                thinking: thinkingLevel,
                requestId: revisionLaunchState.requestId,
                comments: stagedComments
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
                currentComments: stagedComments?.stagedComments ?? [],
                create: { request in
                    let response = try await apiClient.createControlSession(request)
                    return (
                        response.session,
                        response.prompted ?? (response.session.firstMessage != nil)
                    )
                },
                onSessionCreated: { session, delivered in
                    revisionLaunchState.recordCreatedSession(session, promptDelivered: delivered)
                    sessionStore.cacheSessionForNavigation(session)
                }
            )
            revisionLaunchState.starterPromptDelivered = completion.starterPromptDelivered
            stagedComments?.clearSent(ids: completion.sentCommentIdsToDispose)
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
            self.error = targetId == nil
                ? error.localizedDescription
                : "\(error.localizedDescription) Your staged comments are still saved."
        }
    }

    private func sessionName(request: String) -> String {
        if intent == .revise {
            return "Revise \(targetName ?? domainTitle)"
        }
        let fallback = "Create \(domainTitle)"
        guard !request.isEmpty else { return fallback }
        return "\(domainTitle): \(String(request.prefix(48)))"
    }
}

struct GuidedControlSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation

    let domain: ControlSessionDomain
    let intent: ControlSessionIntent
    var targetId: String?
    var targetName: String?
    var targetPath: String?
    var initialRequest = ""
    var allowsEmptyRequest = true
    var placeholder: String
    var stagedComments: ChatReviewCommentsController?
    var onSessionPrepared: ((WorkspaceSessionNavTarget) -> Void)?

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: domainSystemImage,
                description: Text("Describe the outcome you want. Oppi will inspect the current definition and clarify anything ambiguous before changing it.")
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .themedListSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GuidedControlSessionComposer(
                    domain: domain,
                    intent: intent,
                    targetId: targetId,
                    targetName: targetName,
                    targetPath: targetPath,
                    initialRequest: initialRequest,
                    allowsEmptyRequest: allowsEmptyRequest,
                    placeholder: placeholder,
                    stagedComments: stagedComments,
                    onSessionPrepared: { target in
                        if let onSessionPrepared {
                            onSessionPrepared(target)
                        } else {
                            dismiss()
                            Task { @MainActor in
                                await Task.yield()
                                navigation.openWorkspaceSession(target)
                            }
                        }
                    }
                )
            }
        }
    }

    private var domainSystemImage: String {
        switch domain {
        case .agents: "person.crop.circle.badge.questionmark"
        case .schedules: "calendar.badge.clock"
        case .skills: "hammer"
        case .workspaces: "folder.badge.gearshape"
        }
    }

    private var title: String {
        let fallbackSubject = switch domain {
        case .agents: "Agent"
        case .schedules: "Schedule"
        case .skills: "Skill"
        case .workspaces: "Workspace"
        }
        let subject = targetName ?? fallbackSubject
        return intent == .create ? "Create \(subject)" : "Revise \(subject)"
    }
}

struct SessionWorkspacePillLabel: View {
    let workspace: Workspace?

    var body: some View {
        HStack(spacing: 4) {
            if let workspace {
                WorkspaceRuntimeIcon(workspace: workspace, size: 12, frameSize: 16)
            } else {
                Image(systemName: "folder")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeBlue)
                    .frame(width: 16, height: 16)
            }
            Text(workspace?.name ?? "Workspace")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.themeComment)
        }
        .frame(minHeight: 17)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: Capsule())
        .frame(minHeight: ComposerInputMetrics.controlDiameter)
        .contentShape(Rectangle())
    }
}
