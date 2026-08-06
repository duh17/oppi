import SwiftUI
import UIKit

struct TreeNavigationViewUpdate: Equatable {
    let scrollTargetID: String
    let inputText: String
    let shouldFocusComposer: Bool

    static func from(targetId: String, editorText: String?, showComposer: Bool) -> Self {
        let normalized = editorText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return TreeNavigationViewUpdate(
            scrollTargetID: targetId,
            inputText: normalized,
            shouldFocusComposer: !normalized.isEmpty && !showComposer
        )
    }
}

struct ExtensionSurfaceSessionLink: Equatable {
    let sessionId: String
    let workspaceId: String?

    static func parse(_ url: URL, defaultWorkspaceId: String? = nil) -> ExtensionSurfaceSessionLink? {
        guard url.scheme?.lowercased() == "oppi",
              url.host?.lowercased() == "session",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let pathParts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let rawId = pathParts.first, !rawId.isEmpty else {
            return nil
        }

        let sessionId = rawId.removingPercentEncoding ?? rawId
        guard !sessionId.isEmpty else { return nil }

        let queryWorkspaceId = components.queryItems?.first { $0.name == "workspaceId" }?.value
        let workspaceId = normalized(queryWorkspaceId) ?? normalized(defaultWorkspaceId)
        return ExtensionSurfaceSessionLink(sessionId: sessionId, workspaceId: workspaceId)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct ChatView: View {
    enum LocalSlashCommand: Equatable {
        case compact
    }

    let sessionId: String
    private let workspaceIdHint: String?
    private let routeScope: SessionRouteScope?
    private let ownsWorkspacePathBackNavigation: Bool

    @Environment(ServerConnection.self) private var connection
    @Environment(ChatSessionState.self) private var chatState
    @Environment(AskRequestStore.self) private var askRequestStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayerService.self) private var audioPlayer
    @Environment(GitStatusStore.self) private var gitStatusStore
    @Environment(FileIndexStore.self) private var fileIndexStore
    @Environment(MessageQueueStore.self) private var messageQueueStore
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(QuickCommentTemplateStore.self) private var quickCommentTemplateStore
    @Environment(\.composerDraftStore) private var composerDraftStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    @State private var sessionManager: ChatSessionManager
    @State private var scrollController = ChatScrollController()
    @State private var actionHandler = ChatActionHandler()
    @State private var voiceInputManager = VoiceInputManager()
    @State private var audioLifecycleCoordinator = AudioLifecycleCoordinator()
    @State private var composerDraftController: ChatComposerDraftController

    @State private var composerTextBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
#if DEBUG
    @State private var hasSeededE2EChatImageAttachment = false
#endif
    @State private var busyStreamingBehavior: StreamingBehavior = .steer
    @State private var messageQueueEditorState = MessageQueueEditorState(queue: .empty)
    @State private var isPreparingAttachments = false
    @State private var attachmentPreparationText: String?

    @State private var showOutline = false
    @State private var isFilePanelVisible = false
    @State private var selectedFilePanelTab: ChatFileBrowserPanelTab
    @State private var showModelPicker = false
    @State private var showComposer = false
    @State private var sessionRouteToOpen: SessionRoute?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var forkedSessionToOpen: ForkRoute?
    @State private var showShareRedactionSheet = false
    @State private var shareRedactionPolicy = AppPreferences.Share.redactionPolicy
    @State private var sharePreflightResult: ShareSessionPrepareResult?
    @State private var sharePreflightError: String?
    @State private var isSharePreflightRunning = false
    @State private var sharePreflightTask: Task<Void, Never>?

    @State private var showContextInspector = false
    @State private var isKeyboardVisible = false
    @State private var footerHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var composerExternalFocusRequestID = 0
    @State private var contextBarCollapseToken = 0
    @State private var contextBarExpanded = false
    @State private var reviewComments = ChatReviewCommentsController()
    @State private var activeReviewCommentRequest: ReviewCommentSelectionRequest?
    @State private var showReviewCommentStash = false
    @State private var focusedReviewCommentId: String?

    init(
        sessionId: String,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil,
        initialInputText: String = "",
        initialPendingFiles: [PendingFileReference] = [],
        ownsWorkspacePathBackNavigation: Bool = false
    ) {
        self.sessionId = sessionId
        self.workspaceIdHint = workspaceIdHint
        self.routeScope = routeScope
            ?? workspaceIdHint.map(SessionRouteScope.workspace)
        self.ownsWorkspacePathBackNavigation = ownsWorkspacePathBackNavigation
        _sessionManager = State(initialValue: ChatSessionManager(
            sessionId: sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: self.routeScope
        ))
        _composerDraftController = State(initialValue: ChatComposerDraftController(
            initialText: initialInputText,
            initialRepoPointers: initialPendingFiles
        ))
        _selectedFilePanelTab = State(initialValue: ChatFileBrowserPanelTabStore.shared.tab(for: sessionId))
    }

    private struct ForkRoute: Identifiable, Hashable {
        let id: String
        let workspaceId: String?
    }

    private struct SessionRoute: Identifiable, Hashable {
        let id: String
        let workspaceId: String?
    }

    private struct ComposerDraftAttachmentKey: Equatable {
        let key: ComposerDraftKey?
        let isEphemeral: Bool
    }

    private enum TreeNavigationError: LocalizedError {
        case sessionNotReady
        case navigationCancelled
        case navigationAborted
        case historyReloadFailed

        var errorDescription: String? {
            switch self {
            case .sessionNotReady:
                return "Wait for the current turn to finish before navigating the tree."
            case .navigationCancelled:
                return "Tree navigation was cancelled before switching branches."
            case .navigationAborted:
                return "Tree navigation was aborted before switching branches."
            case .historyReloadFailed:
                return "Switched branches, but failed to reload timeline history."
            }
        }
    }

    /// Composite key for the session connection `.task(id:)`.
    ///
    /// Includes both `sessionId` and `connectionGeneration` so the task
    /// re-fires when either changes:
    /// - sessionId changes → view reused for a different session
    /// - generation changes → reconnect after network drop
    ///
    /// Without sessionId, two consecutive managers both start at
    /// generation 0 and the task silently skips the new session.
    private var connectionTaskKey: ConnectionTaskKey {
        ConnectionTaskKey(sessionId: sessionId, generation: sessionManager.connectionGeneration)
    }

    /// Per-session reducer, owned by sessionManager.
    private var reducer: TimelineReducer { sessionManager.reducer }

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var workspace: Workspace? {
        guard let workspaceId = session?.workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == workspaceId }
    }

    private var assistantIdentityPresentation: AssistantIdentityPresentation {
        AssistantIdentityPresentation.resolve(
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon
        )
    }

    private var timelineWorkspaceId: String? {
        let sessionWorkspaceId = session?.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sessionWorkspaceId, !sessionWorkspaceId.isEmpty {
            return sessionWorkspaceId
        }
        let fallback = workspaceIdHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }

    private var focusedRouteScope: SessionRouteScope? {
        if session?.control != nil { return .control }
        if let timelineWorkspaceId { return .workspace(timelineWorkspaceId) }
        return routeScope
    }

    private var reviewCommentLocalScopeId: String? {
        Self.reviewCommentLocalScopeId(routeScope: focusedRouteScope)
    }

    static func reviewCommentLocalScopeId(routeScope: SessionRouteScope?) -> String? {
        switch routeScope {
        case .control:
            return SessionRouteScope.control.composerDraftScopeID
        case .workspace(let workspaceId):
            return workspaceId
        case nil:
            return nil
        }
    }

    private var composerDraftKey: ComposerDraftKey? {
        guard let serverID = connection.currentServerId ?? sessionStore.activeServerId,
              let workspaceID = focusedRouteScope?.composerDraftScopeID else {
            return nil
        }
        return ComposerDraftKey(
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionId
        )
    }

    private var composerDraftAttachmentKey: ComposerDraftAttachmentKey {
        ComposerDraftAttachmentKey(
            key: composerDraftKey,
            isEphemeral: composerDraftIsMemoryOnly
        )
    }

    /// Unknown session metadata stays memory-only until the session record confirms
    /// that local persistence is allowed. This avoids briefly writing incognito text.
    private var composerDraftIsMemoryOnly: Bool {
        Self.composerDraftIsMemoryOnly(
            hasSessionMetadata: session != nil,
            isEphemeral: session?.ephemeral
        )
    }

    static func composerDraftIsMemoryOnly(
        hasSessionMetadata: Bool,
        isEphemeral: Bool?
    ) -> Bool {
        !hasSessionMetadata || isEphemeral == true
    }

    static func resolvedComposerMode(
        hasReviewComment: Bool,
        hasAskRequest: Bool
    ) -> ChatComposerDraftController.Mode {
        if hasReviewComment { return .reviewComment }
        if hasAskRequest { return .ask }
        return .message
    }

    static func resolvedComposerAskRequest(
        _ askRequest: AskRequest?,
        hasReviewComment: Bool
    ) -> AskRequest? {
        hasReviewComment ? nil : askRequest
    }

    static func localSlashCommand(for text: String) -> LocalSlashCommand? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.caseInsensitiveCompare("/compact") == .orderedSame ? .compact : nil
    }

    static func availableSlashCommands(from serverCommands: [SlashCommand]) -> [SlashCommand] {
        guard !serverCommands.contains(where: {
            $0.name.caseInsensitiveCompare("compact") == .orderedSame
        }) else {
            return serverCommands
        }

        return serverCommands + [SlashCommand(
            name: "compact",
            description: "Compact context",
            source: .builtin
        )]
    }

    private var composerTextBinding: Binding<String> {
        Binding(
            get: { composerDraftController.text },
            set: { composerDraftController.text = $0 }
        )
    }

    private var composerRepoPointersBinding: Binding<[PendingFileReference]> {
        Binding(
            get: { composerDraftController.repoPointers },
            set: { composerDraftController.repoPointers = $0 }
        )
    }

    private var availableSlashCommands: [SlashCommand] {
        Self.availableSlashCommands(from: chatState.slashCommands)
    }

    private var hasShareSlashCommand: Bool {
        chatState.slashCommands.contains { command in
            command.name.caseInsensitiveCompare("share") == .orderedSame
        }
    }

    private var sessionDisplayName: String {
        session?.displayTitle ?? "Session \(String(sessionId.prefix(8)))"
    }

    private var isBusy: Bool {
        session?.status == .busy || session?.status == .stopping
    }

    private var isStopping: Bool {
        actionHandler.isStopping || session?.status == .stopping
    }

    private var isStopped: Bool {
        session?.status == .stopped
    }

    private var messageQueueState: MessageQueueState {
        messageQueueStore.queue(for: sessionId)
    }

    private var showsMessageQueue: Bool {
        !messageQueueState.steering.isEmpty || !messageQueueState.followUp.isEmpty
    }

    private var hasMessageQueueDraft: Bool {
        messageQueueEditorState.isDraftMode || messageQueueEditorState.hasStashedDraft
    }

    private var messageQueueSurfaceConfiguration: MessageQueueSurfaceConfiguration {
        MessageQueueSurfaceConfiguration(
            queue: messageQueueState,
            busyStreamingBehavior: $busyStreamingBehavior,
            editorState: $messageQueueEditorState,
            onApply: { baseVersion, steering, followUp in
                try await connection.setMessageQueue(
                    baseVersion: baseVersion,
                    steering: steering,
                    followUp: followUp,
                    sessionIdOverride: sessionId
                )
            },
            onRefresh: {
                try? await connection.requestMessageQueue(sessionIdOverride: sessionId)
            }
        )
    }

    private var extensionSurfaceState: ExtensionSurfaceState? {
        connection.extensionSurfaceBySession[sessionId]
    }

    private var activeComposerAskRequest: AskRequest? {
        askRequestStore.pending(for: sessionId)
    }

    private var composerAskRequest: AskRequest? {
        Self.resolvedComposerAskRequest(
            activeComposerAskRequest,
            hasReviewComment: activeReviewCommentRequest != nil
        )
    }

    private var hasBlockingExtensionInput: Bool {
        activeComposerAskRequest != nil || connection.hasPendingExtensionDialog(for: sessionId)
    }

    /// Show toolbar when composing (keyboard up) or at bottom of chat.
    /// Hide when scrolled up to read history.

    private var contextUsageSnapshot: ContextUsageSnapshot {
        let fallbackWindow: Int?
        if let model = session?.model {
            fallbackWindow = inferContextWindow(from: model)
        } else {
            fallbackWindow = nil
        }

        return ContextUsageSnapshot(
            tokens: session?.contextTokens,
            window: session?.contextWindow ?? fallbackWindow
        )
    }

    var body: some View {
        chatContent
            .environment(sessionManager.reducer)
            .environment(sessionManager.reducer.toolOutputStore)
            .environment(sessionManager.reducer.toolArgsStore)
    }

    private var chatTimeline: some View {
        ChatTimelineView(
            sessionId: sessionId,
            workspaceId: timelineWorkspaceId,
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon,
            routeScope: focusedRouteScope,
            isBusy: isBusy,
            extensionWorkingState: extensionSurfaceState?.working,
            extensionHiddenThinkingLabel: extensionSurfaceState?.hiddenThinkingLabel,
            currentModel: session?.model,
            connection: connection,
            scrollController: scrollController,
            sessionManager: sessionManager,
            audioLifecycleCoordinator: audioLifecycleCoordinator,
            onFork: forkFromMessage,
            onBackSwipe: navigateBackFromChat,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            topOverlap: headerHeight,
            bottomOverlap: footerHeight
        )
    }

    private var chatTimelineScaffold: some View {
        chatTimeline
            .ignoresSafeArea(.container, edges: .top)
            .overlay {
                // Dismiss scrim: dims the timeline so content doesn't
                // bleed through the context bar's glass effect, and
                // collapses the bar on tap. Using a semi-opaque fill
                // instead of Color.clear prevents the visual overlap
                // between expanded bar content and the timeline behind.
                if contextBarExpanded {
                    Color.themeDimScrim
                        .ignoresSafeArea()
                        .onTapGesture { contextBarCollapseToken &+= 1 }
                }
            }
            .overlay(alignment: .top) {
                WorkspaceContextBar(
                    gitStatus: gitStatusStore.gitStatus,
                    isLoading: gitStatusStore.isLoading,
                    workspaceId: session?.workspaceId,
                    sessionId: sessionId,
                    worktreeId: session?.worktreeId,
                    onReviewInCurrentSession: { prompt, files in
                        stageWorkspaceReviewInCurrentSession(prompt: prompt, files: files)
                    },
                    fileDetailReviewCommentScope: .activeSession(reviewCommentSelectionRouter),
                    collapseToken: contextBarCollapseToken,
                    onExpandedChanged: handleContextBarExpandedChanged
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                footerArea
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
            .overlay(alignment: .bottomTrailing) {
                if scrollController.isJumpToBottomHintVisible {
                    JumpToBottomHintButton(
                        isBusy: isBusy,
                        modelId: session?.model,
                        onTap: { scrollController.requestScrollToBottom() }
                    )
                    .padding(.trailing, 27)
                    .padding(.bottom, footerHeight + 10)
                    .transition(ThemeMotion.scaleFade(scale: 0.96, anchor: .bottomTrailing, reduceMotion: reduceMotion))
                }
            }
            .animation(ThemeMotion.easeInOut(duration: 0.18, reduceMotion: reduceMotion), value: scrollController.isJumpToBottomHintVisible)
            .onChange(of: scrollController.isJumpToBottomHintVisible) { _, visible in
                if visible { contextBarCollapseToken &+= 1 }
            }
    }

    private var chatContent: some View {
        configuredChatContent
            .chatAuxiliaryPresentation(
                isPresented: $showOutline,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { outlineSheet }
            .chatAuxiliaryPresentation(
                isPresented: $isFilePanelVisible,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { filePanelSheet }
            .sheet(isPresented: $showModelPicker) { modelPickerSheet }
            .chatAuxiliaryPresentation(
                isPresented: $showContextInspector,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { contextInspectorSheet }
            .chatAuxiliaryPresentation(
                isPresented: $showShareRedactionSheet,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { shareRedactionSheet }
            .chatAuxiliaryPresentation(
                isPresented: $showReviewCommentStash,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { reviewCommentStashSheet }
            .fullScreenCover(isPresented: $showComposer) { composerSheet }
            .alert("Rename Session", isPresented: $showRenameAlert) { renameAlert }
            .task(id: composerDraftAttachmentKey) {
                attachComposerDraftIfPossible()
            }
            .task(id: connectionTaskKey) {
                audioPlayer.setSessionContext(session)
                voiceInputManager.activeSessionId = sessionId
                voiceInputManager.setServerCredentials(connection.credentials)
                voiceInputManager.setServerConnection(connection)
                audioLifecycleCoordinator.setPlaybackInterrupter(audioPlayer)
                // Dictation must use the concrete player as the hardware source of truth.
                // The lifecycle coordinator owns presentation state and can be stale across
                // direct-speak/reconnect edges; using it here can make the mic appear wedged.
                voiceInputManager.setPlaybackInterrupter(audioPlayer)
                await sessionManager.connect(
                    connection: connection,
                    sessionStore: sessionStore
                )
            }
            .task {
                // Pre-warm voice input pipeline in background (model check + transcriber creation)
                if ReleaseFeatures.voiceInputEnabled {
                    await voiceInputManager.prewarm(source: "chat_view_task")
                }
            }
            .task(id: ReviewCommentLoadKey(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId)) {
                loadReviewCommentsIfPossible()
            }
            .onChange(of: session?.displayTitle) { _, _ in
                audioPlayer.setSessionContext(session)
            }
            .onChange(of: session?.model) { _, _ in
                audioPlayer.setSessionContext(session)
            }
            .task(id: sessionId) {
                // Auto-send pending message from QuickSessionSheet.
                // Keyed on sessionId so it re-fires if the view is reused
                // for a different session (onChange self-healing path).
                guard let message = appNavigation.pendingQuickSessionMessage else { return }
                let attachments = appNavigation.pendingQuickSessionAttachments ?? []
                // Consume immediately so it doesn't re-fire
                appNavigation.pendingQuickSessionMessage = nil
                appNavigation.pendingQuickSessionAttachments = nil

                // Pre-fill the composer so the user sees their message while connecting.
                composerDraftController.replaceMessage(text: message)
                pendingAttachments = attachments

                // Wait for the session stream to be established AND the WebSocket
                // to be connected. The stream can briefly reach .streaming then
                // drop during app launch; retry the wait if it bounces.
                let deadline = ContinuousClock.now + .seconds(15)
                while true {
                    if Task.isCancelled { return }
                    if ContinuousClock.now >= deadline { return } // Timeout — user can send manually
                    if isReadyForQuickSend { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }

                // Brief settle for UI
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }

                // Auto-send through the normal WebSocket flow
                sendPrompt()
            }
            .onAppear {
                handleAppear()
#if DEBUG
                seedE2EChatImageAttachmentIfRequested()
#endif
                applyExtensionToolsExpandedState()
            }
            .onChange(of: chatState.extensionEditorTextUpdate?.revision) { _, _ in
                handleExtensionEditorTextUpdate()
            }
            .onChange(of: activeComposerAskRequest?.id) { _, _ in
                synchronizeComposerMode()
            }
            .onChange(of: extensionSurfaceState?.toolsExpanded) { _, _ in
                applyExtensionToolsExpandedState()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
                contextBarCollapseToken &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onChange(of: session?.status) { _, newStatus in
                handleSessionStatusChange(newStatus)
            }
            .onChange(of: sessionManager.entryState) { _, newState in
                handleEntryStateChange(newState)
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: AudioPlayerService.stateDidChangeNotification)) { notification in
                handleAudioPlayerStateChange(notification)
            }
            .onChange(of: sessionId) { oldId, newId in
                // Self-healing: when SwiftUI reuses this view at the same
                // structural position with a different session ID (e.g.
                // deep-link navigation, quick session switch), @State is
                // preserved. Detect the mismatch and reset all session-
                // specific state so the timeline and connection match.
                guard sessionManager.sessionId != newId else { return }

                // Tear down old session
                actionHandler.cleanup()
                sessionManager.cleanup()
                scrollController.cancel()
                if connection.isFocusedSession(oldId) {
                    connection.disconnectSession()
                }

                // Stand up new session. Detach the draft key before any new
                // workspace metadata resolves so edits cannot hit the old session.
                composerDraftController.detachForSessionChange()
                sessionManager = ChatSessionManager(
                    sessionId: newId,
                    workspaceIdHint: workspaceIdHint,
                    routeScope: focusedRouteScope
                )
                // Session switches can happen while the scene is already
                // inactive/background (deep link, iPad multitasking). The new
                // coalescer starts unpaused — re-apply the hard boundary.
                if Self.shouldPauseTimelinePresentation(for: scenePhase) {
                    sessionManager.coalescer.pause()
                }
                scrollController = ChatScrollController()
                reviewComments = ChatReviewCommentsController()
                activeReviewCommentRequest = nil
                showReviewCommentStash = false
                focusedReviewCommentId = nil
                pendingAttachments = []
                contextBarExpanded = false
                showOutline = false
                isFilePanelVisible = false
                selectedFilePanelTab = ChatFileBrowserPanelTabStore.shared.tab(for: newId)
                messageQueueEditorState = MessageQueueEditorState(queue: .empty)
                showContextInspector = false
                attachComposerDraftIfPossible()
            }
            .onChange(of: selectedFilePanelTab) { _, newTab in
                ChatFileBrowserPanelTabStore.shared.setTab(newTab, for: sessionId)
            }
            .onDisappear {
                actionHandler.cleanup()
                sessionManager.cleanup()
                scrollController.cancel()
                Task {
                    if let composerDraftStore {
                        await composerDraftStore.flush()
                    }
                    await sessionManager.flushSnapshotIfNeeded(connection: connection, force: true)
                }
                disconnectIfCurrentSession()
            }
    }

    private var prefersFullScreenChatAuxiliaryPresentation: Bool {
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    private var configuredChatContent: some View {
        configuredChatToolbarContent
    }

    private var configuredChatToolbarContent: some View {
        configuredChatNavigationContent
            .toolbarVisibility(.hidden, for: .tabBar)
            .toolbarVisibility(
                WorkspaceSessionNavigationChromePolicy.bottomBarVisibility(on: .sessionTimeline),
                for: .bottomBar
            )
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    chatLeadingToolbarItem
                }

                ToolbarItem(placement: .principal) {
                    chatPrincipalToolbarItem
                }

                ToolbarItem(placement: .topBarTrailing) {
                    chatTrailingToolbarItem
                }
            }
    }

    private var configuredChatNavigationContent: some View {
        chatTimelineScaffold
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle(sessionDisplayName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(usesCustomChatBackButton)
            .navigationDestination(item: $forkedSessionToOpen) { route in
                Self(sessionId: route.id, workspaceIdHint: route.workspaceId)
            }
            .navigationDestination(item: $sessionRouteToOpen) { route in
                Self(sessionId: route.id, workspaceIdHint: route.workspaceId)
            }
    }

    @ViewBuilder
    private var footerArea: some View {
        if isStopped {
            VStack(spacing: 8) {
                SessionEndedFooter(
                    session: session,
                    isResuming: actionHandler.isResuming,
                    onResume: {
                        actionHandler.resumeSession(
                            connection: connection,
                            reducer: reducer,
                            sessionStore: sessionStore,
                            sessionManager: sessionManager,
                            sessionId: sessionId
                        )
                    }
                )
            }
        } else {
            VStack(spacing: 8) {
                if !hasBlockingExtensionInput {
                    let surface = extensionSurfaceState ?? ExtensionSurfaceState()
                    if surface.hasVisibleContent(in: .aboveEditor) || showsMessageQueue || hasMessageQueueDraft {
                        ExtensionSurfacePanel(
                            surface: surface,
                            placement: .aboveEditor,
                            messageQueue: (showsMessageQueue || hasMessageQueueDraft) ? messageQueueSurfaceConfiguration : nil,
                            onOpenURL: openExtensionSurfaceURL,
                            onExpandedEntryChange: { expanded in
                                if expanded { dismissKeyboard() }
                            }
                        )
                        .padding(.horizontal, 16)
                    }
                }

                if let reconnectFailureMessage = actionHandler.reconnectFailureMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.themeRed)
                            .padding(.top, 1)

                        Text(reconnectFailureMessage)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.themeRed.opacity(0.08))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.themeRed.opacity(0.35), lineWidth: 1)
                    }
                    .padding(.horizontal, 16)
                }

                ChatInputBar(
                    text: composerTextBinding,
                    textBeforeRecording: $composerTextBeforeRecording,
                    pendingAttachments: $pendingAttachments,
                    pendingRepoPointers: composerRepoPointersBinding,

                    isBusy: isBusy,
                    busyStreamingBehavior: $busyStreamingBehavior,
                    isSending: isPreparingAttachments || actionHandler.isSending,
                    pendingReviewCommentCount: activeReviewCommentRequest == nil ? reviewComments.stagedCount : 0,
                    onReviewCommentsTap: { showReviewCommentStash = true },
                    placeholderOverride: activeReviewCommentRequest == nil ? nil : "Comment…",
                    sendProgressText: attachmentPreparationText ?? actionHandler.sendProgressText,
                    isStopping: isStopping,
                    voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                    showForceStop: actionHandler.showForceStop,
                    isForceStopInFlight: actionHandler.isForceStopInFlight,
                    askRequest: composerAskRequest,
                    onAskSubmit: handleComposerAskSubmit,
                    onAskIgnoreAll: handleComposerAskIgnoreAll,

                    slashCommands: availableSlashCommands,
                    fileSuggestions: chatState.fileSuggestions,
                    onFileSuggestionQuery: { query in
                        updateFileSuggestions(query: query)
                    },
                    onSend: sendComposerAction,
                    onStop: stopTurn,
                    onForceStop: {
                        actionHandler.forceStop(
                            connection: connection, reducer: reducer,
                            sessionStore: sessionStore, sessionId: sessionId
                        )
                    },
                    onExpand: presentComposer,
                    externalFocusRequestID: composerExternalFocusRequestID,
                    appliesOuterPadding: true,
                    alwaysShowActionRow: true,
                    allowsExpansion: composerAskRequest == nil,
                    actionRow: {
                        composerActionRow
                    }
                )

                if !hasBlockingExtensionInput,
                   let surface = extensionSurfaceState,
                   surface.hasVisibleContent(in: .belowEditor) {
                    ExtensionSurfacePanel(
                        surface: surface,
                        placement: .belowEditor,
                        onOpenURL: openExtensionSurfaceURL
                    )
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private var composerActionRow: some View {
        if let request = activeReviewCommentRequest {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(QuickCommentTemplate.quickCommentTemplates(quickCommentTemplateStore.templates)) { template in
                            Button {
                                applyQuickCommentTemplate(template)
                            } label: {
                                Label(template.title, systemImage: template.systemImage)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.themeBgHighlight.opacity(0.85), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.themeFg)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    cancelReviewCommentInput()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Color.themeBgHighlight.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeFgDim)
                .accessibilityLabel("Cancel comment")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Comment actions for selected text: \(request.selectedText)")
        } else {
            SessionToolbar(
                session: session,
                thinkingLevel: chatState.thinkingLevel,
                onModelTap: { showModelPicker = true },
                onThinkingSelect: { level in
                    actionHandler.setThinking(
                        level,
                        connection: connection,
                        reducer: reducer,
                        sessionId: sessionId
                    )
                }
            )
        }
    }

    private func toggleChatFilePanel(source: String) {
        AppHaptics.toolbarExpansion()
        let willShow = !isFilePanelVisible
        isFilePanelVisible = willShow
        ClientLog.info("FileBrowser", "Chat files toggle tapped", metadata: [
            "sessionId": sessionId,
            "workspaceId": session?.workspaceId ?? "none",
            "isFilePanelVisible": String(isFilePanelVisible),
            "selectedTab": selectedFilePanelTab.rawValue,
            "source": source,
        ])
        if isFilePanelVisible {
            showOutline = false
        }
    }

    private func closeChatFilePanel() {
        isFilePanelVisible = false
    }

    private var usesCustomChatBackButton: Bool {
        appNavigation.workspaceNavigationPresentation == .stack
            || appNavigation.workspaceNavigationPresentation == .split
    }

    @ViewBuilder
    private var chatLeadingToolbarItem: some View {
        HStack(spacing: 10) {
            if usesCustomChatBackButton {
                Button(action: navigateBackFromChat) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("chat.toolbar.back")
            }

            chatFilesToolbarItem
        }
        .accessibilityElement(children: .contain)
    }

    private func navigateBackFromChat() {
        if ownsWorkspacePathBackNavigation,
           appNavigation.workspaceNavigationPresentation == .stack {
            // Let SwiftUI coordinate the pop with its hosting-controller cache.
            // Mutating NavigationPath directly during toolbar layout can force a
            // synchronous NavigationStack reconciliation on the main thread.
            dismiss()
            return
        }
        if appNavigation.workspaceNavigationPresentation == .split {
            if appNavigation.splitDetailPath.count > 0 {
                dismiss()
                return
            }
            appNavigation.showSessionInboxInSplit()
            return
        }
        dismiss()
    }

    @ViewBuilder
    private var chatFilesToolbarItem: some View {
        if session?.workspaceId != nil {
            Button {
                toggleChatFilePanel(source: "top_leading_pill")
            } label: {
                Image(systemName: isFilePanelVisible ? "folder.fill" : "folder")
                    .font(.subheadline)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFilePanelVisible ? .themeBlue : .themeFg)
            .accessibilityLabel(isFilePanelVisible ? "Close chat files" : "Open chat files")
            .accessibilityIdentifier("chat.toolbar.files")
        }
    }

    @ViewBuilder
    private var chatPrincipalToolbarItem: some View {
        Button {
            renameText = session?.name ?? ""
            showRenameAlert = true
        } label: {
            sessionTitleLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rename session")
        .accessibilityValue(
            assistantIdentityPresentation == .globalAvatar
                ? sessionDisplayName
                : "\(sessionDisplayName), launched with a saved Agent"
        )
        .contextMenu {
            Button("Copy Session ID", systemImage: "doc.on.doc") {
                copySessionID()
            }
            Button("Share Session", systemImage: "square.and.arrow.up") {
                shareSessionFromTitleMenu()
            }
            .disabled(!hasShareSlashCommand)
        }
    }

    @ViewBuilder
    private var chatTrailingToolbarItem: some View {
        HStack(spacing: 2) {
            if !reducer.items.isEmpty {
                Button { showOutline = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open session outline")
                .accessibilityIdentifier("chat.toolbar.outline")
            }

            contextRingButton
        }
    }

    private var contextRingButton: some View {
        Button {
            AppHaptics.toolbarExpansion()
            showContextInspector = true
        } label: {
            ContextUsageRingBadge(
                usage: contextUsageSnapshot
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.toolbar.context")
        .accessibilityLabel("Open context inspector")
    }

    private var chatPrincipalTitleMaxWidth: CGFloat {
        let screenWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen.bounds.width ?? 390
        let reservedChromeWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 220 : 178
        let upperBound: CGFloat = dynamicTypeSize.isAccessibilitySize ? 260 : 320
        return max(132, min(upperBound, screenWidth - reservedChromeWidth))
    }

    private var sessionTitleLabel: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                switch assistantIdentityPresentation {
                case .agent:
                    AgentIconView(
                        value: session?.launch?.agentIcon,
                        size: 18,
                        frameSize: 20,
                        visualScale: ChatAgentIconStyle.compactVisualScale
                    )
                case .globalAvatar:
                    CurrentAssistantAvatarPreview(
                        sessionId: sessionId,
                        size: 20
                    )
                }

                Text(sessionDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let cost = session?.cost, cost > 0 {
                    Text(SessionFormatting.costString(cost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.themeComment)
                        .fixedSize()
                }

                if let terminalMirrorIndicator = TerminalMirrorIndicatorPresentation(session: session) {
                    TerminalMirrorIndicatorView(presentation: terminalMirrorIndicator)
                }
            }
        }
        .frame(maxWidth: chatPrincipalTitleMaxWidth)
        .clipped()
    }

    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter {
        ReviewCommentSelectionRouter(
            dispatchWithPresentation: { request, presentingViewController in
                handleReviewCommentSelection(request, presentingViewController: presentingViewController)
            },
            inlineSave: { body, request in
                saveReviewComment(body: body, request: request)
            },
            inlineQuickComments: QuickCommentTemplate.quickCommentTemplates(quickCommentTemplateStore.templates),
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil
        )
    }

    // MARK: - Actions

    private func updateFileSuggestions(query: String?) {
        if let query {
            connection.fetchFileSuggestions(query: query)
        } else {
            connection.clearFileSuggestions()
        }
    }


    @MainActor
    private func handleReviewCommentSelection(
        _ request: ReviewCommentSelectionRequest,
        presentingViewController: UIViewController? = nil
    ) {
        activeReviewCommentRequest = request
        composerDraftController.setMode(.reviewComment, resetTransientInput: true)
        composerTextBeforeRecording = nil
        pendingAttachments = []
        composerExternalFocusRequestID &+= 1
        contextBarCollapseToken &+= 1
    }

    private func applyQuickCommentTemplate(_ template: QuickCommentTemplate) {
        let text = template.quickCommentText
        guard !text.isEmpty else { return }
        let trimmed = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            composerDraftController.text = text
        } else if composerDraftController.text.hasSuffix("\n") {
            composerDraftController.text += text
        } else {
            composerDraftController.text += "\n" + text
        }
        composerExternalFocusRequestID &+= 1
    }

    private func cancelReviewCommentInput() {
        activeReviewCommentRequest = nil
        synchronizeComposerMode()
        composerTextBeforeRecording = nil
    }

    private func sendComposerAction() {
        if activeReviewCommentRequest != nil {
            sendActiveReviewComment()
        } else {
            sendPrompt()
        }
    }

    private func stopTurn() {
        restoreQueuedMessagesToComposerBeforeStop()
        actionHandler.stop(
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            sessionId: sessionId
        )
    }

    @discardableResult
    private func restoreQueuedMessagesToComposerBeforeStop() -> Bool {
        guard connection.isFocusedSession(sessionId),
              let plan = MessageQueueComposerRestore.plan(
                  queue: messageQueueState,
                  currentText: composerDraftController.text
              ) else {
            return false
        }

        composerDraftController.replaceMessage(text: plan.text)
        composerTextBeforeRecording = nil
        messageQueueStore.apply(plan.clearedQueue, for: sessionId)
        if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
        return true
    }

    private func sendActiveReviewComment() {
        guard let request = activeReviewCommentRequest else { return }
        let body = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let didSave = saveReviewComment(body: body, request: request)
        if didSave {
            activeReviewCommentRequest = nil
            synchronizeComposerMode()
            composerTextBeforeRecording = nil
            loadReviewCommentsIfPossible()
        }
    }

    private func presentComposer() {
        guard activeComposerAskRequest == nil else { return }
        AppHaptics.toolbarExpansion()
        showComposer = true
    }

    @MainActor
    private func stageWorkspaceReviewInCurrentSession(prompt: String, files: [PendingFileReference]) {
        composerDraftController.mutateMessage { text, repoPointers in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = prompt
            } else if text.hasSuffix("\n\n") {
                text += prompt
            } else if text.hasSuffix("\n") {
                text += "\n" + prompt
            } else {
                text += "\n\n" + prompt
            }

            for file in files where !repoPointers.contains(where: { $0.id == file.id }) {
                repoPointers.append(file)
            }
        }

        if isStopped {
            showComposer = true
        } else if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    @MainActor
    private func applyExtensionEditorText(_ text: String) {
        composerDraftController.replaceMessage(text: text)
        if isStopped {
            showComposer = true
        } else if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    private func loadReviewCommentsIfPossible() {
        reviewComments.load(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId)
    }

    @discardableResult
    private func saveReviewComment(body: String, request: ReviewCommentSelectionRequest) -> Bool {
        if let error = reviewComments.save(
            body: body,
            request: request,
            localScopeId: reviewCommentLocalScopeId,
            sessionId: sessionId
        ) {
            connection.extensionToast = error
            return false
        }
        return true
    }

    private func deleteReviewComment(_ comment: ReviewComment) {
        reviewComments.delete(comment)
    }

    private func clearSentReviewComments(ids: [String]) {
        reviewComments.clearSent(ids: ids)
    }

    @MainActor
    private func openExtensionSurfaceURL(_ url: URL) -> Bool {
        let defaultWorkspaceId = session?.workspaceId ?? sessionStore.workspaceId(for: sessionId)
        guard let link = ExtensionSurfaceSessionLink.parse(url, defaultWorkspaceId: defaultWorkspaceId) else {
            return false
        }
        guard link.sessionId != sessionId else {
            return true
        }

        connection.prepareForSessionReentry(link.sessionId, workspaceIdHint: link.workspaceId)
        sessionRouteToOpen = SessionRoute(id: link.sessionId, workspaceId: link.workspaceId)
        return true
    }

    @MainActor
    private func attachComposerDraftIfPossible() {
        guard let composerDraftStore, let composerDraftKey else { return }
        composerDraftController.attach(
            store: composerDraftStore,
            key: composerDraftKey,
            isEphemeral: composerDraftIsMemoryOnly
        )
        synchronizeComposerMode()
    }

    @MainActor
    private func synchronizeComposerMode() {
        let mode = Self.resolvedComposerMode(
            hasReviewComment: activeReviewCommentRequest != nil,
            hasAskRequest: activeComposerAskRequest != nil
        )
        if mode == .ask {
            showComposer = false
        }
        composerDraftController.setMode(mode)
    }

    @MainActor
    private func handleAppear() {
        // Re-establish command routing immediately on re-entry.
        // The async sessionManager.connect() task starts shortly after onAppear,
        // but users can tap toolbar controls before that task has a chance to
        // refocus the connection on this session.
        connection.prepareForSessionReentry(
            sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: focusedRouteScope
        )

        sessionManager.markAppeared()
        if Self.shouldPauseTimelinePresentation(for: scenePhase) {
            sessionManager.coalescer.pause()
        } else if scenePhase == .active,
                  sessionManager.coalescer.resume() {
            sessionManager.reloadTimelineAfterPresentationOverflow(
                connection: connection,
                sessionStore: sessionStore
            )
        }
        voiceInputManager.loadPreferences()
        attachComposerDraftIfPossible()
        // Load initial git status for the workspace
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            let ws = connection.workspaceStore.workspaces.first { $0.id == wsId }
            gitStatusStore.loadInitial(
                workspaceId: wsId,
                worktreeId: session?.worktreeId,
                apiClient: api,
                gitStatusEnabled: ws?.gitStatusEnabled ?? true
            )
        }
        // Pre-load file index for @file fuzzy search
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            fileIndexStore.ensureLoaded(workspaceId: wsId, apiClient: api)
        }
    }

    static func shouldPauseTimelinePresentation(for phase: ScenePhase) -> Bool {
        phase == .inactive || phase == .background
    }

    @MainActor
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if Self.shouldPauseTimelinePresentation(for: phase) {
            // The timeline stays mounted while the scene cannot present a
            // frame. Keep transport and shared session status alive, but make
            // timeline publication a hard presentation boundary.
            sessionManager.coalescer.pause()
            return
        }

        guard phase == .active else { return }
        if sessionManager.coalescer.resume() {
            sessionManager.reloadTimelineAfterPresentationOverflow(
                connection: connection,
                sessionStore: sessionStore
            )
        }
    }

#if DEBUG
    @MainActor
    private func seedE2EChatImageAttachmentIfRequested() {
        guard !hasSeededE2EChatImageAttachment else { return }
        guard let rawBase64 = ProcessInfo.processInfo.environment["OPPI_E2E_CHAT_PENDING_IMAGE_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBase64.isEmpty else {
            return
        }

        hasSeededE2EChatImageAttachment = true
        let compactBase64 = rawBase64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compactBase64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else {
            return
        }

        let configuredMimeType = ProcessInfo.processInfo.environment["OPPI_E2E_CHAT_PENDING_IMAGE_MIME_TYPE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let mimeType = configuredMimeType.isEmpty ? "image/png" : configuredMimeType
        let attachment = PendingAttachment(
            id: "e2e-chat-image",
            source: .image,
            displayName: Self.e2eImageDisplayName(mimeType: mimeType),
            thumbnail: image,
            imageAttachment: ImageAttachment(data: compactBase64, mimeType: mimeType),
            localFileData: nil,
            localMimeType: nil
        )
        if !pendingAttachments.contains(where: { $0.id == attachment.id }) {
            pendingAttachments.append(attachment)
        }
    }

    private static func e2eImageDisplayName(mimeType: String) -> String {
        switch mimeType.split(separator: ";", maxSplits: 1).first?.lowercased() {
        case "image/jpeg", "image/jpg":
            return "e2e-image.jpg"
        case "image/gif":
            return "e2e-image.gif"
        case "image/webp":
            return "e2e-image.webp"
        default:
            return "e2e-image.png"
        }
    }
#endif

    @MainActor
    private func handleExtensionEditorTextUpdate() {
        guard let update = chatState.extensionEditorTextUpdate,
              update.sessionId == sessionId else {
            return
        }
        applyExtensionEditorText(update.text)
    }

    @MainActor
    private func applyExtensionToolsExpandedState() {
        guard let toolsExpanded = extensionSurfaceState?.toolsExpanded else { return }
        reducer.applyExtensionToolsExpanded(toolsExpanded)
    }

    @MainActor
    private func handleSessionStatusChange(_ newStatus: SessionStatus?) {
        if newStatus != .stopping {
            actionHandler.resetStopState()
            sessionManager.cancelReconciliation()
        }

        let shouldReconnectStoppedSession: Bool
        if let newStatus, newStatus != .stopped,
           case .stopped = sessionManager.entryState {
            shouldReconnectStoppedSession = true
        } else {
            shouldReconnectStoppedSession = false
        }

        if shouldReconnectStoppedSession {
            // A visible session can enter as stopped, then become busy when a
            // external session link resumes the current turn. The stopped entry
            // path intentionally avoided WSS; restart the connect task now so
            // live parent output is subscribed. Queue sync runs after the
            // stream reconnects, so skip the pre-reconnect get_queue request.
            sessionManager.reconnect()
            return
        }

        guard newStatus == .busy else { return }
        Task {
            try? await connection.requestMessageQueue(sessionIdOverride: sessionId)
        }
    }

    @MainActor
    private func handleEntryStateChange(_ newState: ChatSessionManager.SessionEntryState) {
        if newState == .streaming {
            actionHandler.clearReconnectFailure()
        }
    }

    @MainActor
    private func disconnectIfCurrentSession() {
        if audioPlayer.activeLiveTransportSessionID == sessionId {
            connection.deferDisconnectSessionUntilLiveAudioStreamFinishes(sessionId)
            return
        }
        let focusedSessionId = connection.focusedSessionId
        if focusedSessionId == sessionId || focusedSessionId == nil {
            connection.disconnectSession()
        }
    }

    @MainActor
    private var isReadyForQuickSend: Bool {
        guard sessionManager.entryState == .streaming else { return false }
        return connection.wsClient?.status == .connected
    }

    private var composerIsSending: Bool {
        isPreparingAttachments || actionHandler.isSending
    }

    private var composerSendProgressText: String? {
        attachmentPreparationText ?? actionHandler.sendProgressText
    }

    @MainActor
    private func handleAudioPlayerStateChange(_ notification: Notification) {
        guard notification.object as? AudioPlayerService === audioPlayer else { return }
        let playing = notification.userInfo?[AudioPlayerService.playingItemIDUserInfoKey] as? String
        let loading = notification.userInfo?[AudioPlayerService.loadingItemIDUserInfoKey] as? String
        audioLifecycleCoordinator.syncPlaybackState(
            playingItemID: playing?.isEmpty == false ? playing : nil,
            loadingItemID: loading?.isEmpty == false ? loading : nil
        )
    }

    @MainActor
    private func handleContextBarExpandedChanged(_ expanded: Bool) {
        contextBarExpanded = expanded
        guard expanded else { return }

        // Avoid overlap between expanded git context and composer when the
        // software keyboard is visible.
        dismissKeyboard()
    }

    @MainActor
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    @MainActor
    private func dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle() {
        guard composerDraftController.mode == .message,
              composerDraftController.text.isEmpty,
              composerDraftController.repoPointers.isEmpty,
              pendingAttachments.isEmpty,
              composerTextBeforeRecording == nil else {
            return
        }
        dismissKeyboard()
    }

    private func uploadPendingLocalAttachments(
        _ sourceAttachments: [PendingAttachment]
    ) async throws -> [ChatAttachmentRef] {
        let localAttachments = sourceAttachments.filter { $0.source == .image || $0.source == .localFile }
        guard !localAttachments.isEmpty else { return [] }
        guard let api = connection.apiClient else {
            throw APIError.server(status: 503, message: "No server connection available")
        }
        guard let routeScope = focusedRouteScope else {
            throw TreeNavigationError.sessionNotReady
        }

        let imageAutoResize: Bool
        if localAttachments.contains(where: { $0.source == .image }) {
            imageAutoResize = await imageAutoResizeEnabled(api: api)
        } else {
            imageAutoResize = false
        }

        var uploaded: [ChatAttachmentRef] = []
        for (index, pending) in localAttachments.enumerated() {
            attachmentPreparationText = "Uploading attachment \(index + 1) of \(localAttachments.count)…"

            let payload: (data: Data, mimeType: String, name: String)
            switch pending.source {
            case .image:
                guard let imageAttachment = pending.imageAttachment else {
                    throw APIError.server(status: 400, message: "Invalid pending image data")
                }
                let uploadAttachment = PendingImage.uploadAttachment(
                    from: imageAttachment,
                    autoResize: imageAutoResize
                )
                guard let data = Data(base64Encoded: uploadAttachment.data, options: .ignoreUnknownCharacters) else {
                    throw APIError.server(status: 400, message: "Invalid pending image data")
                }
                let name = imageUploadName(
                    displayName: pending.displayName,
                    mimeType: uploadAttachment.mimeType,
                    index: index
                )
                payload = (data, uploadAttachment.mimeType, name)
            case .localFile:
                guard let data = pending.localFileData,
                      let mimeType = pending.localMimeType else {
                    throw APIError.server(status: 400, message: "Invalid pending file data")
                }
                payload = (data, mimeType, pending.displayName)
            }

            let upload = try await api.createSessionAttachmentUpload(
                scope: routeScope,
                sessionId: sessionId,
                name: payload.name,
                mimeType: payload.mimeType,
                sizeBytes: payload.data.count
            )
            let attachment = try await api.uploadSessionAttachmentContent(
                scope: routeScope,
                sessionId: sessionId,
                attachmentId: upload.uploadId,
                data: payload.data,
                contentType: payload.mimeType
            )
            uploaded.append(attachment)
        }
        return uploaded
    }

    private func imageAutoResizeEnabled(api: APIClient) async -> Bool {
        do {
            return try await api.serverInfo().images?.autoResize ?? false
        } catch {
            return false
        }
    }

    private func imageUploadName(displayName: String, mimeType: String, index: Int) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExtension = imageUploadFileExtension(for: mimeType)
        if !trimmed.isEmpty,
           trimmed.lowercased().hasSuffix(".\(fileExtension)") {
            return trimmed
        }
        return "image-\(index + 1).\(fileExtension)"
    }

    private func imageUploadFileExtension(for mimeType: String) -> String {
        switch mimeType.split(separator: ";", maxSplits: 1).first?.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/jpeg", "image/jpg": return "jpg"
        default: return "jpg"
        }
    }

    private func uploadPreparationErrorMessage(_ error: Error) -> String {
        if case let APIError.server(status, message) = error {
            if status == 404 {
                return "This server does not support attachment uploads yet."
            }
            return message
        }
        return error.localizedDescription
    }

    private func handleComposerAskSubmit(_ answers: [String: AskAnswer]) {
        guard let ask = activeComposerAskRequest,
              let payload = ask.responsePayload(from: answers) else { return }

        Task {
            do {
                try await connection.respondToExtensionUI(
                    id: ask.id,
                    sessionId: ask.sessionId,
                    payload: payload
                )
            } catch {
                connection.extensionToast = "Failed to respond: \(error.localizedDescription)"
            }
        }
    }

    private func handleComposerAskIgnoreAll() {
        guard let ask = activeComposerAskRequest else { return }

        Task {
            do {
                try await connection.respondToExtensionUI(
                    id: ask.id,
                    sessionId: ask.sessionId,
                    payload: .cancelled
                )
            } catch {
                connection.extensionToast = "Failed to cancel: \(error.localizedDescription)"
            }
        }
    }

    private func sendPrompt() {
        let rawTrimmedInput = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.localSlashCommand(for: rawTrimmedInput) == .compact {
            composerDraftController.clearMessage()
            pendingAttachments = []
            composerTextBeforeRecording = nil
            actionHandler.compact(connection: connection, reducer: reducer, sessionId: sessionId)
            dismissKeyboard()
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/reload") == .orderedSame {
            composerDraftController.clearMessage()
            actionHandler.reloadResources(
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId
            )
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/share") == .orderedSame {
            sendShareSlashCommand(clearComposer: true)
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/review-comments") == .orderedSame {
            composerDraftController.clearMessage()
            connection.extensionToast = "Review comments use compact inline selection now."
            return
        }

        guard !isPreparingAttachments, !actionHandler.isSending else { return }

        let originalInputText = composerDraftController.text
        let originalPendingAttachments = pendingAttachments
        let originalPendingRepoPointers = composerDraftController.repoPointers
        let submission = composerDraftController.beginSubmission()
        let reviewText = reviewComments.appendReviewBlock(to: originalInputText)
        let text = PendingFileReference.appendReferenceBlock(to: reviewText, files: originalPendingRepoPointers)
        let stagedReviewCommentIds = reviewComments.stagedCommentIds
        let sessionManagerRef = sessionManager
        let scrollRef = scrollController

        Task { @MainActor in
            do {
                let pendingLocalAttachments = originalPendingAttachments.filter {
                    $0.source == .image || $0.source == .localFile
                }
                isPreparingAttachments = true
                attachmentPreparationText = pendingLocalAttachments.isEmpty ? nil : "Uploading attachments…"

                let attachments = try await self.uploadPendingLocalAttachments(originalPendingAttachments)
                let optimisticDisplayText = UserMessageAttachmentPresentation.makeDisplayText(
                    text: reviewText,
                    pendingAttachments: originalPendingAttachments,
                    pendingRepoPointers: originalPendingRepoPointers,
                    uploadedAttachments: attachments
                )

                isPreparingAttachments = false
                attachmentPreparationText = nil

                let optimisticImages = originalPendingAttachments.compactMap(\.imageAttachment)
                let restored = actionHandler.sendPrompt(
                    text: text,
                    attachments: attachments,
                    optimisticDisplayText: optimisticDisplayText,
                    optimisticImages: optimisticImages,
                    isBusy: isBusy,
                    busyStreamingBehavior: busyStreamingBehavior,
                    connection: connection,
                    reducer: reducer,
                    sessionId: sessionId,
                    sessionStore: sessionStore,
                    sessionManager: sessionManager,
                    onDispatchStarted: {
                        pendingAttachments = []

                        // Scroll to bottom after sending
                        scrollRef.requestScrollToBottom()
                    },
                    onSendSucceeded: {
                        composerDraftController.completeSubmission(submission)
                        clearSentReviewComments(ids: stagedReviewCommentIds)
                        dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                    },
                    onAsyncFailure: { _, _ in
                        composerDraftController.failSubmission(submission)
                        pendingAttachments = originalPendingAttachments
                    },
                    onNeedsReconnect: {
                        sessionManagerRef.reconnect()
                    }
                )
                if !restored.isEmpty {
                    composerDraftController.failSubmission(submission)
                }
            } catch {
                isPreparingAttachments = false
                attachmentPreparationText = nil
                composerDraftController.failSubmission(submission)
                pendingAttachments = originalPendingAttachments
                reducer.process(.error(sessionId: sessionId, message: self.uploadPreparationErrorMessage(error)))
            }
        }
    }

    private func handleModelSelection(_ model: ModelInfo) {
        switch ModelSwitchPolicy.decision(
            currentModel: session?.model,
            selectedModel: model,
            messageCount: session?.messageCount ?? 0
        ) {
        case .unchanged:
            return
        case .applyImmediately:
            applyModelSelection(model)
        }
    }

    private func applyModelSelection(_ model: ModelInfo) {
        AppPreferences.RecentModels.record(ModelSwitchPolicy.fullModelID(for: model))
        actionHandler.setModel(
            model,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId
        )
    }

    private func copySessionID() {
        UIPasteboard.general.string = sessionId
    }

    private func shareSessionFromTitleMenu() {
        guard hasShareSlashCommand else {
            reducer.process(
                .error(sessionId: sessionId, message: "Share command is not enabled for this workspace.")
            )
            return
        }

        shareRedactionPolicy = AppPreferences.Share.redactionPolicy
        sharePreflightResult = nil
        sharePreflightError = nil
        showShareRedactionSheet = true
    }

    private func sendShareSlashCommand(clearComposer: Bool) {
        guard hasShareSlashCommand else {
            reducer.process(
                .error(sessionId: sessionId, message: "Share command is not enabled for this workspace.")
            )
            return
        }

        let sessionManagerRef = sessionManager
        let policy = AppPreferences.Share.redactionPolicy
        let submission = clearComposer ? composerDraftController.beginSubmission() : nil

        actionHandler.shareSession(
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            redactionPolicy: policy,
            onDispatchStarted: {
                guard clearComposer else { return }
                pendingAttachments = []
            },
            onSendSucceeded: {
                if let submission {
                    composerDraftController.completeSubmission(submission)
                    dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                }
            },
            onAsyncFailure: {
                if let submission {
                    composerDraftController.failSubmission(submission)
                }
            },
            onNeedsReconnect: {
                sessionManagerRef.reconnect()
            }
        )
    }

    private func scheduleSharePreflight() {
        sharePreflightTask?.cancel()
        isSharePreflightRunning = true
        sharePreflightError = nil

        let policy = shareRedactionPolicy.normalized

        sharePreflightTask = Task { @MainActor in
            defer { isSharePreflightRunning = false }

            do {
                try await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, showShareRedactionSheet else { return }
                let prepared = try await connection.prepareShareSession(redactionPolicy: policy)
                guard !Task.isCancelled else { return }
                sharePreflightResult = prepared
                sharePreflightError = nil
            } catch {
                guard !Task.isCancelled else { return }
                sharePreflightResult = nil
                sharePreflightError = error.localizedDescription
            }
        }
    }

    private func cancelSharePreflight() {
        sharePreflightTask?.cancel()
        sharePreflightTask = nil
        isSharePreflightRunning = false
    }

    private func publishSessionWithCurrentRedactionPolicy() {
        let sessionManagerRef = sessionManager
        let policy = shareRedactionPolicy.normalized

        AppPreferences.Share.setRedactionPolicy(policy)
        cancelSharePreflight()
        showShareRedactionSheet = false

        actionHandler.shareSession(
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            redactionPolicy: policy,
            onNeedsReconnect: {
                sessionManagerRef.reconnect()
            }
        )
    }

    // MARK: - Sheets & Alerts


    private var outlineSheet: some View {
        SessionOutlineView(
            items: reducer.items,
            sessionId: sessionId,
            workspaceId: session?.workspaceId,
            onSelect: { targetID in
                if reducer.items.contains(where: { $0.id == targetID }) {
                    scrollController.scrollTargetID = targetID
                    return
                }

                Task { @MainActor in
                    _ = await sessionManager.loadTracePageAround(
                        entryId: targetID,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                    scrollController.scrollTargetID = targetID
                }
            },
            onFork: forkFromMessage,
            onNavigateTreeNode: { request in
                try await navigateFromTree(request)
            },
            loadTree: { filterMode in
                try await connection.getSessionTree(filterMode: filterMode)
            },
            loadOutline: {
                guard let routeScope = focusedRouteScope else {
                    throw TreeNavigationError.sessionNotReady
                }
                return try await connection.getSessionTraceOutline(
                    routeScope: routeScope,
                    sessionId: sessionId
                )
            }
        )
    }

    private var filePanelSheet: some View {
        NavigationStack {
            ChatFileBrowserPanel(
                sessionId: sessionId,
                workspaceId: session?.workspaceId,
                changedFiles: session?.changeStats?.changedFiles ?? [],
                selectedTab: $selectedFilePanelTab,
                fileDetailReviewCommentScope: .activeSession(reviewCommentSelectionRouter)
            )
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { closeChatFilePanel() }
                }
            }
        }
    }

    private var reviewCommentStashSheet: some View {
        let commentsController = reviewComments
        let connection = connection

        return ReviewCommentStashSheet(
            comments: commentsController.stagedComments,
            focusedCommentId: focusedReviewCommentId,
            // Keep the save callback scoped to the state it needs. The device test
            // determines whether this affects the watchdog path.
            onEdit: { [commentsController, connection] comment, body in
                if let error = commentsController.update(comment, body: body) {
                    connection.extensionToast = error
                    return false
                }
                return true
            },
            onDelete: { comment in
                deleteReviewComment(comment)
            },
            onClose: {
                showReviewCommentStash = false
                focusedReviewCommentId = nil
            }
        )
        .onDisappear {
            focusedReviewCommentId = nil
        }
    }

    private var shareRedactionSheet: some View {
        ShareSessionRedactionSheet(
            policy: $shareRedactionPolicy,
            preflight: sharePreflightResult,
            isAnalyzing: isSharePreflightRunning,
            errorMessage: sharePreflightError,
            isSharing: actionHandler.isSending,
            onRefresh: {
                scheduleSharePreflight()
            },
            onShare: {
                publishSessionWithCurrentRedactionPolicy()
            },
            onCancel: {
                cancelSharePreflight()
                showShareRedactionSheet = false
            }
        )
        .onAppear {
            shareRedactionPolicy = AppPreferences.Share.redactionPolicy
            sharePreflightResult = nil
            sharePreflightError = nil
            scheduleSharePreflight()
        }
        .onDisappear {
            cancelSharePreflight()
        }
        .onChange(of: shareRedactionPolicy) { _, newPolicy in
            let normalized = newPolicy.normalized
            if normalized != shareRedactionPolicy {
                shareRedactionPolicy = normalized
                return
            }
            AppPreferences.Share.setRedactionPolicy(normalized)
            scheduleSharePreflight()
        }
    }

    @MainActor
    private func navigateFromTree(_ request: SessionOutlineView.TreeNavigationRequest) async throws {
        guard session?.status == .ready else {
            throw TreeNavigationError.sessionNotReady
        }

        let result = try await connection.navigateTree(
            targetId: request.targetId,
            summarize: request.summarize,
            customInstructions: request.customInstructions,
            replaceInstructions: request.replaceInstructions,
            label: request.label
        )

        if result.cancelled {
            throw TreeNavigationError.navigationCancelled
        }

        if result.aborted == true {
            throw TreeNavigationError.navigationAborted
        }

        let historyReloaded = await sessionManager.forceHistoryReload(
            connection: connection,
            sessionStore: sessionStore
        )

        guard historyReloaded else {
            throw TreeNavigationError.historyReloadFailed
        }

        let viewUpdate = TreeNavigationViewUpdate.from(
            targetId: request.targetId,
            editorText: result.editorText,
            showComposer: showComposer
        )

        scrollController.scrollTargetID = viewUpdate.scrollTargetID
        composerDraftController.replaceMessage(
            text: viewUpdate.inputText,
            repoPointers: []
        )
        pendingAttachments = []

        if viewUpdate.shouldFocusComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    private func forkFromMessage(_ entryId: String) {
        guard let workspaceId = session?.workspaceId, !workspaceId.isEmpty else {
            reducer.process(.error(sessionId: sessionId, message: "Missing workspace context for fork."))
            return
        }

        Task {
            do {
                let forked = try await connection.forkIntoNewSessionFromTimelineEntry(
                    entryId,
                    sourceSessionId: sessionId,
                    workspaceId: workspaceId
                )

                let title = forked.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(forked.id.prefix(8))"
                reducer.appendSystemEvent("Fork created as new session: \(displayName)")

                forkedSessionToOpen = ForkRoute(id: forked.id, workspaceId: forked.workspaceId ?? workspaceId)
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Fork failed: \(error.localizedDescription)"))
            }
        }
    }

    private var currentWorkspace: Workspace? {
        guard let wsId = session?.workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == wsId }
    }

    private var contextInspectorSheet: some View {
        NavigationStack {
            ContextInspectorView(
                session: session,
                workspace: currentWorkspace,
                loadSessionStats: {
                    try await connection.getSessionStats()
                }
            )
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showContextInspector = false }
                }
            }
        }
        .environment(\.reviewCommentSelectionScope, .activeSession(reviewCommentSelectionRouter))
    }

    private var modelPickerSheet: some View {
        ModelPickerSheet(currentModel: session?.model) { model in
            handleModelSelection(model)
        }
        .presentationDetents([.medium, .large])
    }

    private var composerSheet: some View {
        ExpandedComposerView(
            text: composerTextBinding,
            textBeforeRecording: $composerTextBeforeRecording,
            pendingAttachments: $pendingAttachments,
            pendingRepoPointers: composerRepoPointersBinding,
            isBusy: isBusy,
            busyStreamingBehavior: busyStreamingBehavior,
            slashCommands: availableSlashCommands,
            fileSuggestions: chatState.fileSuggestions,
            onFileSuggestionQuery: { query in
                updateFileSuggestions(query: query)
            },
            session: session,
            thinkingLevel: chatState.thinkingLevel,
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
            onSend: sendComposerAction,
            onModelTap: { showModelPicker = true },
            onThinkingSelect: { level in
                actionHandler.setThinking(
                    level,
                    connection: connection,
                    reducer: reducer,
                    sessionId: sessionId
                )
            }
        )
    }

    @ViewBuilder
    private var renameAlert: some View {
        TextField("Session name", text: $renameText)
        Button("Rename") {
            actionHandler.rename(
                renameText,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId
            )
        }
        Button("Cancel", role: .cancel) {}
    }
}


private extension View {
    @ViewBuilder
    func chatAuxiliaryPresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        prefersFullScreen: Bool,
        @ViewBuilder content: @escaping () -> PresentedContent
    ) -> some View {
        if prefersFullScreen {
            fullScreenCover(isPresented: isPresented, content: content)
        } else {
            sheet(isPresented: isPresented) {
                content()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
