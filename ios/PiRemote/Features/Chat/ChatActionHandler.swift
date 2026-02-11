import FoundationModels
import os.log
import SwiftUI

private let log = Logger(subsystem: "dev.chenda.PiRemote", category: "Action")

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
    private static let autoTitleMaxLength = 64
    static let autoTitleEnabledDefaultsKey = "dev.chenda.PiRemote.session.autoTitle.enabled"
    private static var isAutoTitleEnabled: Bool {
        UserDefaults.standard.object(forKey: autoTitleEnabledDefaultsKey) as? Bool ?? true
    }
    private static let autoTitleInstructions = """
        You create concise coding session titles.
        Return only the title text.
        Use 2 to 6 words.
        No quotes, no markdown, no trailing punctuation.
        """

    private static let quickReplySuggestionInstructions = """
        You extract actionable TODO items from assistant responses.
        Return only TODO items found in the provided text.
        If there are no TODO items, return exactly: NONE
        Keep each TODO concise and concrete.
        """

    private static let quickReplyBenchmarkInstructions = """
        You generate short user replies to an assistant.
        Prefer replies that encourage questioning, risk checks, and learning.
        Keep each reply to one sentence.
        Return only the reply text.
        """

    private static let quickReplyBenchmarkPrompt = """
        Assistant reply:
        Here is the migration plan. Step 1 updates schemas, step 2 backfills data,
        step 3 flips reads to v2, and step 4 removes v1 tables.

        Generate a single user reply that asks for risks and tradeoffs before approval.
        """

    private static let quickReplyGenerationOptions = GenerationOptions(
        sampling: .greedy,
        temperature: 0,
        maximumResponseTokens: 96
    )

    /// Keep quick-reply extraction deterministic and instant by default.
    /// Enable only if heuristic extraction misses too often.
    private static let quickReplyModelFallbackEnabled = false

    private actor QuickReplySuggestionCache {
        private var suggestionsByKey: [String: [String]] = [:]

        func value(for key: String) -> [String]? {
            suggestionsByKey[key]
        }

        func set(_ suggestions: [String], for key: String) {
            suggestionsByKey[key] = suggestions
        }
    }

    private static let quickReplySuggestionCache = QuickReplySuggestionCache()

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
                if let api = connection.apiClient {
                    do {
                        let updatedSession = try await api.stopSession(id: sessionId)
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = sessionStore.sessions.first(where: { $0.id == sessionId })
        let previousName = session?.name

        // Optimistic update
        if var optimistic = session {
            optimistic.name = trimmed
            sessionStore.upsert(optimistic)
        }

        Task { @MainActor in
            do {
                try await connection.setSessionName(trimmed)
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

    private static func shouldAutoTitle(session: Session) -> Bool {
        if let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return false
        }
        return session.messageCount <= 1
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
        let fallback = heuristicTitle(from: firstMessage)

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
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
            return normalizeTitle(response.content) ?? fallback
        } catch {
            log.error("Auto title generation failed: \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    func cachedQuickReplySuggestions(cacheKey: String) async -> [String]? {
        await Self.quickReplySuggestionCache.value(for: cacheKey)
    }

    func generateQuickReplySuggestions(
        assistantText: String,
        recentUserReplies: [String],
        limit: Int = QuickReplySuggester.maxSuggestions,
        cacheKey: String? = nil
    ) async -> [String] {
        if let cacheKey,
           let cached = await Self.quickReplySuggestionCache.value(for: cacheKey) {
            return cached
        }

        let generated = await Task.detached(priority: .utility) {
            await Self.generateQuickReplySuggestionsOffMain(
                assistantText: assistantText,
                recentUserReplies: recentUserReplies,
                limit: limit
            )
        }.value

        if let cacheKey {
            await Self.quickReplySuggestionCache.set(generated, for: cacheKey)
        }

        return generated
    }

    private static func generateQuickReplySuggestionsOffMain(
        assistantText: String,
        recentUserReplies: [String],
        limit: Int
    ) async -> [String] {
        let extractedTodos = QuickReplySuggester.suggestions(
            forAssistantText: assistantText,
            recentUserReplies: recentUserReplies,
            limit: limit
        )

        if !extractedTodos.isEmpty {
            return extractedTodos
        }

        guard quickReplyModelFallbackEnabled else {
            return extractedTodos
        }

        guard QuickReplySuggester.shouldAttemptModelTodoExtraction(forAssistantText: assistantText) else {
            return extractedTodos
        }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return extractedTodos
        }

        let prompt = QuickReplySuggester.makeModelPrompt(
            forAssistantText: assistantText,
            recentUserReplies: recentUserReplies,
            limit: limit
        )

        do {
            let session = LanguageModelSession(instructions: quickReplySuggestionInstructions)
            let response = try await session.respond(to: prompt, options: quickReplyGenerationOptions)
            let modelCandidates = QuickReplySuggester.parseModelOutput(response.content)

            return QuickReplySuggester.suggestions(
                forAssistantText: assistantText,
                recentUserReplies: recentUserReplies,
                modelCandidates: modelCandidates,
                limit: limit
            )
        } catch {
            log.error("Quick reply generation failed: \(error.localizedDescription, privacy: .public)")
            return extractedTodos
        }
    }

    func benchmarkOnDeviceQuickReplyModel(iterations: Int = 5) async -> String {
        await Task.detached(priority: .utility) {
            await Self.benchmarkOnDeviceQuickReplyModelOffMain(iterations: iterations)
        }.value
    }

    private static func benchmarkOnDeviceQuickReplyModelOffMain(iterations: Int) async -> String {
        let runCount = max(iterations, 1)
        let model = SystemLanguageModel.default

        guard case .available = model.availability else {
            return "On-device model unavailable: \(String(describing: model.availability))"
        }

        let session = LanguageModelSession(instructions: quickReplyBenchmarkInstructions)
        var latenciesMs: [Int] = []
        latenciesMs.reserveCapacity(runCount)

        for _ in 0..<runCount {
            let startedAt = Date()

            do {
                _ = try await session.respond(to: quickReplyBenchmarkPrompt)
            } catch {
                return "On-device model benchmark failed: \(error.localizedDescription)"
            }

            let elapsedMs = Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
            latenciesMs.append(max(elapsedMs, 0))
        }

        guard !latenciesMs.isEmpty else {
            return "On-device model benchmark produced no samples"
        }

        let sorted = latenciesMs.sorted()
        let minMs = sorted.first ?? 0
        let maxMs = sorted.last ?? 0
        let p50 = percentile(sorted, p: 0.50)
        let p95 = percentile(sorted, p: 0.95)
        let avg = Int((Double(latenciesMs.reduce(0, +)) / Double(latenciesMs.count)).rounded())

        return "On-device quick-reply benchmark: runs=\(runCount) avg=\(avg)ms p50=\(p50)ms p95=\(p95)ms min=\(minMs)ms max=\(maxMs)ms"
    }

    private static func percentile(_ sorted: [Int], p: Double) -> Int {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }

        let clamped = min(max(p, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    private static func heuristicTitle(from firstMessage: String) -> String? {
        let collapsed = collapseWhitespace(firstMessage)
        guard !collapsed.isEmpty else { return nil }

        let firstLine = collapsed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? collapsed
        let tokens = firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(6)
            .map(String.init)
            .joined(separator: " ")

        return normalizeTitle(tokens)
    }

    private static func normalizeTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        if let newline = title.firstIndex(of: "\n") {
            title = String(title[..<newline])
        }

        title = title.replacingOccurrences(
            of: "(?i)^title\\s*:\\s*",
            with: "",
            options: .regularExpression
        )
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’[]() "))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
        title = collapseWhitespace(title)

        if title.count > autoTitleMaxLength {
            title = String(title.prefix(autoTitleMaxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
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
