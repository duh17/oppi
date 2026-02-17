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
    private var sendStageClearTask: Task<Void, Never>?
    private var forceStopTask: Task<Void, Never>?

    private static let sendStageDisplayDuration: Duration = .seconds(1.2)

    /// Test seam: shorten send-stage display retention.
    var _sendStageDisplayDurationForTesting: Duration?

    /// Test seam: override async task launch to simulate scheduling races.
    var _launchTaskForTesting: (((@escaping @MainActor () async -> Void)) -> Void)?

    /// Test seam: override auto title generation.
    var _generateSessionTitleForTesting: ((String) async -> String?)?

    private var autoTitleTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var autoTitleAttemptedSessionIds: Set<String> = []

    private static let autoTitleSourceLimit = 600
    private static let autoTitleMaxLength = 48
    private static let autoTitleMaxWords = 6
    static let autoTitleEnabledDefaultsKey = "\(AppIdentifiers.subsystem).session.autoTitle.enabled"
    private static var isAutoTitleEnabled: Bool {
        UserDefaults.standard.object(forKey: autoTitleEnabledDefaultsKey) as? Bool ?? true
    }
    private static let autoTitleInstructions = """
        You create concise coding session titles.
        Return only the title text.
        Rules:
        - 2 to 5 words.
        - Focus on one concrete objective.
        - No quotes, markdown, or trailing punctuation.
        - For TODO/task-list/planning sessions, start with "TODO:" then 2 to 4 words.
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
        images: [PendingImage],
        isBusy: Bool,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String,
        sessionStore: SessionStore? = nil,
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

            launchTask { @MainActor in
                self.beginSendTracking()
                defer { self.isSending = false }
                onDispatchStarted?()

                let label = attachments.isEmpty
                    ? "→ \(trimmed)"
                    : "→ \(trimmed) [\(attachments.count) image\(attachments.count == 1 ? "" : "s")]"
                reducer.appendSystemEvent(label)

                do {
                    let steerImages = attachments.isEmpty ? nil : attachments
                    try await connection.sendSteer(trimmed, images: steerImages, onAckStage: { stage in
                        self.updateSendAckStage(stage)
                    })
                    self.scheduleSendStageClear()
                } catch {
                    self.clearSendStageNow()
                    log.error("SEND steer FAILED: \(error.localizedDescription, privacy: .public)")
                    ClientLog.error(
                        "Action",
                        "SEND steer FAILED",
                        metadata: ["sessionId": sessionId, "error": error.localizedDescription]
                    )
                    if Self.isReconnectableSendError(error) {
                        onNeedsReconnect?()
                    }
                    onAsyncFailure?(text, images)
                    reducer.process(.error(sessionId: sessionId, message: "Steer failed: \(error.localizedDescription)"))
                }
            }
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

            launchTask { @MainActor in
                self.beginSendTracking()
                defer { self.isSending = false }

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
                        firstMessage: trimmed,
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
                    onAsyncFailure?(text, images)
                    reducer.removeItem(id: messageId)
                    reducer.process(.error(sessionId: sessionId, message: "Failed to send: \(error.localizedDescription)"))
                }
            }
        }

        return ""
    }

    // MARK: - Bash

    func sendBash(
        _ command: String,
        connection: ServerConnection,
        reducer: TimelineReducer,
        sessionId: String
    ) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        reducer.appendSystemEvent("$ \(command)")

        Task { @MainActor in
            do {
                try await connection.runBash(command)
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Bash failed: \(error.localizedDescription)"))
            }
        }
    }

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
                try await connection.sendStop()
            } catch {
                isStopping = false
                reducer.process(.error(sessionId: sessionId, message: "Failed to stop: \(error.localizedDescription)"))
                return
            }

            forceStopTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if let status = sessionStore.sessions.first(where: { $0.id == sessionId })?.status,
                   status == .busy || status == .stopping {
                    showForceStop = true
                }
            }

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
                try await connection.sendStopSession()
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
            do {
                try await connection.compact()
                try? await connection.requestState()
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Compact failed: \(error.localizedDescription)"))
            }
        }
    }

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
        firstMessage: String,
        sessionId: String,
        connection: ServerConnection,
        sessionStore: SessionStore?
    ) {
        guard Self.isAutoTitleEnabled else { return }
        guard let sessionStore else { return }

        let source = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        guard !autoTitleAttemptedSessionIds.contains(sessionId) else { return }
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionId }),
              Self.shouldAutoTitle(session: session) else {
            return
        }

        autoTitleAttemptedSessionIds.insert(sessionId)
        autoTitleTasksBySessionId[sessionId]?.cancel()

        autoTitleTasksBySessionId[sessionId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.autoTitleTasksBySessionId[sessionId] = nil }

            let limitedSource = String(source.prefix(Self.autoTitleSourceLimit))
            let generated = await self.generateSessionTitle(from: limitedSource)
            guard !Task.isCancelled, let generated else { return }

            guard var latest = sessionStore.sessions.first(where: { $0.id == sessionId }),
                  Self.shouldAutoTitle(session: latest) else {
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

    /// Whether a session is eligible for auto-titling.
    ///
    /// Only checks that no name has been set. The `autoTitleAttemptedSessionIds`
    /// guard in the caller ensures we only attempt once per session per app run.
    /// We intentionally do NOT gate on messageCount — fast models (codex) fire
    /// message_end events that increment the count before the auto-title logic
    /// even gets scheduled.
    private static func shouldAutoTitle(session: Session) -> Bool {
        if let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return false
        }
        return true
    }

    private func generateSessionTitle(from firstMessage: String) async -> String? {
        if let hook = _generateSessionTitleForTesting {
            let candidate = await hook(firstMessage)
            return Self.normalizeAutoTitle(candidate, sourceMessage: firstMessage)
        }

        return await Task.detached(priority: .utility) {
            await Self.generateSessionTitleOffMain(from: firstMessage)
        }.value
    }

    private static func generateSessionTitleOffMain(from firstMessage: String) async -> String? {
        let fallback = heuristicTitle(from: firstMessage)

        let model = SystemLanguageModel.default
        let availability = model.availability
        guard case .available = availability else {
            log.error("Auto title: Foundation model not available — \(String(describing: availability), privacy: .public), fallbackLen=\(fallback?.count ?? 0, privacy: .public)")
            return fallback
        }

        let prompt = """
            Create a short session title from this first user message.

            First user message:
            \(firstMessage)
            """

        do {
            let session = LanguageModelSession(instructions: autoTitleInstructions)
            let response = try await session.respond(to: prompt)
            let raw = response.content
            let normalized = normalizeAutoTitle(raw, sourceMessage: firstMessage)
            log.error("Auto title: Foundation model produced rawLen=\(raw.count, privacy: .public) normalized=\(normalized != nil, privacy: .public)")
            return normalized ?? fallback
        } catch {
            log.error("Auto title: Foundation model error — \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    private static func heuristicTitle(from firstMessage: String) -> String? {
        let collapsed = collapseWhitespace(firstMessage)
        guard !collapsed.isEmpty else { return nil }

        let firstLine = collapsed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? collapsed
        let tokens = firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(autoTitleMaxWords)
            .map(String.init)
            .joined(separator: " ")

        return normalizeAutoTitle(tokens, sourceMessage: firstMessage)
    }

    private static func normalizeAutoTitle(_ raw: String?, sourceMessage: String) -> String? {
        guard var title = sanitizeTitle(raw) else { return nil }

        if isTodoSessionPrompt(sourceMessage) {
            title = ensureTodoPrefix(title)
        }

        title = limitWordCount(title, maxWords: autoTitleMaxWords)

        if title.count > autoTitleMaxLength {
            title = truncateTitle(title, maxLength: autoTitleMaxLength)
        }

        guard !title.isEmpty else { return nil }
        return title
    }

    private static func sanitizeTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        if let newline = title.firstIndex(of: "\n") {
            title = String(title[..<newline])
        }

        title = title.replacingOccurrences(
            of: #"(?i)^title\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"^\s*[-*•]\s*"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"^\s*\d+\s*[\).:-]\s*"#,
            with: "",
            options: .regularExpression
        )
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’[]() "))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
        title = collapseWhitespace(title)

        guard !title.isEmpty else { return nil }
        return title
    }

    private static func isTodoSessionPrompt(_ sourceMessage: String) -> Bool {
        sourceMessage.range(
            of: #"(?i)\b(todo|to[- ]do|task(?: list|s)?|checklist|action items?|next steps?|planning)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func ensureTodoPrefix(_ title: String) -> String {
        var core = title.replacingOccurrences(
            of: #"(?i)^(?:todo|to[- ]do|task(?: list|s)?)\s*[:\-]?\s*"#,
            with: "",
            options: .regularExpression
        )
        core = core.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return "TODO" }
        return "TODO: \(core)"
    }

    private static func limitWordCount(_ text: String, maxWords: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).map(String.init).joined(separator: " ")
    }

    private static func truncateTitle(_ title: String, maxLength: Int) -> String {
        guard title.count > maxLength else { return title }

        let endIndex = title.index(title.startIndex, offsetBy: maxLength)
        var truncated = String(title[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

        let cutMidWord: Bool = {
            guard endIndex < title.endIndex else { return false }
            let next = title[endIndex]
            let prev = title[title.index(before: endIndex)]
            return !next.isWhitespace && !prev.isWhitespace
        }()

        if cutMidWord,
           let lastSpace = truncated.lastIndex(where: { $0.isWhitespace }) {
            truncated = String(truncated[..<lastSpace])
        }

        truncated = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
        truncated = truncated.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?-"))

        if truncated.isEmpty {
            return String(title[..<endIndex]).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?- "))
        }

        return truncated
    }

    private static func normalizeManualSessionName(_ raw: String) -> String? {
        var title = collapseWhitespace(raw)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        if title.count > autoTitleMaxLength {
            title = truncateTitle(title, maxLength: autoTitleMaxLength)
        }

        guard !title.isEmpty else { return nil }
        return title
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private func beginSendTracking() {
        sendStageClearTask?.cancel()
        sendStageClearTask = nil
        sendAckStage = nil
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

        for task in autoTitleTasksBySessionId.values {
            task.cancel()
        }
        autoTitleTasksBySessionId.removeAll()

        clearSendStageNow()
        isSending = false
    }
}
