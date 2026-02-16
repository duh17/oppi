import SwiftUI
import UIKit

struct ChatView: View {
    let sessionId: String

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(TimelineReducer.self) private var reducer
    @Environment(AudioPlayerService.self) private var audioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var sessionManager: ChatSessionManager
    @State private var scrollController = ChatScrollController()
    @State private var actionHandler = ChatActionHandler()
    @State private var dictationService = DictationService()

    @State private var inputText = ""
    @State private var pendingImages: [PendingImage] = []

    @State private var showOutline = false
    @State private var showModelPicker = false
    @State private var showComposer = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var copiedSessionID = false
    @State private var forkedSessionToOpen: ForkRoute?
#if DEBUG
    @State private var uploadingClientLogs = false
#endif
    @State private var showCompactConfirmation = false
    @State private var showSkillPanel = false
    @State private var isKeyboardVisible = false
    @State private var coloredThinkingBorderEnabled = UserDefaults.standard.bool(
        forKey: coloredThinkingBorderDefaultsKey
    )

    init(sessionId: String) {
        self.sessionId = sessionId
        _sessionManager = State(initialValue: ChatSessionManager(sessionId: sessionId))
    }

    private struct ForkRoute: Identifiable, Hashable {
        let id: String
    }

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var sessionDisplayName: String {
        let trimmed = session?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return "Session \(String(sessionId.prefix(8)))"
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

    /// Show toolbar when composing (keyboard up) or at bottom of chat.
    /// Hide when scrolled up to read history.

    private var runtimeSyncState: RuntimeStatusBadge.SyncState {
        guard let wsClient = connection.wsClient else {
            return .offline
        }

        let ownsSession = wsClient.connectedSessionId == sessionId

        let isWsSyncing: Bool
        let isWsDisconnected: Bool
        switch wsClient.status {
        case .connecting, .reconnecting:
            isWsSyncing = true
            isWsDisconnected = false
        case .connected:
            isWsSyncing = false
            isWsDisconnected = false
        case .disconnected:
            isWsSyncing = false
            isWsDisconnected = true
        }

        let isSyncing = ownsSession && (isWsSyncing || sessionManager.isSyncing)
        let lastSyncFailed = !ownsSession || isWsDisconnected || sessionManager.lastSyncFailed

        let freshness = FreshnessState.derive(
            lastSuccessfulSyncAt: sessionManager.lastSuccessfulSyncAt,
            isSyncing: isSyncing,
            lastSyncFailed: lastSyncFailed,
            staleAfter: 120
        )

        return .init(freshness)
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTimelineView(
                sessionId: sessionId,
                workspaceId: session?.workspaceId,
                isBusy: isBusy,
                scrollController: scrollController,
                sessionManager: sessionManager,
                onFork: forkFromMessage
            )

            footerArea
        }
        .background(Color.tokyoBg.ignoresSafeArea())
        .navigationTitle(sessionDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $forkedSessionToOpen) { route in
            Self(sessionId: route.id)
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
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

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if !reducer.items.isEmpty {
                        Button { showOutline = true } label: {
                            Image(systemName: "list.bullet")
                                .font(.subheadline)
                        }
                    }
                    Button { showSkillPanel = true } label: {
                        RuntimeStatusBadge(
                            runtime: session?.runtime,
                            statusColor: session?.status.color ?? .tokyoComment,
                            syncState: runtimeSyncState
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showOutline) {
            outlineSheet
        }
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
        }
        .sheet(isPresented: $showSkillPanel) {
            skillPanelSheet
        }
        .fullScreenCover(isPresented: $showComposer) {
            composerSheet
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            renameAlert
        } message: {
            Text("Keep it short (2–6 words). For task planning, start with TODO: ...")
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
        .onAppear {
            sessionManager.markAppeared()
            if sessionManager.hasAppeared, let draft = connection.composerDraft, !draft.isEmpty {
                inputText = draft
                connection.composerDraft = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: session?.status) { _, newStatus in
            if newStatus != .stopping {
                actionHandler.resetStopState()
                sessionManager.cancelReconciliation()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                saveScrollState()
                Task {
                    await sessionManager.flushSnapshotIfNeeded(connection: connection)
                }
            }
        }
        .onDisappear {
            actionHandler.cleanup()
            sessionManager.cleanup()
            scrollController.cancel()
            audioPlayer.stop()
            let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.composerDraft = draft.isEmpty ? nil : draft
            saveScrollState()
            Task {
                await sessionManager.flushSnapshotIfNeeded(connection: connection, force: true)
            }
            // Only disconnect if WE are still the active session.
            // A new ChatView may have already taken over the WS.
            if connection.wsClient?.connectedSessionId == sessionId
                || connection.wsClient?.connectedSessionId == nil {
                connection.disconnectSession()
            }
        }
    }

    @ViewBuilder
    private var footerArea: some View {
        if isStopped {
            SessionEndedFooter(session: session)
        } else {
            VStack(spacing: 8) {
                ChatInputBar(
                    text: $inputText,
                    pendingImages: $pendingImages,
                    isBusy: isBusy,
                    isSending: actionHandler.isSending,
                    sendProgressText: actionHandler.sendProgressText,
                    isStopping: isStopping,
                    dictationService: dictationService,
                    showForceStop: actionHandler.showForceStop,
                    isForceStopInFlight: actionHandler.isForceStopInFlight,
                    slashCommands: connection.slashCommands,
                    onSend: sendPrompt,
                    onBash: sendBashCommand,
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
                    appliesOuterPadding: true,
                    thinkingBorderColor: coloredThinkingBorderEnabled
                        ? theme.thinking.color(for: connection.thinkingLevel)
                        : .tokyoComment
                ) {
                    SessionToolbar(
                        session: session,
                        thinkingLevel: connection.thinkingLevel,
                        onModelTap: { showModelPicker = true },
                        onThinkingSelect: { level in
                            actionHandler.setThinking(
                                level,
                                connection: connection,
                                reducer: reducer,
                                sessionId: sessionId
                            )
                        },
                        onCompact: {
                            showCompactConfirmation = true
                        }
                    )
                }
            }
        }
    }

    private var sessionTitleLabel: some View {
        HStack(spacing: 6) {
            Text(sessionDisplayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tokyoFg)
                .lineLimit(1)

            if let cost = session?.cost, cost > 0 {
                Text(String(format: "$%.2f", cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tokyoComment)
            }

            Image(systemName: copiedSessionID ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copiedSessionID ? .tokyoGreen : .tokyoComment)
        }
    }

    // MARK: - Chat Timeline
    // Extracted to ChatTimelineView (separate struct) so that @State inputText
    // changes in ChatView do NOT trigger ForEach re-diffing of 200+ items.
    // Each keystroke was re-evaluating the entire timeline — O(n) on every char.

    // MARK: - Actions

    private func presentComposer() {
        showComposer = true
    }

    private func sendPrompt() {
        let text = inputText
        let images = pendingImages

        let reducerRef = reducer
        let sessionManagerRef = sessionManager
        let scrollRef = scrollController

        let restored = actionHandler.sendPrompt(
            text: text,
            images: images,
            isBusy: isBusy,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            sessionStore: sessionStore,
            onDispatchStarted: {
                inputText = ""
                pendingImages = []
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

    private func sendBashCommand(_ command: String) {
        inputText = ""
        scrollController.requestScrollToBottom()
        actionHandler.sendBash(
            command,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId
        )
    }

    private func saveScrollState() {
        let nearBottom = scrollController.isCurrentlyNearBottom
        connection.scrollWasNearBottom = nearBottom
        connection.scrollAnchorItemId = nearBottom ? nil : scrollController.currentTopVisibleItemId
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

    private var outlineSheet: some View {
        SessionOutlineView(
            sessionId: sessionId,
            workspaceId: session?.workspaceId,
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

    private var currentWorkspaceSkillNames: [String] {
        guard let wsId = session?.workspaceId else { return [] }
        return connection.workspaceStore.workspaces.first { $0.id == wsId }?.skills ?? []
    }

    private var skillPanelSheet: some View {
        NavigationStack {
            SkillPanelView(workspaceSkillNames: currentWorkspaceSkillNames)
                .navigationTitle("Skills")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSkillPanel = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private var modelPickerSheet: some View {
        ModelPickerSheet(currentModel: session?.model) { model in
            actionHandler.setModel(
                model,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId
            )
        }
        .presentationDetents([.medium, .large])
    }

    private var composerSheet: some View {
        ExpandedComposerView(
            text: $inputText,
            pendingImages: $pendingImages,
            isBusy: isBusy,
            slashCommands: connection.slashCommands,
            session: session,
            thinkingLevel: connection.thinkingLevel,
            onSend: sendPrompt,
            onBash: sendBashCommand,
            onModelTap: { showModelPicker = true },
            onThinkingSelect: { level in
                actionHandler.setThinking(
                    level,
                    connection: connection,
                    reducer: reducer,
                    sessionId: sessionId
                )
            },
            onCompact: { showCompactConfirmation = true }
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

// MARK: - Empty State

private struct ChatEmptyState: View {
    var body: some View {
        Text("π")
            .font(.system(size: 48, design: .monospaced).weight(.bold))
            .foregroundStyle(.tokyoPurple.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Working Indicator

private struct WorkingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("π")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tokyoPurple)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.tokyoComment)
                        .frame(width: 6, height: 6)
                        .opacity(dotOpacity(index: i))
                }
            }
            .padding(.top, 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func dotOpacity(index: Int) -> Double {
        let offset = Double(index) / 3.0
        let adjusted = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + 0.7 * max(0, 1 - abs(adjusted - 0.5) * 4)
    }
}

private struct JumpToBottomHintButton: View {
    let isStreaming: Bool
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(Color.tokyoBgHighlight.opacity(0.95))
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .stroke((isStreaming ? Color.tokyoBlue : Color.tokyoComment).opacity(0.34), lineWidth: 1)
                )
                .overlay {
                    Image(systemName: "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isStreaming ? .tokyoBlue : .tokyoFg)
                }
                .overlay(alignment: .topTrailing) {
                    if isStreaming {
                        Circle()
                            .fill(Color.tokyoBlue)
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulse ? 1.0 : 0.72)
                            .opacity(pulse ? 1.0 : 0.55)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityLabel(isStreaming ? "Jump to latest streaming message" : "Jump to latest message")
        .onAppear {
            guard isStreaming else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
    }
}

// MARK: - Session Ended Footer

private struct SessionEndedFooter: View {
    let session: Session?

    var body: some View {
        VStack(spacing: 6) {
            Divider()
                .overlay(Color.tokyoComment.opacity(0.3))

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.tokyoComment)

                Text("Session ended")
                    .font(.subheadline)
                    .foregroundStyle(.tokyoComment)

                if let session {
                    Spacer()

                    let totalTokens = session.tokens.input + session.tokens.output
                    if totalTokens > 0 {
                        Text(formatTokenCount(totalTokens) + " tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoComment)
                    }

                    if session.cost > 0 {
                        Text(String(format: "$%.3f", session.cost))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoComment)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - ChatTimelineView (Isolated Observation Scope)

/// Extracted from ChatView so that @State inputText changes (every keystroke)
/// do NOT trigger a full ForEach re-diff of 200+ items.
///
/// As a separate View struct, this gets its own SwiftUI observation scope.
/// It only re-evaluates when its own dependencies change (reducer.items,
/// renderVersion, session status) — NOT when the parent's @State changes.
private struct ChatTimelineView: View {
    private static let initialRenderWindow = 80
    private static let renderWindowStep = 60
    /// Guardrail for exact scroll restoration. Expanding the window to thousands
    /// of rows in one pass can stall placement on older devices.
    private static let maxRestorationWindow = 180

    let sessionId: String
    let workspaceId: String?
    let isBusy: Bool
    let scrollController: ChatScrollController
    let sessionManager: ChatSessionManager
    let onFork: (String) -> Void

    @Environment(TimelineReducer.self) private var reducer
    @Environment(ServerConnection.self) private var connection
    @Environment(AudioPlayerService.self) private var audioPlayer
    @Environment(\.theme) private var theme

    @State private var renderWindow = Self.initialRenderWindow
    @State private var fileToOpen: FileToOpen?
    @State private var scrollCommandNonce = 0
    @State private var pendingScrollCommand: ChatTimelineScrollCommand?

    private var visibleItems: ArraySlice<ChatItem> {
        reducer.items.suffix(renderWindow)
    }

    private var hiddenCount: Int {
        max(0, reducer.items.count - visibleItems.count)
    }

    private var showsWorkingIndicator: Bool {
        isBusy && reducer.streamingAssistantID == nil
    }

    private var bottomItemID: String? {
        if showsWorkingIndicator {
            return ChatTimelineCollectionView.workingIndicatorID
        }
        return visibleItems.last?.id
    }

    var body: some View {
        ChatTimelineCollectionView(
            configuration: .init(
                items: Array(visibleItems),
                hiddenCount: hiddenCount,
                renderWindowStep: Self.renderWindowStep,
                isBusy: isBusy,
                streamingAssistantID: reducer.streamingAssistantID,
                sessionId: sessionId,
                workspaceId: workspaceId,
                onFork: onFork,
                onOpenFile: { fileToOpen = $0 },
                onShowEarlier: {
                    renderWindow = min(reducer.items.count, renderWindow + Self.renderWindowStep)
                },
                scrollCommand: pendingScrollCommand,
                scrollController: scrollController,
                reducer: reducer,
                toolOutputStore: reducer.toolOutputStore,
                toolArgsStore: reducer.toolArgsStore,
                connection: connection,
                audioPlayer: audioPlayer,
                theme: theme,
                themeID: ThemeRuntimeState.currentThemeID()
            )
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PermissionOverlay(sessionId: sessionId)
        }
        .background(Color.tokyoBg)
        .overlay {
            if reducer.items.isEmpty && !isBusy {
                ChatEmptyState()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if scrollController.isJumpToBottomHintVisible {
                JumpToBottomHintButton(isStreaming: scrollController.isDetachedStreamingHintVisible) {
                    jumpToLatest()
                }
                .padding(.trailing, 27)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: scrollController.isJumpToBottomHintVisible)
        .onChange(of: reducer.renderVersion) { _, _ in
            scrollController.itemCount = visibleItems.count
            let hasNewItems = scrollController.consumeHasNewItems()
            scrollController.handleContentChange(
                isBusy: isBusy,
                streamingAssistantID: reducer.streamingAssistantID,
                bottomItemID: bottomItemID
            ) { _ in
                // Always target the actual bottom of the timeline.
                // During streaming, bottomItemID == streaming assistant (correct).
                // During tool calls, bottomItemID == latest tool or working indicator.
                guard let bottom = bottomItemID else { return }
                let animate = hasNewItems
                issueScrollCommand(id: bottom, anchor: .bottom, animated: animate)
            }
        }
        .onChange(of: sessionManager.needsInitialScroll) { _, needs in
            guard needs else { return }
            sessionManager.needsInitialScroll = false
            scrollController.needsInitialScroll = true
            scrollController.handleInitialScroll(bottomItemID: bottomItemID) { targetID in
                issueScrollCommand(id: targetID, anchor: .bottom, animated: false)
            }
        }
        .onChange(of: scrollController.scrollTargetID) { _, targetID in
            guard targetID != nil else { return }
            if let targetID, !visibleItems.contains(where: { $0.id == targetID }) {
                renderWindow = reducer.items.count
            }
            scrollController.handleScrollTarget { target in
                issueScrollCommand(id: target, anchor: .top, animated: true)
            }
        }
        .onChange(of: sessionManager.restorationScrollItemId) { _, itemId in
            guard let itemId else { return }
            sessionManager.restorationScrollItemId = nil

            guard let targetIndex = reducer.items.firstIndex(where: { $0.id == itemId }) else { return }
            let requiredWindow = reducer.items.count - targetIndex
            guard requiredWindow <= Self.maxRestorationWindow else { return }

            if !visibleItems.contains(where: { $0.id == itemId }) {
                renderWindow = max(renderWindow, requiredWindow)
            }
            scrollController.scrollTargetID = itemId
        }
        .onChange(of: scrollController.scrollToBottomNonce) { _, _ in
            guard let bottomItemID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                issueScrollCommand(id: bottomItemID, anchor: .bottom, animated: true)
            }
        }
        .sheet(item: $fileToOpen) { file in
            RemoteFileView(workspaceId: file.workspaceId, sessionId: file.sessionId, path: file.path)
        }
    }

    private func jumpToLatest() {
        guard let bottomItemID else { return }
        scrollController.setDetachedStreamingHintVisible(false)
        scrollController.setJumpToBottomHintVisible(false)
        issueScrollCommand(id: bottomItemID, anchor: .bottom, animated: true)
    }

    private func issueScrollCommand(id: String, anchor: ChatTimelineScrollCommand.Anchor, animated: Bool) {
        scrollCommandNonce &+= 1
        pendingScrollCommand = ChatTimelineScrollCommand(
            id: id,
            anchor: anchor,
            animated: animated,
            nonce: scrollCommandNonce
        )
    }
}
