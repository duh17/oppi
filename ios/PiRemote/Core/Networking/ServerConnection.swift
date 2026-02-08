import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.chenda.PiRemote", category: "Connection")

/// Top-level connection coordinator.
///
/// Owns the APIClient and WebSocketClient, manages the event pipeline,
/// and routes server messages to stores and the timeline reducer.
@MainActor @Observable
final class ServerConnection {
    // Public state
    private(set) var credentials: ServerCredentials?

    // Networking
    private(set) var apiClient: APIClient?
    private(set) var wsClient: WebSocketClient?

    /// Derived connection state for UI badges.
    var isConnected: Bool {
        wsClient?.status == .connected
    }

    // Stores
    let sessionStore = SessionStore()
    let permissionStore = PermissionStore()
    let workspaceStore = WorkspaceStore()

    // Runtime pipeline
    let reducer = TimelineReducer()
    private let coalescer = DeltaCoalescer()
    private let toolMapper = ToolEventMapper()

    // Stream lifecycle
    private var activeSessionId: String?

    // Extension UI
    var activeExtensionDialog: ExtensionUIRequest?
    var extensionToast: String?

    /// Composer draft text — saved/restored across background cycles.
    var composerDraft: String?

    /// Current thinking level (tracked client-side from RPC responses).
    /// Reset to `.medium` on session switch; updated by `cycle_thinking_level` responses.
    var thinkingLevel: ThinkingLevel = .medium

    /// Timer that auto-dismisses extension dialogs after their timeout expires.
    private var extensionTimeoutTask: Task<Void, Never>?

    init() {
        // Wire coalescer to reducer (batch) + Live Activity (throttled).
        // Single renderVersion bump per flush, not per event.
        coalescer.onFlush = { [weak self] events in
            guard let self else { return }
            self.reducer.processBatch(events)
            for event in events {
                LiveActivityManager.shared.updateFromEvent(event)
            }
        }
    }

    // MARK: - Setup

    /// Configure the connection with validated credentials.
    /// Returns `false` if the credentials contain a malformed host.
    @discardableResult
    func configure(credentials: ServerCredentials) -> Bool {
        guard let baseURL = credentials.baseURL else {
            logger.error("Invalid server credentials: host=\(credentials.host) port=\(credentials.port)")
            return false
        }
        self.credentials = credentials
        self.apiClient = APIClient(baseURL: baseURL, token: credentials.token)
        self.wsClient = WebSocketClient(credentials: credentials)
        return true
    }

    // MARK: - Session Streaming

    /// Open a WebSocket stream for one session.
    ///
    /// The caller owns stream consumption and task lifecycle.
    /// On stream termination, `WebSocketClient` disconnects via `onTermination`.
    func streamSession(_ sessionId: String) -> AsyncStream<ServerMessage>? {
        guard let wsClient else { return nil }

        // v1 one-stream policy
        disconnectSession()

        activeSessionId = sessionId
        toolMapper.reset()
        thinkingLevel = .medium  // Reset to default; server state arrives via rpcResult
        return wsClient.connect(sessionId: sessionId)
    }

    /// Disconnect from the current session stream.
    func disconnectSession() {
        coalescer.flushNow()
        wsClient?.disconnect()
        activeSessionId = nil
        // Clear stale extension dialog — it's tied to the active session stream
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
        // Don't end Live Activity on disconnect — it should persist
        // on Lock Screen until the session actually ends.
    }

    /// Flush pending deltas on background transition.
    /// Does NOT disconnect — the OS will suspend the stream, and
    /// `reconnectIfNeeded` handles recovery on foreground.
    func flushAndSuspend() {
        coalescer.flushNow()
    }

    // MARK: - Actions

    /// Send a prompt to the connected session.
    func sendPrompt(_ text: String) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.prompt(message: text))
    }

    /// Stop the current agent operation.
    func sendStop() async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.stop())
    }

    /// Respond to a permission request.
    func respondToPermission(id: String, action: PermissionAction) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.permissionResponse(id: id, action: action))
        permissionStore.resolve(id: id)
        reducer.resolvePermission(id: id, action: action)
        PermissionNotificationService.shared.cancelNotification(permissionId: id)
    }

    /// Respond to an extension UI dialog.
    func respondToExtensionUI(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.extensionUIResponse(id: id, value: value, confirmed: confirmed, cancelled: cancelled))
        activeExtensionDialog = nil
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
    }

    /// Request current state from server.
    func requestState() async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(.getState())
    }

    /// Send any client message.
    func send(_ message: ClientMessage) async throws {
        guard let wsClient else { throw WebSocketError.notConnected }
        try await wsClient.send(message)
    }

    // ── Model ──

    func setModel(provider: String, modelId: String) async throws {
        try await send(.setModel(provider: provider, modelId: modelId))
    }

    func cycleModel() async throws {
        try await send(.cycleModel())
    }

    // ── Thinking ──

    func setThinkingLevel(_ level: ThinkingLevel) async throws {
        try await send(.setThinkingLevel(level: level))
    }

    func cycleThinkingLevel() async throws {
        try await send(.cycleThinkingLevel())
    }

    // ── Session ──

    func newSession() async throws {
        try await send(.newSession())
    }

    func setSessionName(_ name: String) async throws {
        try await send(.setSessionName(name: name))
    }

    func compact(instructions: String? = nil) async throws {
        try await send(.compact(customInstructions: instructions))
    }

    // ── Bash ──

    func runBash(_ command: String) async throws {
        try await send(.bash(command: command))
    }

    // MARK: - Reconnect (foreground)

    /// Called when app returns to foreground.
    func reconnectIfNeeded() async {
        guard let apiClient, let sessionId = activeSessionId else { return }

        // Refresh session list (doesn't touch timeline)
        do {
            let sessions = try await apiClient.listSessions()
            sessionStore.sessions = sessions
        } catch {
            logger.error("Failed to refresh sessions: \(error)")
        }

        // Refresh workspaces + skills
        await workspaceStore.load(api: apiClient)

        // Sweep expired permissions (safety net for missed WS messages)
        let expiredIds = permissionStore.sweepExpired()
        for id in expiredIds {
            reducer.resolvePermission(id: id, action: .deny)
            PermissionNotificationService.shared.cancelNotification(permissionId: id)
        }

        // Treat connecting/reconnecting as alive for this session so foreground
        // refresh does not race and clobber in-flight ChatView connect work.
        let streamAttached = wsClient?.connectedSessionId == sessionId
        let streamAlive: Bool
        if streamAttached {
            switch wsClient?.status {
            case .connected, .connecting, .reconnecting:
                streamAlive = true
            default:
                streamAlive = false
            }
        } else {
            streamAlive = false
        }

        if !streamAlive {
            // Clear stale extension dialog — server will re-send if still pending
            activeExtensionDialog = nil
            extensionTimeoutTask?.cancel()
            extensionTimeoutTask = nil

            do {
                let (traceSession, trace) = try await apiClient.getSessionTrace(id: sessionId)
                sessionStore.upsert(traceSession)

                if !trace.isEmpty, traceAppearsComplete(trace, messageCount: traceSession.messageCount) {
                    reducer.loadFromTrace(trace)
                } else {
                    do {
                        let (restSession, messages) = try await apiClient.getSession(id: sessionId)
                        sessionStore.upsert(restSession)
                        reducer.loadFromREST(messages)
                    } catch {
                        if !trace.isEmpty {
                            reducer.loadFromTrace(trace)
                        } else {
                            logger.error("Failed to refresh session \(sessionId): \(error)")
                        }
                    }
                }
            } catch {
                do {
                    let (session, messages) = try await apiClient.getSession(id: sessionId)
                    sessionStore.upsert(session)
                    reducer.loadFromREST(messages)
                } catch {
                    logger.error("Failed to refresh session \(sessionId): \(error)")
                }
            }
        } else {
            // Stream alive — just refresh session metadata without touching timeline
            do {
                let (session, _) = try await apiClient.getSession(id: sessionId)
                sessionStore.upsert(session)
            } catch {
                logger.error("Failed to refresh session metadata: \(error)")
            }
        }

        // Ask server for freshest state once the active stream is connected.
        if streamAttached, wsClient?.status == .connected {
            try? await requestState()
        }
    }

    private func traceAppearsComplete(_ trace: [TraceEvent], messageCount: Int) -> Bool {
        guard messageCount > 0 else {
            return true
        }

        let traceMessageCount = trace.reduce(into: 0) { count, event in
            if event.type == .user || event.type == .assistant {
                count += 1
            }
        }
        return traceMessageCount >= messageCount
    }

    // MARK: - Message Router

    /// Route a ServerMessage to the appropriate store or pipeline.
    /// Ignores messages for non-active sessions (stale stream race).
    func handleServerMessage(_ message: ServerMessage, sessionId: String) {
        guard sessionId == activeSessionId else {
            logger.debug("Ignoring message for stale session \(sessionId) (active: \(self.activeSessionId ?? "none"))")
            return
        }

        switch message {
        // Direct state updates (not timeline events)
        case .connected(let session):
            sessionStore.upsert(session)

        case .state(let session):
            sessionStore.upsert(session)

        case .extensionUIRequest(let request):
            extensionTimeoutTask?.cancel()
            activeExtensionDialog = request
            scheduleExtensionTimeout(request)

        case .extensionUINotification(_, let message, _, _, _):
            extensionToast = message

        case .unknown:
            break  // Already logged in WebSocketClient

        // Permission events → store + pipeline + notification
        case .permissionRequest(let perm):
            logger.info("Permission request received: \(perm.id) tool=\(perm.tool) summary=\(perm.displaySummary)")
            permissionStore.add(perm)
            coalescer.receive(.permissionRequest(perm))
            PermissionNotificationService.shared.notifyIfBackgrounded(perm)

        case .permissionExpired(let id, _):
            permissionStore.expire(id: id)
            coalescer.receive(.permissionExpired(id: id))

        case .permissionCancelled(let id):
            permissionStore.remove(id: id)
            reducer.resolvePermission(id: id, action: .deny)
            PermissionNotificationService.shared.cancelNotification(permissionId: id)

        // Agent events → pipeline
        case .agentStart:
            coalescer.receive(.agentStart(sessionId: sessionId))

        case .agentEnd:
            coalescer.receive(.agentEnd(sessionId: sessionId))

        case .textDelta(let delta):
            coalescer.receive(.textDelta(sessionId: sessionId, delta: delta))

        case .thinkingDelta(let delta):
            coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: delta))

        case .toolStart(let tool, let args, let toolCallId):
            coalescer.receive(toolMapper.start(sessionId: sessionId, tool: tool, args: args, toolCallId: toolCallId))

        case .toolOutput(let output, let isError, let toolCallId):
            coalescer.receive(toolMapper.output(sessionId: sessionId, output: output, isError: isError, toolCallId: toolCallId))

        case .toolEnd(_, let toolCallId):
            coalescer.receive(toolMapper.end(sessionId: sessionId, toolCallId: toolCallId))

        case .sessionEnded(let reason):
            coalescer.receive(.sessionEnded(sessionId: sessionId, reason: reason))

        case .error(let msg):
            coalescer.receive(.error(sessionId: sessionId, message: msg))

        // Compaction events → pipeline
        case .compactionStart(let reason):
            coalescer.receive(.compactionStart(sessionId: sessionId, reason: reason))

        case .compactionEnd(let aborted, let willRetry, let summary, _):
            coalescer.receive(.compactionEnd(sessionId: sessionId, aborted: aborted, willRetry: willRetry, summary: summary))

        // Retry events → pipeline
        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            coalescer.receive(.retryStart(sessionId: sessionId, attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage))

        case .retryEnd(let success, let attempt, let finalError):
            coalescer.receive(.retryEnd(sessionId: sessionId, success: success, attempt: attempt, finalError: finalError))

        // RPC results → pipeline (for model changes, stats, etc.)
        case .rpcResult(let command, let requestId, let success, let data, let error):
            // Track thinking level from RPC responses
            if success && (command == "cycle_thinking_level" || command == "set_thinking_level") {
                if let levelStr = data?.objectValue?["level"]?.stringValue,
                   let level = ThinkingLevel(rawValue: levelStr) {
                    thinkingLevel = level
                } else if command == "cycle_thinking_level" {
                    // Server didn't return data — cycle locally
                    thinkingLevel = thinkingLevel.next
                }
            }
            coalescer.receive(.rpcResult(sessionId: sessionId, command: command, requestId: requestId, success: success, data: data, error: error))
        }
    }

    // MARK: - Extension Timeout

    /// Auto-dismiss extension dialog after its timeout expires.
    /// The server has already given up waiting — we just clean up the UI.
    private func scheduleExtensionTimeout(_ request: ExtensionUIRequest) {
        guard let timeout = request.timeout, timeout > 0 else { return }
        extensionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            guard let self, self.activeExtensionDialog?.id == request.id else { return }
            self.activeExtensionDialog = nil
            self.extensionToast = "Extension request timed out"
        }
    }
}
