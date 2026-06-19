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
    let sessionId: String
    private let workspaceIdHint: String?

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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var sessionManager: ChatSessionManager
    @State private var scrollController = ChatScrollController()
    @State private var actionHandler = ChatActionHandler()
    @State private var voiceInputManager = VoiceInputManager()
    @State private var audioLifecycleCoordinator = AudioLifecycleCoordinator()

    @State private var inputText = ""
    @State private var composerTextBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var pendingRepoPointers: [PendingFileReference] = []
    @State private var busyStreamingBehavior: StreamingBehavior = .steer
    @State private var isPreparingAttachments = false
    @State private var attachmentPreparationText: String?

    @State private var showOutline = false
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

    @State private var showCompactConfirmation = false
    @State private var showContextInspector = false
    @State private var suppressNextContextTap = false
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
        initialInputText: String = "",
        initialPendingFiles: [PendingFileReference] = []
    ) {
        self.sessionId = sessionId
        self.workspaceIdHint = workspaceIdHint
        _sessionManager = State(initialValue: ChatSessionManager(sessionId: sessionId, workspaceIdHint: workspaceIdHint))
        _inputText = State(initialValue: initialInputText)
        _pendingRepoPointers = State(initialValue: initialPendingFiles)
    }

    private struct ForkRoute: Identifiable, Hashable {
        let id: String
        let workspaceId: String?
    }

    private struct SessionRoute: Identifiable, Hashable {
        let id: String
        let workspaceId: String?
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

    private var extensionSurfaceState: ExtensionSurfaceState? {
        connection.extensionSurfaceBySession[sessionId]
    }

    private var activeComposerAskRequest: AskRequest? {
        askRequestStore.pending(for: sessionId)
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
            workspaceId: session?.workspaceId,
            isBusy: isBusy,
            extensionWorkingState: extensionSurfaceState?.working,
            extensionHiddenThinkingLabel: extensionSurfaceState?.hiddenThinkingLabel,
            currentModel: session?.model,
            connection: connection,
            scrollController: scrollController,
            sessionManager: sessionManager,
            audioLifecycleCoordinator: audioLifecycleCoordinator,
            onFork: forkFromMessage,
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
                    Color.themeBg.opacity(0.5)
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
            .alert("Compact Context", isPresented: $showCompactConfirmation) {
                Button("Compact", role: .destructive) {
                    actionHandler.compact(connection: connection, reducer: reducer, sessionId: sessionId)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will summarize the conversation to free up context window space. The summary replaces earlier messages.")
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
            .task(id: ReviewCommentLoadKey(workspaceId: session?.workspaceId, sessionId: sessionId)) {
                await loadReviewCommentsIfPossible()
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

                // Pre-fill the composer so the user sees their message while connecting
                inputText = message
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
                applyExtensionToolsExpandedState()
            }
            .onChange(of: chatState.extensionEditorTextUpdate?.revision) { _, _ in
                handleExtensionEditorTextUpdate()
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

                // Stand up new session
                sessionManager = ChatSessionManager(sessionId: newId, workspaceIdHint: workspaceIdHint)
                scrollController = ChatScrollController()
                reviewComments = ChatReviewCommentsController()
                activeReviewCommentRequest = nil
                showReviewCommentStash = false
                focusedReviewCommentId = nil
                inputText = ""
                pendingAttachments = []
                pendingRepoPointers = []
                contextBarExpanded = false
                showOutline = false
                showContextInspector = false
            }
            .onDisappear {
                actionHandler.cleanup()
                sessionManager.cleanup()
                scrollController.cancel()
                let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                chatState.composerDraft = draft.isEmpty ? nil : draft
                Task {
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
                if !hasBlockingExtensionInput,
                   let surface = extensionSurfaceState,
                   surface.hasVisibleContent(in: .aboveEditor) {
                    ExtensionSurfacePanel(
                        surface: surface,
                        placement: .aboveEditor,
                        onOpenURL: openExtensionSurfaceURL
                    )
                        .padding(.horizontal, 16)
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

                // Floating Game of Life indicator — pinned above input bar.
                // Visible while agent is working, hidden when scrolled up.
                if showsMessageQueue {
                    MessageQueueContainer(
                        queue: messageQueueState,
                        busyStreamingBehavior: $busyStreamingBehavior,
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
                    .padding(.horizontal, 16)
                }

                ChatInputBar(
                    text: $inputText,
                    textBeforeRecording: $composerTextBeforeRecording,
                    pendingAttachments: $pendingAttachments,
                    pendingRepoPointers: $pendingRepoPointers,

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
                    askRequest: activeComposerAskRequest,
                    onAskSubmit: handleComposerAskSubmit,
                    onAskIgnoreAll: handleComposerAskIgnoreAll,

                    slashCommands: chatState.slashCommands,
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
        .accessibilityValue(sessionDisplayName)
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
        HStack(spacing: 10) {
            if !reducer.items.isEmpty {
                Button { showOutline = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline)
                }
                .accessibilityLabel("Open session outline")
                .accessibilityIdentifier("chat.toolbar.outline")
            }

            contextRingButton
                .padding(.horizontal, 4)
                .padding(.trailing, 4)
        }
    }

    private var contextRingButton: some View {
        Button {
            if suppressNextContextTap {
                suppressNextContextTap = false
                return
            }
            triggerToolbarHaptic(style: .soft, intensity: 0.55)
            showContextInspector = true
        } label: {
            ContextUsageRingBadge(
                usage: contextUsageSnapshot
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.toolbar.context")
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    suppressNextContextTap = true
                    triggerToolbarHaptic(style: .rigid, intensity: 0.75)
                    showCompactConfirmation = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.6))
                        suppressNextContextTap = false
                    }
                }
        )
        .accessibilityLabel("Open context inspector")
        .accessibilityHint("Long press to compact context")
    }

    private var chatPrincipalTitleMaxWidth: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        let reservedChromeWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 220 : 178
        let upperBound: CGFloat = dynamicTypeSize.isAccessibilitySize ? 260 : 320
        return max(132, min(upperBound, screenWidth - reservedChromeWidth))
    }

    private var sessionTitleLabel: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
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
                await saveReviewComment(body: body, request: request)
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
        inputText = ""
        composerTextBeforeRecording = nil
        pendingAttachments = []
        pendingRepoPointers = []
        composerExternalFocusRequestID &+= 1
        contextBarCollapseToken &+= 1
    }

    private func applyQuickCommentTemplate(_ template: QuickCommentTemplate) {
        let text = template.quickCommentText
        guard !text.isEmpty else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            inputText = text
        } else if inputText.hasSuffix("\n") {
            inputText += text
        } else {
            inputText += "\n" + text
        }
        composerExternalFocusRequestID &+= 1
    }

    private func cancelReviewCommentInput() {
        activeReviewCommentRequest = nil
        inputText = ""
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
                  currentText: inputText
              ) else {
            return false
        }

        inputText = plan.text
        composerTextBeforeRecording = nil
        messageQueueStore.apply(plan.clearedQueue, for: sessionId)
        if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
        return true
    }

    private func sendActiveReviewComment() {
        guard let request = activeReviewCommentRequest else { return }
        let body = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task { @MainActor in
            let didSave = await saveReviewComment(body: body, request: request)
            if didSave {
                activeReviewCommentRequest = nil
                inputText = ""
                composerTextBeforeRecording = nil
                await loadReviewCommentsIfPossible()
            }
        }
    }

    private func presentComposer() {
        showComposer = true
    }

    @MainActor
    private func stageWorkspaceReviewInCurrentSession(prompt: String, files: [PendingFileReference]) {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = prompt
        } else if inputText.hasSuffix("\n\n") {
            inputText += prompt
        } else if inputText.hasSuffix("\n") {
            inputText += "\n" + prompt
        } else {
            inputText += "\n\n" + prompt
        }

        for file in files where !pendingRepoPointers.contains(where: { $0.id == file.id }) {
            pendingRepoPointers.append(file)
        }

        if isStopped {
            showComposer = true
        } else if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    @MainActor
    private func applyExtensionEditorText(_ text: String) {
        inputText = text
        if isStopped {
            showComposer = true
        } else if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    private func loadReviewCommentsIfPossible() async {
        await reviewComments.load(api: connection.apiClient, workspaceId: session?.workspaceId, sessionId: sessionId)
    }

    @discardableResult
    private func saveReviewComment(body: String, request: ReviewCommentSelectionRequest) async -> Bool {
        if let error = await reviewComments.save(
            body: body,
            request: request,
            api: connection.apiClient,
            workspaceId: session?.workspaceId,
            sessionId: sessionId
        ) {
            connection.extensionToast = error
            return false
        }
        return true
    }

    private func deleteReviewComment(_ comment: ReviewComment) async {
        if let error = await reviewComments.delete(comment, api: connection.apiClient) {
            connection.extensionToast = error
        }
    }

    private func markReviewCommentsSentIfPossible(ids: [String]) {
        Task {
            if let error = await reviewComments.markSent(
                ids: ids,
                api: connection.apiClient,
                workspaceId: session?.workspaceId,
                sessionId: sessionId
            ) {
                connection.extensionToast = error
            }
        }
    }

    private func triggerToolbarHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let feedback = UIImpactFeedbackGenerator(style: style)
        feedback.prepare()
        feedback.impactOccurred(intensity: intensity)
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
    private func handleAppear() {
        // Re-establish command routing immediately on re-entry.
        // The async sessionManager.connect() task starts shortly after onAppear,
        // but users can tap toolbar controls before that task has a chance to
        // refocus the connection on this session.
        connection.prepareForSessionReentry(sessionId, workspaceIdHint: workspaceIdHint)

        sessionManager.markAppeared()
        voiceInputManager.loadPreferences()
        if sessionManager.hasAppeared, let draft = chatState.composerDraft, !draft.isEmpty {
            inputText = draft
            chatState.composerDraft = nil
        }
        // Load initial git status for the workspace
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            let ws = connection.workspaceStore.workspaces.first { $0.id == wsId }
            gitStatusStore.loadInitial(
                workspaceId: wsId,
                apiClient: api,
                gitStatusEnabled: ws?.gitStatusEnabled ?? true
            )
        }
        // Pre-load file index for @file fuzzy search
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            fileIndexStore.ensureLoaded(workspaceId: wsId, apiClient: api)
        }
    }

    @MainActor
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            sessionManager.coalescer.pause()
            Task {
                await sessionManager.flushSnapshotIfNeeded(connection: connection)
            }
        case .active:
            sessionManager.coalescer.resume()
        default:
            break
        }
    }

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
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func uploadPendingLocalAttachments() async throws -> [ChatAttachmentRef] {
        let localAttachments = pendingAttachments.filter { $0.source == .image || $0.source == .localFile }
        guard !localAttachments.isEmpty else { return [] }
        guard let workspaceId = session?.workspaceId else {
            throw APIError.server(status: 400, message: "Attachments require a workspace-backed session")
        }
        guard let api = connection.apiClient else {
            throw APIError.server(status: 503, message: "No server connection available")
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
                workspaceId: workspaceId,
                sessionId: sessionId,
                name: payload.name,
                mimeType: payload.mimeType,
                sizeBytes: payload.data.count
            )
            let attachment = try await api.uploadSessionAttachmentContent(
                workspaceId: workspaceId,
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
        let rawTrimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTrimmedInput.caseInsensitiveCompare("/reload") == .orderedSame {
            inputText = ""
            actionHandler.reloadResources(
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId
            )
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/share") == .orderedSame {
            sendShareSlashCommand(clearComposer: true, restoreInputOnFailure: inputText)
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/review-comments") == .orderedSame {
            inputText = ""
            connection.extensionToast = "Review comments use compact inline selection now."
            return
        }

        guard !isPreparingAttachments, !actionHandler.isSending else { return }

        let originalInputText = inputText
        let originalPendingAttachments = pendingAttachments
        let originalPendingRepoPointers = pendingRepoPointers
        let reviewText = reviewComments.appendReviewBlock(to: inputText)
        let text = PendingFileReference.appendReferenceBlock(to: reviewText, files: pendingRepoPointers)
        let stagedReviewCommentIds = reviewComments.stagedCommentIds
        let sessionManagerRef = sessionManager
        let scrollRef = scrollController

        Task { @MainActor in
            do {
                let pendingLocalAttachments = pendingAttachments.filter { $0.source == .image || $0.source == .localFile }
                isPreparingAttachments = true
                attachmentPreparationText = pendingLocalAttachments.isEmpty ? nil : "Uploading attachments…"

                let uploadedAttachments = try await self.uploadPendingLocalAttachments()
                let attachments = uploadedAttachments
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
                        inputText = ""
                        pendingAttachments = []
                        pendingRepoPointers = []

                        // Scroll to bottom after sending
                        scrollRef.requestScrollToBottom()
                    },
                    onSendSucceeded: {
                        markReviewCommentsSentIfPossible(ids: stagedReviewCommentIds)
                    },
                    onAsyncFailure: { _, failedAttachments in
                        inputText = originalInputText
                        pendingAttachments = originalPendingAttachments
                        pendingRepoPointers = originalPendingRepoPointers
                    },
                    onNeedsReconnect: {
                        sessionManagerRef.reconnect()
                    }
                )
                if !restored.isEmpty {
                    inputText = restored
                }
            } catch {
                isPreparingAttachments = false
                attachmentPreparationText = nil
                pendingAttachments = originalPendingAttachments
                pendingRepoPointers = originalPendingRepoPointers
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

    private func sendShareSlashCommand(clearComposer: Bool, restoreInputOnFailure: String?) {
        guard hasShareSlashCommand else {
            reducer.process(
                .error(sessionId: sessionId, message: "Share command is not enabled for this workspace.")
            )
            return
        }

        let sessionManagerRef = sessionManager
        let policy = AppPreferences.Share.redactionPolicy

        actionHandler.shareSession(
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            redactionPolicy: policy,
            onDispatchStarted: {
                guard clearComposer else { return }
                inputText = ""
                pendingAttachments = []
                pendingRepoPointers = []
            },
            onAsyncFailure: {
                if let restoreInputOnFailure {
                    inputText = restoreInputOnFailure
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
            changedFiles: session?.changeStats?.changedFiles ?? [],
            onSelect: { targetID in
                scrollController.scrollTargetID = targetID
            },
            onFork: forkFromMessage,
            fileDetailReviewCommentScope: .activeSession(reviewCommentSelectionRouter),
            onNavigateTreeNode: { request in
                try await navigateFromTree(request)
            },
            loadTree: { filterMode in
                try await connection.getSessionTree(filterMode: filterMode)
            }
        )
    }

    private var reviewCommentStashSheet: some View {
        ReviewCommentStashSheet(
            comments: reviewComments.stagedComments,
            focusedCommentId: focusedReviewCommentId,
            onDelete: { comment in
                Task { await deleteReviewComment(comment) }
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
        inputText = viewUpdate.inputText
        pendingAttachments = []
        pendingRepoPointers = []

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
                ToolbarItem(placement: .confirmationAction) {
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
            text: $inputText,
            textBeforeRecording: $composerTextBeforeRecording,
            pendingAttachments: $pendingAttachments,
            pendingRepoPointers: $pendingRepoPointers,
            isBusy: isBusy,
            busyStreamingBehavior: busyStreamingBehavior,
            slashCommands: chatState.slashCommands,
            fileSuggestions: chatState.fileSuggestions,
            onFileSuggestionQuery: { query in
                updateFileSuggestions(query: query)
            },
            session: session,
            thinkingLevel: chatState.thinkingLevel,
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
            onSend: sendPrompt,
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
            }
        }
    }
}
