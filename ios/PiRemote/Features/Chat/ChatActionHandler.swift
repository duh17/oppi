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
        onDispatchStarted: (() -> Void)? = nil,
        onAsyncFailure: ((_ text: String, _ images: [PendingImage]) -> Void)? = nil,
        onNeedsReconnect: (() -> Void)? = nil
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = images.map(\.attachment)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return text }
        guard !isSending else { return text }

        let wsStatus = String(describing: connection.wsClient?.status)
        let wsSessionId = connection.wsClient?.connectedSessionId ?? "nil"
        let sendPreview = String(trimmed.prefix(60))
        log.error(
            """
            SEND tap: isBusy=\(isBusy, privacy: .public) \
            wsStatus=\(wsStatus, privacy: .public) \
            wsSession=\(wsSessionId, privacy: .public) \
            targetSession=\(sessionId, privacy: .public) \
            text=\"\(sendPreview, privacy: .public)\"
            """
        )
        ClientLog.error(
            "Action",
            "SEND tap",
            metadata: [
                "isBusy": String(isBusy),
                "wsStatus": wsStatus,
                "wsSession": wsSessionId,
                "targetSession": sessionId,
                "text": sendPreview,
            ]
        )

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

                let sendStatus = String(describing: connection.wsClient?.status)
                log.error("SEND steer Task started, wsStatus=\(sendStatus, privacy: .public)")
                ClientLog.error(
                    "Action",
                    "SEND steer Task started",
                    metadata: ["wsStatus": sendStatus, "sessionId": sessionId]
                )

                do {
                    let steerImages = attachments.isEmpty ? nil : attachments
                    try await connection.sendSteer(trimmed, images: steerImages, onAckStage: { stage in
                        self.updateSendAckStage(stage)
                    })
                    self.scheduleSendStageClear()
                    log.error("SEND steer OK")
                    ClientLog.info("Action", "SEND steer OK", metadata: ["sessionId": sessionId])
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
                log.error("SEND prompt appended msgId=\(messageId, privacy: .public)")
                ClientLog.info(
                    "Action",
                    "SEND prompt appended",
                    metadata: ["sessionId": sessionId, "messageId": messageId]
                )

                let sendStatus = String(describing: connection.wsClient?.status)
                log.error("SEND prompt Task started, wsStatus=\(sendStatus, privacy: .public)")
                ClientLog.error(
                    "Action",
                    "SEND prompt Task started",
                    metadata: ["wsStatus": sendStatus, "sessionId": sessionId]
                )

                do {
                    let promptImages = attachments.isEmpty ? nil : attachments
                    try await connection.sendPrompt(trimmed, images: promptImages, onAckStage: { stage in
                        self.updateSendAckStage(stage)
                    })
                    self.scheduleSendStageClear()
                    log.error("SEND prompt OK")
                    ClientLog.info("Action", "SEND prompt OK", metadata: ["sessionId": sessionId])
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
                try? await connection.requestState()
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
        clearSendStageNow()
        isSending = false
    }
}
