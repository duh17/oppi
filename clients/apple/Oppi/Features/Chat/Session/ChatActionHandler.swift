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

    private static let sendStageDisplayDuration: Duration = .seconds(1.2)

    /// Test seam: shorten send-stage display retention.
    var _sendStageDisplayDurationForTesting: Duration?

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

        return isSending ? "Sending…" : nil
    }

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

        if isBusy {
            AppHaptics.impact(style: .soft)

            let queuedAttachments = attachments.isEmpty ? nil : attachments
            let queuedKind: MessageQueueKind = busyStreamingBehavior == .steer ? .steer : .followUp
            let queueTurnId = UUID().uuidString
            let optimisticQueueItem = connection.messageQueueStore.enqueueOptimisticItem(
                for: sessionId,
                kind: queuedKind,
                message: trimmed,
                attachments: queuedAttachments,
                optimisticImages: optimisticImages.isEmpty ? nil : optimisticImages,
                id: queueTurnId
            )

            launchTask { @MainActor in
                self.beginSendTracking()
                defer { self.isSending = false }
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
                    onSendSucceeded?()
                    self.scheduleSendStageClear()
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
                    onAsyncFailure?(text, attachments)
                    reducer.process(.error(sessionId: sessionId, message: "\(errorPrefix) failed: \(error.localizedDescription)"))
                }
            }
        } else {
            AppHaptics.impact(style: .light)
            let promptTurnId = UUID().uuidString

            launchTask { @MainActor in
                self.beginSendTracking()

                let optimisticText = optimisticDisplayText ?? trimmed
                let messageId: ChatItem.ID? = if !optimisticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty {
                    reducer.appendUserMessage(optimisticText, images: optimisticImages)
                } else {
                    nil
                }
                if let onDispatchStarted {
                    DispatchQueue.main.async {
                        onDispatchStarted()
                    }
                }
                do {
                    let promptAttachments = attachments.isEmpty ? nil : attachments
                    try await connection.sendPrompt(trimmed, attachments: promptAttachments, clientTurnId: promptTurnId, sessionIdOverride: sessionId, onAckStage: { stage in
                        self.updateSendAckStage(stage)
                    })
                    onSendSucceeded?()
                    self.scheduleSendStageClear()
                    self.scheduleAutoSessionTitleIfNeeded(
                        sessionId: sessionId,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                } catch {
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
                    onAsyncFailure?(text, attachments)
                    if let messageId {
                        reducer.removeItem(id: messageId)
                    }
                    reducer.process(.error(sessionId: sessionId, message: "Failed to send: \(error.localizedDescription)"))
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
                self.scheduleSendStageClear()
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

    private func beginSendTracking() {
        sendStageClearTask?.cancel()
        sendStageClearTask = nil
        sendAckStage = nil
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
    }
}
