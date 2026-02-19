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
        .background(Color.themeBg.ignoresSafeArea())
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
                            statusColor: session?.status.color ?? .themeComment,
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
            LiveActivityManager.shared.endIfNeeded()
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
                        : .themeComment
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
                .foregroundStyle(.themeFg)
                .lineLimit(1)

            if let cost = session?.cost, cost > 0 {
                Text(String(format: "$%.2f", cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.themeComment)
            }

            Image(systemName: copiedSessionID ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copiedSessionID ? .themeGreen : .themeComment)
        }
    }

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


