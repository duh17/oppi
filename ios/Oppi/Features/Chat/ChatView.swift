import SwiftUI
import UIKit

struct ChatView: View {
    let sessionId: String

    @Environment(ServerConnection.self) private var connection
    @Environment(ChatSessionState.self) private var chatState
    @Environment(SessionStore.self) private var sessionStore
    @Environment(TimelineReducer.self) private var reducer
    @Environment(AudioPlayerService.self) private var audioPlayer
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(PiQuickActionStore.self) private var piQuickActionStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var sessionManager: ChatSessionManager
    @State private var scrollController = ChatScrollController()
    @State private var actionHandler = ChatActionHandler()
    @State private var voiceInputManager = VoiceInputManager()

    @State private var inputText = ""
    @State private var pendingImages: [PendingImage] = []
    @State private var pendingFiles: [PendingFileReference] = []
    @State private var contextPills: [ContextPill]
    @State private var busyStreamingBehavior: StreamingBehavior = .steer

    @State private var showOutline = false
    @State private var showModelPicker = false
    @State private var showModelSwitchWarning = false
    @State private var pendingModelSwitch: ModelInfo?
    @State private var showComposer = false
    @State private var subagentBarExpanded = false
    @State private var childSessionToOpen: ChildSessionRoute?
    @State private var parentSessionToOpen: ParentSessionRoute?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var copiedSessionID = false
    @State private var forkedSessionToOpen: ForkRoute?
#if DEBUG
    @State private var uploadingClientLogs = false
#endif
    @State private var showCompactConfirmation = false
    @State private var showContextInspector = false
    @State private var suppressNextContextTap = false
    @State private var isKeyboardVisible = false
    @State private var footerHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var composerExternalFocusRequestID = 0
    @State private var contextBarCollapseToken = 0
    @State private var contextBarExpanded = false
    @State private var contextPillDetailFile: WorkspaceReviewFile?

    init(sessionId: String, initialInputText: String = "", initialContextPills: [ContextPill] = []) {
        self.sessionId = sessionId
        _sessionManager = State(initialValue: ChatSessionManager(sessionId: sessionId))
        _inputText = State(initialValue: initialInputText)
        _contextPills = State(initialValue: initialContextPills)
    }

    private struct ForkRoute: Identifiable, Hashable {
        let id: String
    }

    private struct ChildSessionRoute: Identifiable, Hashable {
        let id: String
    }

    private struct ParentSessionRoute: Identifiable, Hashable {
        let id: String
    }

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    /// Child sessions spawned by this session.
    private var childSessions: [Session] {
        sessionStore.sessions.filter { $0.parentSessionId == sessionId }.sorted(by: { $0.createdAt < $1.createdAt })
    }

    /// The parent session, if this session was spawned by another.
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
        connection.messageQueueStore.queue(for: sessionId)
    }

    private var showsMessageQueue: Bool {
        !messageQueueState.steering.isEmpty || !messageQueueState.followUp.isEmpty
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
    }

    private var chatTimeline: some View {
        ChatTimelineView(
            sessionId: sessionId,
            workspaceId: session?.workspaceId,
            isBusy: isBusy,
            scrollController: scrollController,
            sessionManager: sessionManager,
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
                // Dismiss layer: tap anywhere outside the bar to collapse it
                if contextBarExpanded {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { contextBarCollapseToken &+= 1 }
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    WorkspaceContextBar(
                        gitStatus: connection.gitStatusStore.gitStatus,
                        isLoading: connection.gitStatusStore.isLoading,
                        workspaceId: session?.workspaceId,
                        sessionId: sessionId,
                        collapseToken: contextBarCollapseToken,
                        onExpandedChanged: { contextBarExpanded = $0 }
                    )

                    if let parent = parentSession {
                        ParentBreadcrumb(parentSession: parent) {
                            parentSessionToOpen = ParentSessionRoute(id: parent.id)
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                footerArea
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
            .overlay(alignment: .bottomTrailing) {
                if scrollController.isJumpToBottomHintVisible {
                    JumpToBottomHintButton(isStreaming: scrollController.isDetachedStreamingHintVisible) {
                        scrollController.requestScrollToBottom()
                    }
                    .padding(.trailing, 27)
                    .padding(.bottom, footerHeight + 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: scrollController.isJumpToBottomHintVisible)
            .onChange(of: scrollController.isJumpToBottomHintVisible) { _, visible in
                if visible { contextBarCollapseToken &+= 1 }
            }
    }

    private var chatContent: some View {
        configuredChatContent
            .sheet(isPresented: $showOutline) { outlineSheet }
            .sheet(isPresented: $showModelPicker) { modelPickerSheet }
            .sheet(isPresented: $showContextInspector) { contextInspectorSheet }
            .sheet(item: $contextPillDetailFile) { file in
                contextPillDetailSheet(file: file)
            }
            .fullScreenCover(isPresented: $showComposer) { composerSheet }
            .alert("Rename Session", isPresented: $showRenameAlert) { renameAlert }
            .alert("Switch model in active session?", isPresented: $showModelSwitchWarning, presenting: pendingModelSwitch) { model in
                Button("Keep Current", role: .cancel) {
                    pendingModelSwitch = nil
                }
                Button("Switch Anyway") {
                    applyModelSelection(model)
                    pendingModelSwitch = nil
                }
            } message: { model in
                Text("Switching to \(shortModelName(ModelSwitchPolicy.fullModelID(for: model))) now invalidates prompt caching for this conversation, which can increase cost and latency. Prefer switching when starting a new session.")
            }
            .alert("Compact Context", isPresented: $showCompactConfirmation) {
                Button("Compact", role: .destructive) {
                    actionHandler.compact(connection: connection, reducer: reducer, sessionId: sessionId)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will summarize the conversation to free up context window space. The summary replaces earlier messages.")
            }
            .task(id: sessionManager.connectionGeneration) {
                await sessionManager.connect(
                    connection: connection,
                    reducer: reducer,
                    sessionStore: sessionStore
                )
            }
            .task {
                // Pre-warm voice input pipeline in background (model check + transcriber creation)
                if ReleaseFeatures.voiceInputEnabled {
                    await voiceInputManager.prewarm(source: "chat_view_task")
                }
            }
            .task {
                // Auto-send pending message from QuickSessionSheet.
                // Pre-fill immediately, wait for connection, then dispatch.
                guard let message = appNavigation.pendingQuickSessionMessage else { return }
                let images = appNavigation.pendingQuickSessionImages ?? []

                // Consume immediately so it doesn't re-fire
                appNavigation.pendingQuickSessionMessage = nil
                appNavigation.pendingQuickSessionImages = nil

                // Pre-fill the composer so the user sees their message while connecting
                inputText = message
                pendingImages = images

                // Wait for the session stream to be established (max 10s)
                let deadline = ContinuousClock.now + .seconds(10)
                while sessionManager.entryState != .streaming {
                    if Task.isCancelled { return }
                    if ContinuousClock.now >= deadline { return } // Timeout — user can send manually
                    try? await Task.sleep(for: .milliseconds(100))
                }

                // Brief settle for UI
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }

                // Auto-send through the normal WebSocket flow
                sendPrompt()
            }
            .onAppear {
                sessionManager.markAppeared()
                voiceInputManager.loadPreferences()
                if sessionManager.hasAppeared, let draft = chatState.composerDraft, !draft.isEmpty {
                    inputText = draft
                    chatState.composerDraft = nil
                }
                // Load initial git status for the workspace
                if let wsId = session?.workspaceId, let api = connection.apiClient {
                    let ws = connection.workspaceStore.workspaces.first { $0.id == wsId }
                    connection.gitStatusStore.loadInitial(
                        workspaceId: wsId,
                        apiClient: api,
                        gitStatusEnabled: ws?.gitStatusEnabled ?? true
                    )
                }
                // Pre-load file index for @file fuzzy search
                if let wsId = session?.workspaceId, let api = connection.apiClient {
                    connection.fileIndexStore.ensureLoaded(workspaceId: wsId, apiClient: api)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
                contextBarCollapseToken &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onChange(of: session?.status) { _, newStatus in
                if newStatus != .stopping {
                    actionHandler.resetStopState()
                    sessionManager.cancelReconciliation()
                }

                if newStatus == .busy {
                    Task {
                        try? await connection.requestMessageQueue()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    connection.coalescer.pause()
                    Task {
                        await sessionManager.flushSnapshotIfNeeded(connection: connection)
                    }
                case .active:
                    connection.coalescer.resume()
                default:
                    break
                }
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
                if connection.activeSessionId == sessionId
                    || connection.activeSessionId == nil {
                    connection.disconnectSession()
                }
            }
    }

    private var configuredChatContent: some View {
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
        .navigationDestination(item: $parentSessionToOpen) { route in
            Self(sessionId: route.id)
        }
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
                if showsMessageQueue {
                    MessageQueueContainer(
                        queue: messageQueueState,
                        busyStreamingBehavior: $busyStreamingBehavior,
                        onApply: { baseVersion, steering, followUp in
                            try await connection.setMessageQueue(
                                baseVersion: baseVersion,
                                steering: steering,
                                followUp: followUp
                            )
                        },
                        onRefresh: {
                            try? await connection.requestMessageQueue()
                        }
                    )
                    .padding(.horizontal, 16)
                }

                SubagentStatusBar(
                    childSessions: childSessions,
                    isExpanded: $subagentBarExpanded,
                    onSelectChild: { childId in
                        childSessionToOpen = ChildSessionRoute(id: childId)
                    }
                )

                ChatInputBar(
                    text: $inputText,
                    pendingImages: $pendingImages,
                    pendingFiles: $pendingFiles,
                    contextPills: contextPills,
                    onContextPillTap: session?.workspaceId != nil ? { pill in
                        contextPillDetailFile = pill.toReviewFile()
                    } : nil,
                    isBusy: isBusy,
                    busyStreamingBehavior: $busyStreamingBehavior,
                    isSending: actionHandler.isSending,
                    sendProgressText: actionHandler.sendProgressText,
                    isStopping: isStopping,
                    voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                    showForceStop: actionHandler.showForceStop,
                    isForceStopInFlight: actionHandler.isForceStopInFlight,
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
#if DEBUG
        .contextMenu {
            Button("Copy Session ID", systemImage: "doc.on.doc") {
                copySessionID()
            }
            Button(uploadingClientLogs ? "Uploading Client Logs…" : "Upload Client Logs", systemImage: "arrow.up.doc") {
                uploadClientLogs()
            }
            .disabled(uploadingClientLogs)
        }
#endif
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
        HStack(spacing: 6) {
            Text(sessionDisplayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .truncationMode(.tail)

            if let cost = session?.cost, cost > 0 {
                Text(String(format: "$%.2f", cost))
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

    private var selectedTextPiRouter: SelectedTextPiActionRouter {
        SelectedTextPiActionRouter { request in
            handleSelectedTextPiAction(request)
        }
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
        // "New Session" actions always route through the quick session sheet,
        // even when triggered from inside an active chat.
        if request.action.behavior == .newSession {
            let addition = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            guard !addition.isEmpty else { return }
            appNavigation.pendingQuickSessionDraft = addition
            appNavigation.showQuickSession = true
            return
        }

        let addition = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        guard !addition.isEmpty else { return }

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

    private func presentComposer() {
        showComposer = true
    }

    private func triggerToolbarHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let feedback = UIImpactFeedbackGenerator(style: style)
        feedback.prepare()
        feedback.impactOccurred(intensity: intensity)
    }

    private func sendPrompt() {
        // Inject pending file references as @path prefixes
        var text = inputText
        if !pendingFiles.isEmpty {
            let fileRefs = pendingFiles.map { "@\($0.path)" }.joined(separator: " ")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed.isEmpty ? fileRefs : "\(fileRefs) \(trimmed)"
        }
        let images = pendingImages

        let reducerRef = reducer
        let sessionManagerRef = sessionManager
        let scrollRef = scrollController

        let restored = actionHandler.sendPrompt(
            text: text,
            images: images,
            isBusy: isBusy,
            busyStreamingBehavior: busyStreamingBehavior,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            sessionStore: sessionStore,
            onDispatchStarted: {
                inputText = ""
                pendingImages = []
                pendingFiles = []
                contextPills = []
                // Scroll to bottom after sending
                scrollRef.requestScrollToBottom()
            },
            onAsyncFailure: { failedText, failedImages in
                inputText = failedText
                pendingImages = failedImages
            },
            onNeedsReconnect: {
                reducerRef.appendSystemEvent("Connection dropped — reconnecting…")
                sessionManagerRef.reconnect()
            }
        )
        if !restored.isEmpty {
            inputText = restored
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
        RecentModels.record(ModelSwitchPolicy.fullModelID(for: model))
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

#if DEBUG
    private func uploadClientLogs() {
        guard !uploadingClientLogs else { return }
        guard let api = connection.apiClient else {
            reducer.process(.error(sessionId: sessionId, message: "No API client available"))
            return
        }
        guard let workspaceId = session?.workspaceId, !workspaceId.isEmpty else {
            reducer.process(.error(sessionId: sessionId, message: "Missing workspace context"))
            return
        }

        uploadingClientLogs = true
        ClientLog.info("ChatView", "Manual client log upload requested", metadata: [
            "sessionId": sessionId,
        ])

        Task { @MainActor in
            defer { uploadingClientLogs = false }

            let entries = await ClientLogBuffer.shared.snapshot(limit: 800, sessionId: sessionId)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let request = ClientLogUploadRequest(
                generatedAt: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
                trigger: "manual-toolbar",
                appVersion: version,
                buildNumber: build,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceModel: UIDevice.current.model,
                entries: entries
            )

            do {
                try await api.uploadClientLogs(workspaceId: workspaceId, sessionId: sessionId, request: request)
                reducer.appendSystemEvent("Uploaded \(entries.count) client log entries")
                ClientLog.info("ChatView", "Client log upload succeeded", metadata: [
                    "sessionId": sessionId,
                    "entries": String(entries.count),
                ])
            } catch {
                let message = "Client log upload failed: \(error.localizedDescription)"
                reducer.process(.error(sessionId: sessionId, message: message))
                ClientLog.error("ChatView", message, metadata: ["sessionId": sessionId])
            }
        }
    }
#endif

    // MARK: - Sheets & Alerts

    @ViewBuilder
    private func contextPillDetailSheet(file: WorkspaceReviewFile) -> some View {
        if let workspaceId = session?.workspaceId {
            NavigationStack {
                WorkspaceReviewFileDetailView(
                    workspaceId: workspaceId,
                    selectedSessionId: sessionId,
                    file: file
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { contextPillDetailFile = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var outlineSheet: some View {
        SessionOutlineView(
            items: reducer.items,
            onSelect: { targetID in
                scrollController.scrollTargetID = targetID
            },
            onFork: forkFromMessage
        )
        .presentationDetents([.medium, .large])
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
            pendingImages: $pendingImages,
            pendingFiles: $pendingFiles,
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
