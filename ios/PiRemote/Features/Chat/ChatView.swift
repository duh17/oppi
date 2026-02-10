import os.log
import SwiftUI
import UIKit

private let perfLog = Logger(subsystem: "dev.chenda.PiRemote", category: "ChatView")

struct ChatView: View {
    let sessionId: String

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(TimelineReducer.self) private var reducer
    @Environment(AudioPlayerService.self) private var audioPlayer

    @State private var sessionManager: ChatSessionManager
    @State private var scrollController = ChatScrollController()
    @State private var actionHandler = ChatActionHandler()

    @State private var inputText = ""
    @State private var pendingImages: [PendingImage] = []

    @State private var showOutline = false
    @State private var showModelPicker = false
    @State private var showComposer = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var copiedSessionID = false
#if DEBUG
    @State private var showSessionActions = false
    @State private var uploadingClientLogs = false
#endif

    init(sessionId: String) {
        self.sessionId = sessionId
        _sessionManager = State(initialValue: ChatSessionManager(sessionId: sessionId))
    }

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
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

    var body: some View {
        VStack(spacing: 0) {
            SessionToolbar(
                session: session,
                thinkingLevel: connection.thinkingLevel,
                onModelTap: { showModelPicker = true },
                onThinkingCycle: {
                    actionHandler.cycleThinking(connection: connection, reducer: reducer, sessionId: sessionId)
                },
                onCompact: {
                    actionHandler.compact(connection: connection, reducer: reducer, sessionId: sessionId)
                },
                onRename: {
                    renameText = session?.name ?? ""
                    showRenameAlert = true
                },
                onNewSession: {
                    actionHandler.newSession(connection: connection, reducer: reducer, sessionId: sessionId)
                }
            )

            ChatTimelineView(
                sessionId: sessionId,
                isBusy: isBusy,
                scrollController: scrollController,
                sessionManager: sessionManager,
                onFork: forkFromMessage
            )

            footerArea
        }
        .background(Color.tokyoBg.ignoresSafeArea())
        .navigationTitle(sessionId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
#if DEBUG
                Button {
                    showSessionActions = true
                } label: {
                    sessionTitleLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session actions")
                .confirmationDialog("Session Actions", isPresented: $showSessionActions) {
                    Button("Copy Session ID") {
                        copySessionID()
                    }
                    Button(uploadingClientLogs ? "Uploading Client Logs…" : "Upload Client Logs") {
                        uploadClientLogs()
                    }
                    .disabled(uploadingClientLogs)
                    Button("Cancel", role: .cancel) {}
                }
#else
                Button(action: copySessionID) {
                    sessionTitleLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy session ID")
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
                    RuntimeStatusBadge(
                        runtime: session?.runtime,
                        statusColor: session?.status.color ?? .tokyoComment
                    )
                }
            }
        }
        .sheet(isPresented: $showOutline) {
            outlineSheet
        }
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
        }
        .sheet(isPresented: $showComposer) {
            composerSheet
        }
        .alert("Rename Session", isPresented: $showRenameAlert) {
            renameAlert
        } message: {
            Text("Enter a new name for this session.")
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
        .onChange(of: session?.status) { _, newStatus in
            if newStatus != .stopping {
                actionHandler.resetStopState()
                sessionManager.cancelReconciliation()
            }
        }
        .onDisappear {
            actionHandler.cleanup()
            sessionManager.cleanup()
            scrollController.cancel()
            audioPlayer.stop()
            let draft = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.composerDraft = draft.isEmpty ? nil : draft
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
            ChatInputBar(
                text: $inputText,
                pendingImages: $pendingImages,
                isBusy: isBusy,
                isSending: actionHandler.isSending,
                sendProgressText: actionHandler.sendProgressText,
                isStopping: isStopping,
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
                onExpand: { showComposer = true },
                appliesOuterPadding: true
            )
        }
    }

    private var sessionTitleLabel: some View {
        HStack(spacing: 6) {
            Text(sessionId)
                .font(.caption.monospaced())
                .foregroundStyle(.tokyoFg)
                .lineLimit(1)
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

    private func sendPrompt() {
        let text = inputText
        let images = pendingImages

        if handleBuiltinSlashCommand(text: text, images: images) {
            return
        }

        let reducerRef = reducer
        let sessionManagerRef = sessionManager

        let restored = actionHandler.sendPrompt(
            text: text,
            images: images,
            isBusy: isBusy,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            onDispatchStarted: {
                inputText = ""
                pendingImages = []
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

    private func handleBuiltinSlashCommand(text: String, images: [PendingImage]) -> Bool {
        guard !isBusy else {
            return false
        }

        guard let command = SlashBuiltinCommand.parse(text) else {
            return false
        }

        if !images.isEmpty {
            reducer.process(.error(sessionId: sessionId, message: "Slash commands do not support image attachments."))
            return true
        }

        switch command {
        case .compact(let customInstructions):
            inputText = ""
            pendingImages = []
            if let customInstructions {
                Task {
                    do {
                        try await connection.compact(instructions: customInstructions)
                        try? await connection.requestState()
                    } catch {
                        reducer.process(.error(sessionId: sessionId, message: "Compact failed: \(error.localizedDescription)"))
                    }
                }
            } else {
                actionHandler.compact(connection: connection, reducer: reducer, sessionId: sessionId)
            }
            return true

        case .newSession:
            inputText = ""
            pendingImages = []
            actionHandler.newSession(connection: connection, reducer: reducer, sessionId: sessionId)
            return true

        case .setSessionName(let maybeName):
            guard let name = maybeName else {
                reducer.process(.error(sessionId: sessionId, message: "Usage: /name <session name>"))
                return true
            }
            inputText = ""
            pendingImages = []
            actionHandler.rename(
                name,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId
            )
            return true

        case .modelPicker:
            inputText = ""
            pendingImages = []
            showModelPicker = true
            return true
        }
    }

    private func sendBashCommand(_ command: String) {
        inputText = ""
        actionHandler.sendBash(
            command,
            connection: connection,
            reducer: reducer,
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

        uploadingClientLogs = true
        ClientLog.info("ChatView", "Manual client log upload requested", metadata: [
            "sessionId": sessionId,
        ])

        Task { @MainActor in
            defer { uploadingClientLogs = false }

            let entries = await ClientLogBuffer.shared.snapshot(limit: 500)
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
                try await api.uploadClientLogs(sessionId: sessionId, request: request)
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
            items: reducer.items,
            onSelect: { targetID in
                scrollController.scrollTargetID = targetID
            },
            onFork: forkFromMessage
        )
        .presentationDetents([.medium, .large])
    }

    private func forkFromMessage(_ entryId: String) {
        if UUID(uuidString: entryId) != nil {
            reducer.process(.error(sessionId: sessionId, message: "Wait for this turn to finish before forking."))
            return
        }
        Task {
            do {
                try await connection.send(.fork(entryId: entryId))
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Fork failed: \(error.localizedDescription)"))
            }
        }
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
            onSend: sendPrompt,
            onBash: sendBashCommand
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(false)
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
        VStack(spacing: 12) {
            Text("π")
                .font(.system(size: 48, design: .monospaced).weight(.bold))
                .foregroundStyle(.tokyoPurple.opacity(0.5))
            Text("Send a message to start")
                .font(.subheadline)
                .foregroundStyle(.tokyoComment)
            Text("Tip: prefix with $ for shell commands")
                .font(.caption)
                .foregroundStyle(.tokyoComment.opacity(0.6))
        }
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
    let sessionId: String
    let isBusy: Bool
    let scrollController: ChatScrollController
    let sessionManager: ChatSessionManager
    let onFork: (String) -> Void

    @Environment(TimelineReducer.self) private var reducer

    var body: some View {
        MainThreadBreadcrumb.set("timeline-body:\(reducer.items.count)items")
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(reducer.items) { item in
                        ChatItemRow(
                            item: item,
                            isStreaming: item.id == reducer.streamingAssistantID,
                            onFork: onFork
                        )
                        .id(item.id)
                    }

                    if isBusy && reducer.streamingAssistantID == nil {
                        WorkingIndicator()
                            .id("working-indicator")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom-sentinel")
                        .onAppear { scrollController.onSentinelAppear() }
                        .onDisappear { scrollController.onSentinelDisappear() }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PermissionOverlay(sessionId: sessionId)
            }
            .background(Color.tokyoBg)
            .overlay {
                if reducer.items.isEmpty && !isBusy {
                    ChatEmptyState()
                }
            }
            .onChange(of: reducer.renderVersion) { _, newVersion in
                let rowsRendered = MainThreadBreadcrumb.rowCount
                MainThreadBreadcrumb.resetRowCount()
                perfLog.error("PERF renderVersion=\(newVersion, privacy: .public) items=\(reducer.items.count, privacy: .public) rowsSinceLastRV=\(rowsRendered, privacy: .public)")
                scrollController._diagnosticItemCount = reducer.items.count
                scrollController.handleRenderVersionChange(
                    proxy: proxy,
                    streamingID: reducer.streamingAssistantID
                )
            }
            .onChange(of: sessionManager.needsInitialScroll) { _, needs in
                guard needs else { return }
                sessionManager.needsInitialScroll = false
                scrollController.needsInitialScroll = true
                scrollController.handleInitialScroll(proxy: proxy)
            }
            .onChange(of: scrollController.scrollTargetID) { _, _ in
                scrollController.handleScrollTarget(proxy: proxy)
            }
        }
    }
}
