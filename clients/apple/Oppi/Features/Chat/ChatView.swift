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

struct ChatView: View {
    let sessionId: String

    @Environment(ServerConnection.self) private var connection
    @Environment(ChatSessionState.self) private var chatState
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayerService.self) private var audioPlayer
    @Environment(GitStatusStore.self) private var gitStatusStore
    @Environment(FileIndexStore.self) private var fileIndexStore
    @Environment(MessageQueueStore.self) private var messageQueueStore
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(PiQuickActionStore.self) private var piQuickActionStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var showModelSwitchWarning = false
    @State private var pendingModelSwitch: ModelInfo?
    @State private var showComposer = false
    @State private var childSessionToOpen: ChildSessionRoute?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var copiedSessionID = false
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

    init(sessionId: String, initialInputText: String = "", initialPendingFiles: [PendingFileReference] = []) {
        self.sessionId = sessionId
        _sessionManager = State(initialValue: ChatSessionManager(sessionId: sessionId))
        _inputText = State(initialValue: initialInputText)
        _pendingRepoPointers = State(initialValue: initialPendingFiles)
    }

    private struct ForkRoute: Identifiable, Hashable {
        let id: String
    }

    private struct ChildSessionRoute: Identifiable, Hashable {
        let id: String
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

    /// Child sessions spawned by this session.
    private var childSessions: [Session] {
        SessionTreeHelper.sortedChildSessions(of: sessionId, in: sessionStore.sessions)
    }

    private var hasShareSlashCommand: Bool {
        chatState.slashCommands.contains { command in
            command.name.caseInsensitiveCompare("share") == .orderedSame
        }
    }

    /// Parent session (when this is a spawned child).
    private var parentSession: Session? {
        guard let parentId = session?.parentSessionId else { return nil }
        return sessionStore.sessions.first { $0.id == parentId }
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
            currentModel: session?.model,
            connection: connection,
            scrollController: scrollController,
            sessionManager: sessionManager,
            audioLifecycleCoordinator: audioLifecycleCoordinator,
            onFork: forkFromMessage,
            selectedTextPiRouter: selectedTextPiRouter,
            piQuickActionStore: piQuickActionStore,
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
                    childSessions: childSessions,
                    onSelectChild: { childId in
                        childSessionToOpen = ChildSessionRoute(id: childId)
                    },
                    fileDetailActionScope: .activeSession(selectedTextPiRouter),
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
            .sheet(isPresented: $showOutline) { outlineSheet }
            .sheet(isPresented: $showModelPicker) { modelPickerSheet }
            .sheet(isPresented: $showContextInspector) { contextInspectorSheet }
            .sheet(isPresented: $showShareRedactionSheet) { shareRedactionSheet }
            .sheet(isPresented: reviewCommentsSheetBinding) { reviewCommentsSheet }
            .sheet(item: reviewCommentDraftBinding) { context in
                ReviewCommentComposerSheet(
                    selectedText: context.request.selectedText,
                    source: context.request.source,
                    voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                    quickComments: PiQuickAction.quickCommentTemplates(piQuickActionStore.actions),
                    onCancel: { reviewComments.pendingDraft = nil },
                    onSave: { body in
                        await saveReviewComment(body: body, request: context.request)
                    }
                )
            }
            .fullScreenCover(isPresented: $showComposer) { composerSheet }
            .alert("Rename Session", isPresented: $showRenameAlert) { renameAlert }
            .alert("Switch model in active session?", isPresented: $showModelSwitchWarning) {
                Button("Keep Current", role: .cancel) {
                    pendingModelSwitch = nil
                }
                Button("Switch Anyway") {
                    applyPendingModelSwitch()
                }
            } message: {
                Text(pendingModelSwitchWarningMessage)
            }
            .alert("Compact Context", isPresented: $showCompactConfirmation) {
                Button("Compact", role: .destructive) {
                    actionHandler.compact(connection: connection, reducer: reducer, sessionId: sessionId)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will summarize the conversation to free up context window space. The summary replaces earlier messages.")
            }
            .task(id: connectionTaskKey) {
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
            .task(id: session?.workspaceId ?? "") {
                await loadReviewCommentsIfPossible()
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
            }
            .onChange(of: chatState.extensionEditorTextUpdate?.revision) { _, _ in
                handleExtensionEditorTextUpdate()
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
                audioPlayer.stop()
                if connection.isFocusedSession(oldId) {
                    connection.disconnectSession()
                }

                // Stand up new session
                sessionManager = ChatSessionManager(sessionId: newId)
                scrollController = ChatScrollController()
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
                audioPlayer.stop()
                let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                chatState.composerDraft = draft.isEmpty ? nil : draft
                Task {
                    await sessionManager.flushSnapshotIfNeeded(connection: connection, force: true)
                }
                disconnectIfCurrentSession()
            }
    }

    private var configuredChatContent: some View {
        configuredChatToolbarContent
    }

    private var configuredChatToolbarContent: some View {
        configuredChatNavigationContent
            .toolbar(.hidden, for: .tabBar)
            .toolbar(.hidden, for: .bottomBar)
            .toolbar(.visible, for: .navigationBar)
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
                Self(sessionId: route.id)
            }
            .navigationDestination(item: $childSessionToOpen) { route in
                Self(sessionId: route.id)
            }
    }

    @ViewBuilder
    private var footerArea: some View {
        if isStopped {
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
        } else {
            VStack(spacing: 8) {
                if let surface = extensionSurfaceState,
                   surface.hasVisibleContent {
                    ExtensionSurfacePanel(surface: surface)
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
                    .background(Color.themeRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

                if reviewComments.stagedCount > 0 {
                    ReviewCommentChip(stagedCount: reviewComments.stagedCount) {
                        reviewComments.openSheet()
                    }
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
                    pendingReviewCommentCount: reviewComments.stagedCount,
                    sendProgressText: attachmentPreparationText ?? actionHandler.sendProgressText,
                    isStopping: isStopping,
                    voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                    showForceStop: actionHandler.showForceStop,
                    isForceStopInFlight: actionHandler.isForceStopInFlight,
                    askRequest: connection.activeAskRequest,
                    onAskSubmit: { answers in
                        guard let ask = connection.activeAskRequest else { return }
                        let value = AskResponseEncoder.encode(answers)
                        Task {
                            do {
                                try await connection.respondToExtensionUI(id: ask.id, sessionId: ask.sessionId, value: value)
                            } catch {
                                // Keep the ask card visible so the user can retry.
                            }
                        }
                    },
                    onAskIgnoreAll: {
                        guard let ask = connection.activeAskRequest else { return }
                        Task {
                            do {
                                try await connection.respondToExtensionUI(id: ask.id, sessionId: ask.sessionId, cancelled: true)
                            } catch {
                                // Keep the ask card visible so the user can retry.
                            }
                        }
                    },

                    slashCommands: chatState.slashCommands,
                    fileSuggestions: chatState.fileSuggestions,
                    onFileSuggestionQuery: { query in
                        updateFileSuggestions(query: query)
                    },
                    onSend: sendPrompt,
                    onStop: {
                        actionHandler.stop(
                            connection: connection, reducer: reducer,
                            sessionStore: sessionStore, sessionManager: sessionManager,
                            sessionId: sessionId
                        )
                    },
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
                )
            }
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

    private var sessionTitleLabel: some View {
        VStack(spacing: 1) {
            if let parent = parentSession {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.system(size: 8, weight: .semibold))
                    Text(parent.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption2)
                .foregroundStyle(.themeComment)
            }

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

                Image(systemName: copiedSessionID ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copiedSessionID ? .themeGreen : .themeComment)
                    .fixedSize()
            }
        }
    }

    private var selectedTextPiRouter: SelectedTextPiActionRouter {
        SelectedTextPiActionRouter { request in
            handleSelectedTextPiAction(request)
        }
    }

    static func routeForSelectedTextPiAction(_ request: SelectedTextPiRequest) -> SelectedTextPiRoute? {
        SelectedTextPiRouterPolicy.route(request: request, context: .activeChat)
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
    private func handleSelectedTextPiAction(_ request: SelectedTextPiRequest) {
        guard let route = Self.routeForSelectedTextPiAction(request) else { return }

        switch route {
        case .reviewComment(let request):
            reviewComments.beginComment(request)

        case .quickSessionDraft(let addition):
            appNavigation.pendingQuickSessionDraft = addition
            appNavigation.showQuickSession = true

        case .currentSessionDraft(let addition):
            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = addition
            } else if inputText.hasSuffix("\n\n") {
                inputText += addition
            } else if inputText.hasSuffix("\n") {
                inputText += "\n" + addition
            } else {
                inputText += "\n\n" + addition
            }

            if isStopped {
                showComposer = true
            } else if !showComposer {
                composerExternalFocusRequestID &+= 1
            }
        }
    }

    private func presentComposer() {
        showComposer = true
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

    private var reviewCommentsSheetBinding: Binding<Bool> {
        Binding(
            get: { reviewComments.showsSheet },
            set: { reviewComments.showsSheet = $0 }
        )
    }

    private var reviewCommentDraftBinding: Binding<ReviewCommentDraftContext?> {
        Binding(
            get: { reviewComments.pendingDraft },
            set: { reviewComments.pendingDraft = $0 }
        )
    }

    private var reviewCommentsSheet: some View {
        ReviewCommentsSheet(
            comments: reviewComments.comments,
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
            onRefresh: {
                Task { await loadReviewCommentsIfPossible() }
            },
            onClose: {
                reviewComments.closeSheet()
            },
            onUpdateBody: { comment, body in
                await updateReviewComment(comment, body: body)
            },
            onDelete: { comment in
                Task { await deleteReviewComment(comment) }
            },
            onResolve: { comment in
                Task { await updateReviewComment(comment, status: .resolved) }
            }
        )
        .presentationDetents([.medium, .large])
    }

    private func loadReviewCommentsIfPossible() async {
        await reviewComments.load(api: connection.apiClient, workspaceId: session?.workspaceId, sessionId: sessionId)
    }

    @discardableResult
    private func saveReviewComment(body: String, request: SelectedTextPiRequest) async -> Bool {
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

    @discardableResult
    private func updateReviewComment(
        _ comment: ReviewComment,
        body: String? = nil,
        status: ReviewCommentStatus? = nil
    ) async -> Bool {
        if let error = await reviewComments.update(
            comment,
            body: body,
            status: status,
            api: connection.apiClient,
            workspaceId: session?.workspaceId
        ) {
            connection.extensionToast = error
            return false
        }
        return true
    }

    private func deleteReviewComment(_ comment: ReviewComment) async {
        if let error = await reviewComments.delete(comment, api: connection.apiClient, workspaceId: session?.workspaceId) {
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
    private func handleAppear() {
        // Re-establish command routing immediately on re-entry.
        // The async sessionManager.connect() task starts shortly after onAppear,
        // but users can tap toolbar controls before that task has a chance to
        // refocus the connection on this session.
        connection.prepareForSessionReentry(sessionId)

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

    private var pendingModelSwitchWarningMessage: String {
        guard let pendingModelSwitch else {
            return "Switching now invalidates prompt caching for this conversation, which can increase cost and latency. Prefer switching when starting a new session."
        }
        let modelName = shortModelName(ModelSwitchPolicy.fullModelID(for: pendingModelSwitch))
        return "Switching to \(modelName) now invalidates prompt caching for this conversation, which can increase cost and latency. Prefer switching when starting a new session."
    }

    @MainActor
    private func applyPendingModelSwitch() {
        guard let model = pendingModelSwitch else { return }
        applyModelSelection(model)
        pendingModelSwitch = nil
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
    private func handleSessionStatusChange(_ newStatus: SessionStatus?) {
        if newStatus != .stopping {
            actionHandler.resetStopState()
            sessionManager.cancelReconciliation()
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

        var uploaded: [ChatAttachmentRef] = []
        for (index, pending) in localAttachments.enumerated() {
            attachmentPreparationText = "Uploading attachment \(index + 1) of \(localAttachments.count)…"

            let payload: (data: Data, mimeType: String, name: String)
            switch pending.source {
            case .image:
                guard let imageAttachment = pending.imageAttachment,
                      let data = Data(base64Encoded: imageAttachment.data, options: .ignoreUnknownCharacters) else {
                    throw APIError.server(status: 400, message: "Invalid pending image data")
                }
                let name = pending.displayName.lowercased().hasSuffix(".jpg") ? pending.displayName : "image-\(index + 1).jpg"
                payload = (data, imageAttachment.mimeType, name)
            case .localFile:
                guard let data = pending.localFileData,
                      let mimeType = pending.localMimeType else {
                    throw APIError.server(status: 400, message: "Invalid pending file data")
                }
                payload = (data, mimeType, pending.displayName)
            }

            let upload = try await api.createUpload(
                workspaceId: workspaceId,
                name: payload.name,
                mimeType: payload.mimeType,
                sizeBytes: payload.data.count
            )
            let attachment = try await api.uploadAttachmentContent(
                workspaceId: workspaceId,
                uploadId: upload.uploadId,
                data: payload.data,
                contentType: payload.mimeType
            )
            uploaded.append(attachment)
        }
        return uploaded
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

    private func sendPrompt() {
        let rawTrimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTrimmedInput.caseInsensitiveCompare("/share") == .orderedSame {
            sendShareSlashCommand(clearComposer: true, restoreInputOnFailure: inputText)
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/review-comments") == .orderedSame {
            inputText = ""
            reviewComments.openSheet()
            Task { await loadReviewCommentsIfPossible() }
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
        case .requireConfirmation:
            pendingModelSwitch = model
            showModelSwitchWarning = true
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
        copiedSessionID = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copiedSessionID = false
        }
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
            fileDetailActionScope: .activeSession(selectedTextPiRouter),
            onNavigateTreeNode: { request in
                try await navigateFromTree(request)
            },
            loadTree: { filterMode in
                try await connection.getSessionTree(filterMode: filterMode)
            }
        )
        .presentationDetents([.medium, .large])
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

                forkedSessionToOpen = ForkRoute(id: forked.id)
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Fork failed: \(error.localizedDescription)"))
            }
        }
    }

    private var currentWorkspace: Workspace? {
        guard let wsId = session?.workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == wsId }
    }

    private var currentWorkspaceSkillNames: [String] {
        currentWorkspace?.skills ?? []
    }

    private var contextInspectorSheet: some View {
        NavigationStack {
            ContextInspectorView(
                session: session,
                workspace: currentWorkspace,
                workspaceSkillNames: currentWorkspaceSkillNames,
                availableSkills: connection.workspaceStore.skills,
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
        .presentationDetents([.medium, .large])
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

private struct ExtensionSurfacePanel: View {
    let surface: ExtensionSurfaceState

    private var sortedStatuses: [(key: String, text: String)] {
        surface.statuses
            .map { (key: $0.key, text: $0.value) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private var sortedWidgets: [ExtensionWidgetState] {
        surface.widgets
            .values
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = surface.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }

            ForEach(sortedStatuses, id: \.key) { status in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(status.key)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.themeFg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ForEach(sortedWidgets, id: \.key) { widget in
                if !widget.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if sortedWidgets.count > 1 {
                            Text(widget.key)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.themeComment)
                        }
                        Text(widget.lines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.themeFg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.themeComment.opacity(0.25), lineWidth: 1)
        }
    }
}
