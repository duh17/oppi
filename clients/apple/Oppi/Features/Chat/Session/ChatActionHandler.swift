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
    private var forceStopTask: Task<Void, Never>?

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
    /// Key for auto-title provider (server / onDevice / off). Tests use this
    /// to select the on-device path that invokes the test hook.
    static let autoTitleProviderDefaultsKey = AppPreferences.Session.autoTitleProviderKey
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

    /// True while a send waits for the focused stream to (re)bind before dispatch.
    private(set) var isAwaitingSendReadiness = false

    /// Turn-ack never uses the composer caption; the optimistic user bubble is
    /// dispatch confirmation. Only the pre-dispatch reconnect wait is shown, so
    /// the kept draft reads as "connecting" rather than stuck.
    var sendProgressText: String? {
        isAwaitingSendReadiness ? "Connecting…" : nil
    }

    /// Last turn whose frame was sent but never acknowledged. An identical resend
    /// (same session, command, text, attachments) from this chat screen reuses
    /// its clientTurnId, so the server's existing turn dedupe can recognize it.
    /// Bounded guarantee: held only by this handler (lost when the screen goes
    /// away) and only effective while the server still caches that turn id for
    /// the live session. User copy therefore promises nothing about duplicates.
    private struct UnconfirmedTurn: Equatable {
        let sessionId: String
        let command: String
        let message: String
        let attachments: [ChatAttachmentRef]?
        let clientTurnId: String
    }

    private var unconfirmedTurn: UnconfirmedTurn?

    // MARK: - Prompt / Steer

    /// Send a user prompt or steer the running agent.
    ///
    /// Returns the input text to restore on failure, or empty string on success.
    func sendPrompt(
        text: String,
        attachments: [ChatAttachmentRef],
        optimisticDisplayText: String? = nil,
        optimisticImages: [ImageAttachment] = [],
        isBusy: Bool,
        busyStreamingBehavior: StreamingBehavior = .steer,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String,
        sessionStore: SessionStore? = nil,
        sessionManager: ChatSessionManager? = nil,
        onDispatchStarted: (() -> Void)? = nil,
        onSendSucceeded: (() -> Void)? = nil,
        onAsyncFailure: ((_ text: String, _ attachments: [ChatAttachmentRef]) -> Void)? = nil,
        onNeedsReconnect: (() -> Void)? = nil
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return text }
        guard !isSending else { return text }

        isSending = true
        // Dispatch needs this chat's own live focused socket, re-checked inside
        // the task right before sending. Otherwise the stream is (re)bound first
        // and nothing is dispatched or shown as sent until it is ready.
        let readinessStore = sessionStore ?? connection.sessionStore
        let isReadyAtTap = sessionManager?.isReadyForTurnDispatch ?? true
        let sendAttachments = attachments.isEmpty ? nil : attachments

        if isBusy {
            AppHaptics.impact(style: .soft)

            let queuedAttachments = sendAttachments
            let queuedKind: MessageQueueKind = busyStreamingBehavior == .steer ? .steer : .followUp
            let commandName = busyStreamingBehavior == .steer ? "steer" : "follow_up"
            let queueTurnId = clientTurnId(
                sessionId: sessionId,
                command: commandName,
                message: trimmed,
                attachments: queuedAttachments
            )
            let enqueueOptimisticItem = {
                connection.messageQueueStore.enqueueOptimisticItem(
                    for: sessionId,
                    kind: queuedKind,
                    message: trimmed,
                    attachments: queuedAttachments,
                    optimisticImages: optimisticImages.isEmpty ? nil : optimisticImages,
                    id: queueTurnId
                )
            }
            let preDispatchQueueItem = isReadyAtTap ? enqueueOptimisticItem() : nil

            launchTask { @MainActor in
                self.beginSendTracking()
                defer { self.isSending = false }
                if let readinessError = await self.awaitSendReadiness(
                    sessionManager,
                    connection: connection,
                    sessionStore: readinessStore
                ) {
                    if let preDispatchQueueItem {
                        connection.messageQueueStore.removeQueuedItem(
                            for: sessionId,
                            kind: queuedKind,
                            id: preDispatchQueueItem.id,
                            messageFallback: trimmed
                        )
                    }
                    self.failNotDispatched(
                        command: commandName,
                        error: readinessError,
                        sessionId: sessionId,
                        reducer: reducer
                    )
                    onAsyncFailure?(text, attachments)
                    return
                }
                let optimisticQueueItem = preDispatchQueueItem ?? enqueueOptimisticItem()
                onDispatchStarted?()

                do {
                    switch busyStreamingBehavior {
                    case .steer:
                        try await connection.sendSteer(trimmed, attachments: queuedAttachments, clientTurnId: queueTurnId, sessionIdOverride: sessionId, onAckStage: { stage in
                            self.updateSendAckStage(stage)
                        })
                    case .followUp:
                        try await connection.sendFollowUp(trimmed, attachments: queuedAttachments, clientTurnId: queueTurnId, sessionIdOverride: sessionId, onAckStage: { stage in
                            self.updateSendAckStage(stage)
                        })
                    }
                    self.clearUnconfirmedTurn(clientTurnId: queueTurnId)
                    onSendSucceeded?()
                    Task { @MainActor in
                        try? await connection.requestMessageQueue(sessionIdOverride: sessionId)
                    }
                } catch {
                    connection.messageQueueStore.removeQueuedItem(
                        for: sessionId,
                        kind: queuedKind,
                        id: optimisticQueueItem.id,
                        messageFallback: trimmed
                    )
                    self.clearSendStageNow()
                    self.recordUnconfirmedTurnIfNeeded(
                        error,
                        sessionId: sessionId,
                        command: commandName,
                        message: trimmed,
                        attachments: queuedAttachments,
                        clientTurnId: queueTurnId
                    )
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
                    onAsyncFailure?(text, attachments)
                    reducer.process(.error(
                        sessionId: sessionId,
                        message: Self.sendFailureMessage(error, prefix: "\(errorPrefix) failed")
                    ))
                }
            }
        } else {
            AppHaptics.impact(style: .light)
            let promptTurnId = clientTurnId(
                sessionId: sessionId,
                command: "prompt",
                message: trimmed,
                attachments: sendAttachments
            )

            launchTask { @MainActor in
                self.beginSendTracking()
                if let readinessError = await self.awaitSendReadiness(
                    sessionManager,
                    connection: connection,
                    sessionStore: readinessStore
                ) {
                    self.failNotDispatched(
                        command: "prompt",
                        error: readinessError,
                        sessionId: sessionId,
                        reducer: reducer
                    )
                    onAsyncFailure?(text, attachments)
                    self.isSending = false
                    return
                }

                let optimisticText = optimisticDisplayText ?? trimmed
                let messageId: ChatItem.ID? = if !optimisticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty {
                    reducer.appendUserMessage(optimisticText, images: optimisticImages)
                } else {
                    nil
                }
                // Same turn as the optimistic row. Deferring this left the
                // sent draft in the composer until the ack, which can take
                // seconds after the message is already visible.
                onDispatchStarted?()
                do {
                    try await connection.sendPrompt(trimmed, attachments: sendAttachments, clientTurnId: promptTurnId, sessionIdOverride: sessionId, onAckStage: { stage in
                        self.updateSendAckStage(stage)
                    })
                    self.clearUnconfirmedTurn(clientTurnId: promptTurnId)
                    onSendSucceeded?()
                    self.scheduleAutoSessionTitleIfNeeded(
                        sessionId: sessionId,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                } catch {
                    self.clearSendStageNow()
                    self.recordUnconfirmedTurnIfNeeded(
                        error,
                        sessionId: sessionId,
                        command: "prompt",
                        message: trimmed,
                        attachments: sendAttachments,
                        clientTurnId: promptTurnId
                    )
                    log.error("SEND prompt FAILED: \(error.localizedDescription, privacy: .public)")
                    ClientLog.error(
                        "Action",
                        "SEND prompt FAILED",
                        metadata: ["sessionId": sessionId, "error": error.localizedDescription]
                    )
                    if Self.isReconnectableSendError(error) {
                        onNeedsReconnect?()
                    }
                    onAsyncFailure?(text, attachments)
                    if let messageId {
                        reducer.removeItem(id: messageId)
                    }
                    reducer.process(.error(
                        sessionId: sessionId,
                        message: Self.sendFailureMessage(error, prefix: "Failed to send")
                    ))
                }

                self.isSending = false
            }
        }

        return ""
    }

    func shareSession(
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String,
        redactionPolicy: ShareSessionRedactionPolicy = .recommended,
        onDispatchStarted: (() -> Void)? = nil,
        onSendSucceeded: (() -> Void)? = nil,
        onAsyncFailure: (() -> Void)? = nil,
        onNeedsReconnect: (() -> Void)? = nil
    ) {
        guard !isSending else { return }
        isSending = true

        launchTask { @MainActor in
            self.beginSendTracking()
            defer { self.isSending = false }
            onDispatchStarted?()

            do {
                guard let published = try await connection.shareSession(
                    redactionPolicy: redactionPolicy.normalized
                ) else {
                    throw CommandRequestError.rejected(
                        command: "share_session",
                        reason: "server returned an empty response"
                    )
                }

                connection.extensionToast = Self.shareSessionToastMessage(
                    link: published.link,
                    redaction: published.redaction
                )
                onSendSucceeded?()
            } catch {
                self.clearSendStageNow()
                log.error("SHARE session FAILED: \(error.localizedDescription, privacy: .public)")
                ClientLog.error(
                    "Action",
                    "SHARE session FAILED",
                    metadata: ["sessionId": sessionId, "error": error.localizedDescription]
                )
                if Self.isReconnectableSendError(error) {
                    onNeedsReconnect?()
                }
                onAsyncFailure?()
                reducer.process(
                    .error(sessionId: sessionId, message: "Share failed: \(error.localizedDescription)")
                )
            }
        }
    }

    private static func shareSessionToastMessage(
        link: SharedSessionLink,
        redaction: ShareSessionRedactionReport?
    ) -> String {
        var lines = [
            "Share URL: \(link.shareURL)",
            "Gist: \(link.gistURL)",
        ]

        guard let redaction, redaction.totalReplacements > 0 else {
            lines.append("Redaction: none")
            return lines.joined(separator: "\n")
        }

        lines.append("Redaction: \(redaction.totalReplacements) replacements")
        for finding in redaction.findings.prefix(5) {
            var detail = "• \(finding.kind)×\(finding.count) → \(finding.replacement)"
            if let sample = finding.samples.first, !sample.isEmpty {
                detail += " (\(sample))"
            }
            lines.append(detail)
        }

        if redaction.findings.count > 5 {
            lines.append("• … \(redaction.findings.count - 5) more")
        }

        return lines.joined(separator: "\n")
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

            guard let routeScope = sessionStore.routeScope(for: sessionId) else {
                reducer.process(.error(sessionId: sessionId, message: "Missing session route context"))
                return
            }

            do {
                let updated = try await api.resumeSession(
                    scope: routeScope,
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
        guard connection.isFocusedSession(sessionId) else {
            reducer.process(
                .error(
                    sessionId: sessionId,
                    message: "Failed to stop: \(WebSocketError.notConnected.localizedDescription)"
                )
            )
            return
        }

        isStopping = true
        showForceStop = false

        forceStopTask?.cancel()
        forceStopTask = nil

        Task { @MainActor in
            do {
                if let sendStopHook = self._sendStopForTesting {
                    try await sendStopHook(connection)
                } else {
                    try await connection.sendStop(sessionIdOverride: sessionId)
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
                    try await connection.sendStopSession(sessionIdOverride: sessionId)
                }
                reducer.appendSystemEvent("Session stopped")
            } catch {
                if let api = connection.apiClient,
                   let routeScope = sessionStore.routeScope(for: sessionId) {
                    do {
                        let updatedSession = try await api.stopSession(scope: routeScope, sessionId: sessionId)
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
        reconnectFailureMessage = nil
        clearSendStageNow()
    }

    // MARK: - Model / Thinking / Context

    func setThinking(
        _ level: ThinkingLevel,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String,
        persist: Bool = false
    ) {
        if persist, connection.sessionStore.sessions.first(where: { $0.id == sessionId })?.supportsPersistingDefaults == false {
            reducer.process(
                .error(sessionId: sessionId, message: SessionRuntimeKind.persistUnsupportedMessage)
            )
            return
        }
        Task {
            do {
                try await connection.setThinkingLevel(level, persist: persist)
                try? await connection.requestState()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Failed to set thinking: \(error.localizedDescription)"))
            }
        }
    }

    func compact(
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String,
        onSendSucceeded: (() -> Void)? = nil,
        onAsyncFailure: (() -> Void)? = nil
    ) {
        Task { @MainActor in
            // Show immediate "Compacting context..." indicator before the server responds.
            reducer.process(.compactionStart(sessionId: sessionId, reason: "manual"))
            do {
                try await connection.compact()
                onSendSucceeded?()
                try? await connection.requestState()
            } catch {
                onAsyncFailure?()
                reducer.process(.error(sessionId: sessionId, message: "Compact failed: \(error.localizedDescription)"))
            }
        }
    }

    func reloadResources(
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        sessionId: String,
        onSendSucceeded: (() -> Void)? = nil,
        onAsyncFailure: (() -> Void)? = nil
    ) {
        Task { @MainActor in
            do {
                try await connection.reloadResources()
                onSendSucceeded?()
                try? await connection.requestState()
                if let session = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                    await connection.refreshSlashCommands(for: session, force: true)
                }
                connection.extensionToast = "Reloaded tools, extensions, skills, and prompts."
            } catch {
                onAsyncFailure?()
                reducer.process(.error(sessionId: sessionId, message: "Reload failed: \(error.localizedDescription)"))
            }
        }
    }

    func setModel(
        _ model: ModelInfo,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionStore: SessionStore,
        sessionId: String,
        persist: Bool = false
    ) {
        let session = sessionStore.sessions.first(where: { $0.id == sessionId })
        if persist, session?.supportsPersistingDefaults == false {
            reducer.process(
                .error(sessionId: sessionId, message: SessionRuntimeKind.persistUnsupportedMessage)
            )
            return
        }
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

                try await connection.setModel(provider: model.provider, modelId: modelId, persist: persist)
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
        let provider = AppPreferences.Session.autoTitleProvider

        // Off → skip entirely. Server → server handles it via get_state sync.
        guard provider == .onDevice else { return }
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

    private func clientTurnId(
        sessionId: String,
        command: String,
        message: String,
        attachments: [ChatAttachmentRef]?
    ) -> String {
        if let unconfirmedTurn,
           unconfirmedTurn.sessionId == sessionId,
           unconfirmedTurn.command == command,
           unconfirmedTurn.message == message,
           unconfirmedTurn.attachments == attachments {
            return unconfirmedTurn.clientTurnId
        }
        return UUID().uuidString
    }

    private func recordUnconfirmedTurnIfNeeded(
        _ error: Error,
        sessionId: String,
        command: String,
        message: String,
        attachments: [ChatAttachmentRef]?,
        clientTurnId: String
    ) {
        guard error is TurnSendUnconfirmedError else { return }
        unconfirmedTurn = UnconfirmedTurn(
            sessionId: sessionId,
            command: command,
            message: message,
            attachments: attachments,
            clientTurnId: clientTurnId
        )
    }

    private func clearUnconfirmedTurn(clientTurnId: String) {
        if unconfirmedTurn?.clientTurnId == clientTurnId {
            unconfirmedTurn = nil
        }
    }

    /// Validate this chat's focused stream immediately before dispatch, waiting
    /// for it when needed. Returns the error when it never became ready; nothing
    /// was sent in that case.
    ///
    /// `sessionManager` stayed optional: ChatView, the only production sender,
    /// always passes its runtime. With no runtime there is no focus claim to
    /// validate, so the send relies on the transport's own pre-dispatch checks
    /// (no focused session or socket fails fast as never dispatched). That keeps
    /// the dispatch/ack unit tests independent of a scripted chat runtime.
    private func awaitSendReadiness(
        _ sessionManager: ChatSessionManager?,
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> Error? {
        guard let sessionManager, !sessionManager.isReadyForTurnDispatch else { return nil }
        isAwaitingSendReadiness = true
        defer { isAwaitingSendReadiness = false }
        do {
            try await sessionManager.ensureReadyForSend(
                connection: connection,
                sessionStore: sessionStore
            )
            return nil
        } catch {
            return error
        }
    }

    private func failNotDispatched(
        command: String,
        error: Error,
        sessionId: String,
        reducer: TimelineReducer
    ) {
        clearSendStageNow()
        log.error("SEND \(command, privacy: .public) NOT DISPATCHED: \(error.localizedDescription, privacy: .public)")
        ClientLog.error(
            "Action",
            "SEND \(command) NOT DISPATCHED",
            metadata: ["sessionId": sessionId, "error": error.localizedDescription]
        )
        reducer.process(.error(
            sessionId: sessionId,
            message: "Not sent: \(error.localizedDescription) Your message is still in the composer."
        ))
    }

    private static func sendFailureMessage(_ error: Error, prefix: String) -> String {
        if error is TurnSendUnconfirmedError {
            return "Couldn't confirm your message was delivered. It's still in the composer; check the conversation before sending it again."
        }
        return "\(prefix): \(error.localizedDescription)"
    }

    private func beginSendTracking() {
        sendAckStage = nil
        reconnectFailureMessage = nil
        isSending = true
    }

    private func updateSendAckStage(_ stage: TurnAckStage) {
        sendAckStage = stage
    }

    private func clearSendStageNow() {
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
        if let unconfirmed = error as? TurnSendUnconfirmedError {
            return isReconnectableSendError(unconfirmed.underlying)
        }
        if let wsError = error as? WebSocketError {
            switch wsError {
            case .notConnected, .sendTimeout:
                return true
            case .encodingFailed:
                return false
            }
        }

        if let ackError = error as? SendAckError {
            switch ackError {
            case .timeout(let command):
                return command != "prompt"
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

        reconnectFailureMessage = nil
        clearSendStageNow()
        isSending = false
        isAwaitingSendReadiness = false
    }
}
