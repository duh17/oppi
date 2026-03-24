import FoundationModels
import os.log
import SwiftUI

private let log = Logger(subsystem: AppIdentifiers.subsystem, category: "Action")

/// Handles user actions in the chat: sending prompts, stopping the agent,
/// model/thinking changes, and session management.
///
/// Extracted from ChatView to keep the view focused on composition.
/// Owns the stop/force-stop state machine and action dispatch.
@MainActor @Observable
final class ChatActionHandler {
    // MARK: - Stop State Machine

    private(set) var isStopping = false
    private(set) var showForceStop = false
    private(set) var isForceStopInFlight = false
    private(set) var isSending = false
    private(set) var sendAckStage: TurnAckStage?
    private(set) var reconnectFailureMessage: String?
    private var sendStageClearTask: Task<Void, Never>?
    private var forceStopTask: Task<Void, Never>?
    private var sendRecoveryText: String?

    private static let sendStageDisplayDuration: Duration = .seconds(1.2)
    private static let reconnectRecoveryTimeout: Duration = .seconds(8)
    private static let reconnectRecoveryPollInterval: Duration = .milliseconds(150)

    /// Test seam: shorten send-stage display retention.
    var _sendStageDisplayDurationForTesting: Duration?

    /// Test seam: shorten reconnect recovery timeout.
    var _reconnectRecoveryTimeoutForTesting: Duration?

    /// Test seam: shorten reconnect recovery poll interval.
    var _reconnectRecoveryPollIntervalForTesting: Duration?

    /// Test seam: override async task launch to simulate scheduling races.
    var _launchTaskForTesting: (((@escaping @MainActor () async -> Void)) -> Void)?

    /// Test seam: override auto title generation.
    var _generateSessionTitleForTesting: ((String) async -> String?)?

    /// Test seam: override stop-turn transport.
    var _sendStopForTesting: ((ServerConnection) async throws -> Void)?

    /// Test seam: override force-stop transport.
    var _sendStopSessionForTesting: ((ServerConnection) async throws -> Void)?

    private var autoTitleTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var autoTitleAttemptedSessionIds: Set<String> = []

    private static let autoTitleMaxLength = 48
    /// Backward-compat key reference for tests that set up UserDefaults directly.
    static let autoTitleEnabledDefaultsKey = AppPreferences.Session.autoTitleEnabledKey
    private static var isAutoTitleEnabled: Bool {
        AppPreferences.Session.isAutoTitleEnabled
    }
    private static let autoTitleInstructions = """
        You generate concise coding session titles.
        Return exactly one line containing only the title text.

        Rules:
        - 2 to 6 words.
        - Start with a category verb or noun when the intent is clear:
          "Fix", "Debug", "Add", "Refactor", "Review", "Investigate", "Polish", "Test", "Research".
        - Capture one concrete objective using specific nouns from the request \
        (feature name, bug symptom, file, subsystem, tool).
        - Skip conversational filler like "please", "can you", "help me", or "I need to".
        - No quotes, markdown, emojis, or trailing punctuation.

        Examples:
        - "fix the websocket reconnect state drift" -> Fix WebSocket Reconnect Drift
        - "let's polish the review view icons" -> Polish Review View Icons
        - "can you investigate why voice input language changes" -> Investigate Voice Input Language Bug
        - "research code review agents" -> Research Code Review Agents
        - "install our app" -> Install App
        """

    var sendProgressText: String? {
        if let sendAckStage {
            switch sendAckStage {
            case .accepted:
                return "Accepted…"
            case .dispatched:
                return "Dispatched…"
            case .started:
                return "Started…"
            }
        }

        if let sendRecoveryText {
            return sendRecoveryText
        }

        return isSending ? "Sending…" : nil
    }

    // MARK: - Prompt / Steer

    /// Send a user prompt or steer the running agent.
    ///
    /// Returns the input text to restore on failure, or empty string on success.
    func sendPrompt(
        text: String,
        images: [PendingImage],
        isBusy: Bool,
        busyStreamingBehavior: StreamingBehavior = .steer,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String,
        sessionStore: SessionStore? = nil,
        sessionManager: ChatSessionManager? = nil,
        onDispatchStarted: (() -> Void)? = nil,
        onAsyncFailure: ((_ text: String, _ images: [PendingImage]) -> Void)? = nil,
        onNeedsReconnect: (() -> Void)? = nil
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = images.map(\.attachment)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return text }
        guard !isSending else { return text }

        if isBusy {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()

            let queuedImages = attachments.isEmpty ? nil : attachments
            let queuedKind: MessageQueueKind = busyStreamingBehavior == .steer ? .steer : .followUp
            let optimisticQueueItem = connection.messageQueueStore.enqueueOptimisticItem(
                for: sessionId,
                kind: queuedKind,
                message: trimmed,
                images: queuedImages
            )

            launchTask { @MainActor in
                self.beginSendTracking()
                defer { self.isSending = false }
                onDispatchStarted?()

                do {
                    switch busyStreamingBehavior {
                    case .steer:
                        try await connection.sendSteer(trimmed, images: queuedImages, onAckStage: { stage in
                            self.updateSendAckStage(stage)
                        })
                    case .followUp:
                        try await connection.sendFollowUp(trimmed, images: queuedImages, onAckStage: { stage in
                            self.updateSendAckStage(stage)
                        })
                    }
                    self.scheduleSendStageClear()
                    Task { @MainActor in
                        try? await connection.requestMessageQueue()
                    }
                } catch {
                    connection.messageQueueStore.removeQueuedItem(
                        for: sessionId,
                        kind: queuedKind,
                        id: optimisticQueueItem.id,
                        messageFallback: trimmed
                    )
                    self.clearSendStageNow()
                    let commandName = busyStreamingBehavior == .steer ? "steer" : "follow_up"
                    let errorPrefix = busyStreamingBehavior == .steer ? "Steer" : "Follow-up"
                    log.error("SEND \(commandName, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)")
                    ClientLog.error(
                        "Action",
                        "SEND \(commandName) FAILED",
                        metadata: ["sessionId": sessionId, "error": error.localizedDescription]
                    )
                    if Self.isReconnectableSendError(error) {
                        onNeedsReconnect?()
                    }
                    onAsyncFailure?(text, images)
                    reducer.process(.error(sessionId: sessionId, message: "\(errorPrefix) failed: \(error.localizedDescription)"))
                }
            }
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            launchTask { @MainActor in
                self.beginSendTracking()

                let messageId = reducer.appendUserMessage(trimmed, images: attachments)
                // Decouple composer-clear from the optimistic timeline append.
                // Running both in the same layout turn increases the chance of
                // UIKit↔SwiftUI feedback loops under heavy timeline load.
                if let onDispatchStarted {
                    DispatchQueue.main.async {
                        onDispatchStarted()
                    }
                }
                do {
                    let promptImages = attachments.isEmpty ? nil : attachments
                    try await connection.sendPrompt(trimmed, images: promptImages, onAckStage: { stage in
                        self.updateSendAckStage(stage)
                    })
                    self.scheduleSendStageClear()
                    self.scheduleAutoSessionTitleIfNeeded(
                        sessionId: sessionId,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                } catch {
                    if let sessionManager,
                       Self.isReconnectableSendError(error) {
                        await self.recoverPromptSendAfterReconnect(
                            text: text,
                            trimmedText: trimmed,
                            images: images,
                            attachments: attachments,
                            messageId: messageId,
                            connection: connection,
                            reducer: reducer,
                            sessionStore: sessionStore,
                            sessionManager: sessionManager,
                            sessionId: sessionId,
                            onAsyncFailure: onAsyncFailure,
                            onNeedsReconnect: onNeedsReconnect
                        )
                        self.isSending = false
                        return
                    }

                    self.clearSendStageNow()
                    log.error("SEND prompt FAILED: \(error.localizedDescription, privacy: .public)")
                    ClientLog.error(
                        "Action",
                        "SEND prompt FAILED",
                        metadata: ["sessionId": sessionId, "error": error.localizedDescription]
                    )
                    if Self.isReconnectableSendError(error) {
                        onNeedsReconnect?()
                    }
                    onAsyncFailure?(text, images)
                    reducer.removeItem(id: messageId)
                    reducer.process(.error(sessionId: sessionId, message: "Failed to send: \(error.localizedDescription)"))
                }

                self.isSending = false
            }
        }

        return ""
    }

    // MARK: - Bash

    // MARK: - Resume

    private(set) var isResuming = false

    /// Resume a stopped session via the REST endpoint, then reconnect the WS stream.
    func resumeSession(
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        sessionManager: ChatSessionManager,
        sessionId: String
    ) {
        guard !isResuming else { return }
        isResuming = true

        Task { @MainActor in
            defer { isResuming = false }

            guard let api = connection.apiClient else {
                reducer.process(.error(sessionId: sessionId, message: "No connection available"))
                return
            }

            guard let workspaceId = sessionStore.workspaceId(for: sessionId),
                  !workspaceId.isEmpty else {
                reducer.process(.error(sessionId: sessionId, message: "Missing workspace context"))
                return
            }

            do {
                let updated = try await api.resumeWorkspaceSession(
                    workspaceId: workspaceId,
                    sessionId: sessionId
                )
                sessionStore.upsert(updated)

                // Trigger reconnect which will now open the WS since session is no longer stopped
                sessionManager.reconnect()
            } catch {
                reducer.process(.error(
                    sessionId: sessionId,
                    message: "Resume failed: \(error.localizedDescription)"
                ))
            }
        }
    }

    // MARK: - Stop / Force Stop

    func stop(
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        sessionManager: ChatSessionManager,
        sessionId: String
    ) {
        isStopping = true
        showForceStop = false

        forceStopTask?.cancel()
        forceStopTask = nil

        Task { @MainActor in
            do {
                if let sendStopHook = self._sendStopForTesting {
                    try await sendStopHook(connection)
                } else {
                    try await connection.sendStop()
                }
            } catch {
                isStopping = false
                reducer.process(.error(sessionId: sessionId, message: "Failed to stop: \(error.localizedDescription)"))
                return
            }

            // Stop-turn must never escalate to stop-session automatically.
            // If graceful stop fails, server emits stop_failed and the session
            // remains alive for the next prompt.
            sessionManager.reconcileAfterStop(connection: connection, sessionStore: sessionStore)
        }
    }

    func forceStop(
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        sessionId: String
    ) {
        guard !isForceStopInFlight else { return }
        isForceStopInFlight = true

        Task { @MainActor in
            do {
                if let sendStopSessionHook = self._sendStopSessionForTesting {
                    try await sendStopSessionHook(connection)
                } else {
                    try await connection.sendStopSession()
                }
                reducer.appendSystemEvent("Session stopped")
            } catch {
                if let api = connection.apiClient,
                   let workspaceId = sessionStore.workspaceId(for: sessionId),
                   !workspaceId.isEmpty {
                    do {
                        let updatedSession = try await api.stopSession(workspaceId: workspaceId, id: sessionId)
                        sessionStore.upsert(updatedSession)
                        reducer.appendSystemEvent("Session stopped")
                    } catch {
                        reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(error.localizedDescription)"))
                    }
                } else {
                    reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(error.localizedDescription)"))
                }
            }
            isForceStopInFlight = false
        }
    }

    /// Reset stop state when session leaves busy.
    func resetStopState() {
        isStopping = false
        showForceStop = false
        isForceStopInFlight = false
        forceStopTask?.cancel()
        forceStopTask = nil
        sendRecoveryText = nil
        reconnectFailureMessage = nil
        clearSendStageNow()
    }

    // MARK: - Model / Thinking / Context

    func setThinking(
        _ level: ThinkingLevel,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String
    ) {
        Task {
            do {
                try await connection.setThinkingLevel(level)
                try? await connection.requestState()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Failed to set thinking: \(error.localizedDescription)"))
            }
        }
    }

    // periphery:ignore - future UI wiring point for thinking level cycling
    func cycleThinking(connection: ServerConnection, reducer: TimelineReducer, sessionId: String) {
        Task {
            do {
                try await connection.cycleThinkingLevel()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Failed to cycle thinking: \(error.localizedDescription)"))
            }
        }
    }

    func compact(connection: ServerConnection, reducer: TimelineReducer, sessionId: String) {
        Task { @MainActor in
            // Show immediate "Compacting context..." indicator before the server responds.
            reducer.process(.compactionStart(sessionId: sessionId, reason: "manual"))
            do {
                try await connection.compact()
                try? await connection.requestState()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Compact failed: \(error.localizedDescription)"))
            }
        }
    }

    // periphery:ignore - future UI wiring point for new session creation
    func newSession(connection: ServerConnection, reducer: TimelineReducer, sessionId: String) {
        Task { @MainActor in
            do {
                try await connection.newSession()
                try? await connection.requestState()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "New session failed: \(error.localizedDescription)"))
            }
        }
    }

    func setModel(
        _ model: ModelInfo,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        sessionId: String
    ) {
        let session = sessionStore.sessions.first(where: { $0.id == sessionId })
        let previousModel = session?.model
        let fullModelId = model.id.hasPrefix("\(model.provider)/")
            ? model.id
            : "\(model.provider)/\(model.id)"

        // Optimistic update
        if var optimistic = session {
            optimistic.model = fullModelId
            sessionStore.upsert(optimistic)
        }

        Task { @MainActor in
            do {
                let modelId: String
                if model.id.hasPrefix("\(model.provider)/") {
                    modelId = String(model.id.dropFirst(model.provider.count + 1))
                } else {
                    modelId = model.id
                }

                try await connection.setModel(provider: model.provider, modelId: modelId)
                try? await connection.requestState()
            } catch {
                if var rollback = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                    rollback.model = previousModel
                    sessionStore.upsert(rollback)
                }
                reducer.process(.error(sessionId: sessionId, message: "Failed to set model: \(error.localizedDescription)"))
            }
        }
    }

    func rename(
        _ name: String,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        sessionId: String
    ) {
        guard let normalized = Self.normalizeManualSessionName(name) else { return }

        let session = sessionStore.sessions.first(where: { $0.id == sessionId })
        let previousName = session?.name

        // Optimistic update
        if var optimistic = session {
            optimistic.name = normalized
            sessionStore.upsert(optimistic)
        }

        Task { @MainActor in
            do {
                try await connection.setSessionName(normalized)
            } catch {
                if var rollback = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                    rollback.name = previousName
                    sessionStore.upsert(rollback)
                }
                reducer.process(.error(sessionId: sessionId, message: "Rename failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Helpers

    private func scheduleAutoSessionTitleIfNeeded(
        sessionId: String,
        connection: ServerConnection,
        sessionStore: SessionStore?
    ) {
        guard Self.isAutoTitleEnabled else { return }
        guard let sessionStore else { return }
        guard !autoTitleAttemptedSessionIds.contains(sessionId) else { return }

        // Use the session's recorded first message — not whatever the user
        // just typed.  This is the single source of truth and survives view
        // recreation, so even if this function fires on a later turn the
        // title always reflects the original intent.
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionId }),
              (session.name?.trimmingCharacters(in: .whitespacesAndNewlines))?.isEmpty ?? true else {
            return
        }

        let source = (session.firstMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }

        autoTitleAttemptedSessionIds.insert(sessionId)
        autoTitleTasksBySessionId[sessionId]?.cancel()

        autoTitleTasksBySessionId[sessionId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.autoTitleTasksBySessionId[sessionId] = nil }

            let limitedSource = String(source.prefix(600))
            let generated = await self.generateSessionTitle(from: limitedSource)
            guard !Task.isCancelled, let generated else { return }

            guard var latest = sessionStore.sessions.first(where: { $0.id == sessionId }),
                  (latest.name?.trimmingCharacters(in: .whitespacesAndNewlines))?.isEmpty ?? true else {
                return
            }

            let previousName = latest.name
            latest.name = generated
            sessionStore.upsert(latest)

            do {
                try await connection.setSessionName(generated)
            } catch {
                log.error("Auto title set_session_name failed: \(error.localizedDescription, privacy: .public)")
                if var rollback = sessionStore.sessions.first(where: { $0.id == sessionId }),
                   rollback.name == generated {
                    rollback.name = previousName
                    sessionStore.upsert(rollback)
                }
            }
        }
    }

    private func recoverPromptSendAfterReconnect(
        text: String,
        trimmedText: String,
        images: [PendingImage],
        attachments: [ImageAttachment],
        messageId: ChatItem.ID,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore?,
        sessionManager: ChatSessionManager,
        sessionId: String,
        onAsyncFailure: ((_ text: String, _ images: [PendingImage]) -> Void)?,
        onNeedsReconnect: (() -> Void)?
    ) async {
        clearSendStageNow()
        reconnectFailureMessage = nil

        let timeout = _reconnectRecoveryTimeoutForTesting ?? Self.reconnectRecoveryTimeout
        let pollInterval = _reconnectRecoveryPollIntervalForTesting ?? Self.reconnectRecoveryPollInterval
        let startedAt = ContinuousClock.now
        var lastRecoveryError: Error?
        var didRequestReconnect = false

        func requestReconnectIfNeeded() {
            didRequestReconnect = true
            onNeedsReconnect?()
        }

        requestReconnectIfNeeded()

        while ContinuousClock.now - startedAt < timeout {
            if Task.isCancelled {
                return
            }

            sendRecoveryText = Self.recoveryStatusText(
                sessionManager: sessionManager,
                connection: connection,
                sessionStore: sessionStore,
                sessionId: sessionId
            )

            if Self.didSessionStop(sessionStore: sessionStore, sessionId: sessionId) {
                let message = "Couldn't restore live session — it ended while reconnecting. Tap Resume to continue."
                completeRecoveredPromptFailure(
                    message: message,
                    originalText: text,
                    originalImages: images,
                    messageId: messageId,
                    reducer: reducer,
                    sessionId: sessionId,
                    onAsyncFailure: onAsyncFailure
                )
                return
            }

            if Self.canRetryRecoveredPrompt(
                sessionManager: sessionManager,
                connection: connection,
                sessionId: sessionId
            ) {
                do {
                    let promptImages = attachments.isEmpty ? nil : attachments
                    try await connection.sendPrompt(trimmedText, images: promptImages, onAckStage: { stage in
                        self.updateSendAckStage(stage)
                    })
                    sendRecoveryText = nil
                    reconnectFailureMessage = nil
                    scheduleSendStageClear()
                    scheduleAutoSessionTitleIfNeeded(
                        sessionId: sessionId,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                    return
                } catch {
                    lastRecoveryError = error
                    if Self.isReconnectableSendError(error) {
                        requestReconnectIfNeeded()
                        try? await Task.sleep(for: pollInterval)
                        continue
                    }

                    let message = Self.reconnectFailureMessage(
                        sessionManager: sessionManager,
                        connection: connection,
                        sessionStore: sessionStore,
                        sessionId: sessionId,
                        error: error,
                        reconnectWasRequested: didRequestReconnect
                    )
                    completeRecoveredPromptFailure(
                        message: message,
                        originalText: text,
                        originalImages: images,
                        messageId: messageId,
                        reducer: reducer,
                        sessionId: sessionId,
                        onAsyncFailure: onAsyncFailure
                    )
                    return
                }
            }

            try? await Task.sleep(for: pollInterval)
        }

        let message = Self.reconnectFailureMessage(
            sessionManager: sessionManager,
            connection: connection,
            sessionStore: sessionStore,
            sessionId: sessionId,
            error: lastRecoveryError,
            reconnectWasRequested: didRequestReconnect
        )
        completeRecoveredPromptFailure(
            message: message,
            originalText: text,
            originalImages: images,
            messageId: messageId,
            reducer: reducer,
            sessionId: sessionId,
            onAsyncFailure: onAsyncFailure
        )
    }

    private func completeRecoveredPromptFailure(
        message: String,
        originalText: String,
        originalImages: [PendingImage],
        messageId: ChatItem.ID,
        reducer: TimelineReducer,
        sessionId: String,
        onAsyncFailure: ((_ text: String, _ images: [PendingImage]) -> Void)?
    ) {
        clearSendStageNow()
        sendRecoveryText = nil
        reconnectFailureMessage = message

        log.error("SEND prompt recovery FAILED: \(message, privacy: .public)")
        ClientLog.error(
            "Action",
            "SEND prompt recovery FAILED",
            metadata: ["sessionId": sessionId, "reason": message]
        )

        onAsyncFailure?(originalText, originalImages)
        reducer.removeItem(id: messageId)
    }

    private static func canRetryRecoveredPrompt(
        sessionManager: ChatSessionManager,
        connection: ServerConnection,
        sessionId: String
    ) -> Bool {
        guard connection.wsClient?.status == .connected else { return false }
        guard connection.activeSessionId == sessionId else { return false }
        guard sessionManager.entryState == .streaming else { return false }
        return true
    }

    private static func didSessionStop(
        sessionStore: SessionStore?,
        sessionId: String
    ) -> Bool {
        sessionStore?.sessions.first(where: { $0.id == sessionId })?.status == .stopped
    }

    private static func recoveryStatusText(
        sessionManager: ChatSessionManager,
        connection: ServerConnection,
        sessionStore: SessionStore?,
        sessionId: String
    ) -> String {
        if didSessionStop(sessionStore: sessionStore, sessionId: sessionId) {
            return "Session ended"
        }

        if connection.wsClient?.status != .connected {
            return "Reconnecting…"
        }

        switch sessionManager.entryState {
        case .awaitingConnected:
            return "Restoring session…"
        case .idle, .loadingCache:
            return "Restoring session…"
        case .disconnected:
            return "Restoring session…"
        case .stopped:
            return "Session ended"
        case .streaming:
            return "Restoring session…"
        }
    }

    private static func reconnectFailureMessage(
        sessionManager: ChatSessionManager,
        connection: ServerConnection,
        sessionStore: SessionStore?,
        sessionId: String,
        error: Error?,
        reconnectWasRequested: Bool
    ) -> String {
        if didSessionStop(sessionStore: sessionStore, sessionId: sessionId) {
            return "Couldn't restore live session — it ended while reconnecting. Tap Resume to continue."
        }

        if let wsError = error as? WebSocketError {
            switch wsError {
            case .sendTimeout:
                return "Couldn't restore live session — the server took too long to respond."
            case .notConnected:
                break
            }
        }

        if let ackError = error as? SendAckError,
           case .timeout = ackError {
            return "Couldn't restore live session — the server did not acknowledge the retried send in time."
        }

        if connection.wsClient?.status != .connected {
            return reconnectWasRequested
                ? "Couldn't reconnect to the server — the connection kept dropping while we retried."
                : "Couldn't reconnect to the server."
        }

        switch sessionManager.entryState {
        case .awaitingConnected, .idle, .loadingCache:
            return "Couldn't restore live session — waking the session took too long."
        case .disconnected:
            return "Couldn't restore live session — the session stream closed again while reconnecting."
        case .stopped:
            return "Couldn't restore live session — it ended while reconnecting. Tap Resume to continue."
        case .streaming:
            if let error {
                return "Couldn't send after reconnect — \(error.localizedDescription)"
            }
            return "Couldn't send after reconnect."
        }
    }

    private func generateSessionTitle(from firstMessage: String) async -> String? {
        if let hook = _generateSessionTitleForTesting {
            let candidate = await hook(firstMessage)
            return Self.normalizeTitle(candidate)
        }

        return await Task.detached(priority: .utility) {
            await Self.generateSessionTitleOffMain(from: firstMessage)
        }.value
    }

    private static func generateSessionTitleOffMain(from firstMessage: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            log.error("Auto title: Foundation model not available")
            return nil
        }

        let prompt = """
            Create a concise session title from the first user message.

            <first_user_message>
            \(firstMessage)
            </first_user_message>
            """

        do {
            let session = LanguageModelSession(instructions: autoTitleInstructions)
            let response = try await session.respond(to: prompt)
            return normalizeTitle(response.content)
        } catch {
            log.error("Auto title error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Normalize a title: first line, strip common LLM artifacts, cap length.
    static func normalizeTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        // Take first line only
        if let newline = title.firstIndex(of: "\n") {
            title = String(title[..<newline])
        }

        // Strip "Title:" prefix LLMs sometimes add
        title = title.replacingOccurrences(
            of: #"(?i)^title\s*:\s*"#, with: "", options: .regularExpression
        )

        // Strip wrapping quotes and trailing punctuation
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{201c}\u{201d}\u{2018}\u{2019}[]() "))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))

        // Collapse whitespace
        title = title.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")

        // Cap length at word boundary
        if title.count > autoTitleMaxLength {
            let endIndex = title.index(title.startIndex, offsetBy: autoTitleMaxLength)
            title = String(title[..<endIndex])
            if let lastSpace = title.lastIndex(where: { $0.isWhitespace }) {
                title = String(title[..<lastSpace])
            }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
        }

        return title.isEmpty ? nil : title
    }

    private static func normalizeManualSessionName(_ raw: String) -> String? {
        normalizeTitle(raw)
    }

    private func beginSendTracking() {
        sendStageClearTask?.cancel()
        sendStageClearTask = nil
        sendAckStage = nil
        sendRecoveryText = nil
        reconnectFailureMessage = nil
        isSending = true
    }

    private func updateSendAckStage(_ stage: TurnAckStage) {
        sendAckStage = stage
        if stage == .started {
            scheduleSendStageClear()
        }
    }

    private func scheduleSendStageClear() {
        sendStageClearTask?.cancel()
        let delay = _sendStageDisplayDurationForTesting ?? Self.sendStageDisplayDuration
        sendStageClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sendAckStage = nil
            self?.sendStageClearTask = nil
        }
    }

    private func clearSendStageNow() {
        sendStageClearTask?.cancel()
        sendStageClearTask = nil
        sendAckStage = nil
    }

    func clearReconnectFailure() {
        reconnectFailureMessage = nil
    }

    private func launchTask(_ operation: @escaping @MainActor () async -> Void) {
        if let launchHook = _launchTaskForTesting {
            launchHook(operation)
            return
        }

        Task { @MainActor in
            await operation()
        }
    }

    private static func isReconnectableSendError(_ error: Error) -> Bool {
        if let wsError = error as? WebSocketError {
            switch wsError {
            case .notConnected, .sendTimeout:
                return true
            }
        }

        if let ackError = error as? SendAckError {
            switch ackError {
            case .timeout:
                return true
            case .rejected:
                return false
            }
        }

        return false
    }

    // MARK: - Cleanup

    func cleanup() {
        forceStopTask?.cancel()
        forceStopTask = nil

        // Do NOT cancel auto-title tasks here.  They are lightweight on-device
        // model calls that should be allowed to complete even when the user
        // navigates away.  Cancelling them was the root cause of the
        // "auto-rename fires on wrong message" bug: the task would get killed
        // on onDisappear, and when the view was recreated the ephemeral
        // autoTitleAttemptedSessionIds guard was lost, causing the next send
        // to re-trigger title generation from a later (wrong) message.

        sendRecoveryText = nil
        reconnectFailureMessage = nil
        clearSendStageNow()
        isSending = false
    }
}
