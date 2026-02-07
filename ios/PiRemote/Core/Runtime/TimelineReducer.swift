import Foundation

/// Reduces `AgentEvent` stream into a `[ChatItem]` timeline.
///
/// State machine that accumulates deltas into items, manages tool correlation,
/// and produces the item array that drives the chat `LazyVStack`.
///
/// ## Transition Rules
/// - `agentStart`: clear turn buffers, begin new assistant context
/// - `thinkingDelta`: append to thinking buffer, upsert thinking item
/// - `textDelta`: append to assistant buffer, upsert assistant message
/// - `toolStart`: append new toolCall item
/// - `toolOutput`: append to ToolOutputStore, update toolCall preview
/// - `toolEnd`: mark toolCall as done
/// - `agentEnd`: flush buffers, finalize assistant message
/// - `error` / `sessionEnded`: flush, append terminal item
@MainActor @Observable
final class TimelineReducer {
    private(set) var items: [ChatItem] = []

    /// Incremented on timeline mutations so ChatView can react to row content
    /// updates (not only item insert/remove).
    private(set) var renderVersion: Int = 0

    // Turn-local buffers (reset on agentStart, finalized on agentEnd)
    private var currentAssistantID: String?
    private var assistantBuffer: String = ""
    private var currentThinkingID: String?
    private var thinkingBuffer: String = ""

    /// The item ID currently being streamed (non-nil while deltas arrive).
    /// Used by views to enable streaming-optimized rendering (e.g., plain text).
    var streamingAssistantID: String? { currentAssistantID }

    /// Expansion state — external from ChatItem payload to avoid Equatable cost.
    var expandedItemIDs: Set<String> = []

    /// Separate store for full tool output.
    let toolOutputStore = ToolOutputStore()

    // MARK: - Reset

    /// Clear all state — call when switching sessions.
    func reset() {
        items.removeAll()
        assistantBuffer = ""
        thinkingBuffer = ""
        currentAssistantID = nil
        currentThinkingID = nil
        toolOutputStore.clearAll()
        renderVersion &+= 1
    }

    // MARK: - Load from REST (reconnect)

    /// Rebuild timeline from stored messages (after reconnect/foreground).
    /// Only contains user/assistant/system messages — tool events are lost.
    func loadFromREST(_ messages: [SessionMessage]) {
        items.removeAll()
        assistantBuffer = ""
        thinkingBuffer = ""
        currentAssistantID = nil
        currentThinkingID = nil
        toolOutputStore.clearAll()

        for msg in messages {
            switch msg.role {
            case .user:
                items.append(.userMessage(id: msg.id, text: msg.content, timestamp: msg.timestamp))
            case .assistant:
                items.append(.assistantMessage(id: msg.id, text: msg.content, timestamp: msg.timestamp))
            case .system:
                items.append(.systemEvent(id: msg.id, message: msg.content))
            }
        }

        bumpRenderVersion()
    }

    // MARK: - Load from Trace (full history including tool calls)

    /// Rebuild timeline from full pi JSONL trace.
    /// Includes tool calls, tool results, and thinking blocks.
    func loadFromTrace(_ events: [TraceEvent]) {
        items.removeAll()
        assistantBuffer = ""
        thinkingBuffer = ""
        currentAssistantID = nil
        currentThinkingID = nil
        toolOutputStore.clearAll()

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for event in events {
            let date = dateFormatter.date(from: event.timestamp) ?? Date()

            switch event.type {
            case .user:
                items.append(.userMessage(
                    id: event.id,
                    text: event.text ?? "",
                    timestamp: date
                ))

            case .assistant:
                items.append(.assistantMessage(
                    id: event.id,
                    text: event.text ?? "",
                    timestamp: date
                ))

            case .thinking:
                let preview = ChatItem.preview(event.thinking ?? "")
                items.append(.thinking(
                    id: event.id,
                    preview: preview,
                    hasMore: (event.thinking?.count ?? 0) > ChatItem.maxPreviewLength
                ))

            case .toolCall:
                let argsSummary = event.args?.map { "\($0.key): \($0.value.summary())" }
                    .joined(separator: ", ") ?? ""
                items.append(.toolCall(
                    id: event.id,
                    tool: event.tool ?? "unknown",
                    argsSummary: ChatItem.preview(argsSummary),
                    outputPreview: "",
                    outputByteCount: 0,
                    isError: false,
                    isDone: true  // Historical = always done
                ))

            case .toolResult:
                let output = event.output ?? ""
                // Match to the originating toolCall by toolCallId
                let matchId = event.toolCallId ?? event.id
                toolOutputStore.append(output, to: matchId)
                updateToolCallPreview(id: matchId, isError: event.isError ?? false)

            case .system:
                items.append(.systemEvent(
                    id: event.id,
                    message: event.text ?? ""
                ))

            case .compaction:
                items.append(.systemEvent(
                    id: event.id,
                    message: "Context compacted"
                ))
            }
        }

        bumpRenderVersion()
    }

    // MARK: - Process Agent Events

    /// Process a batch of events with a single renderVersion bump.
    /// Use this from the coalescer to avoid per-event SwiftUI diffs.
    func processBatch(_ events: [AgentEvent]) {
        for event in events {
            processInternal(event)
        }
        bumpRenderVersion()
    }

    /// Process a single event. Bumps renderVersion once.
    func process(_ event: AgentEvent) {
        processInternal(event)
        bumpRenderVersion()
    }

    private func processInternal(_ event: AgentEvent) {
        switch event {
        case .agentStart:
            clearTurnBuffers()
            // New assistant turn — ID assigned on first text delta

        case .agentEnd:
            finalizeAssistantMessage()
            finalizeThinking()
            closeOrphanedTool()

        case .textDelta(_, let delta):
            assistantBuffer += delta
            upsertAssistantMessage()

        case .thinkingDelta(_, let delta):
            thinkingBuffer += delta
            upsertThinking()

        case .toolStart(_, let toolEventId, let tool, let args):
            let argsSummary = args.map { "\($0.key): \($0.value.summary())" }
                .joined(separator: ", ")
            items.append(.toolCall(
                id: toolEventId,
                tool: tool,
                argsSummary: ChatItem.preview(argsSummary),
                outputPreview: "",
                outputByteCount: 0,
                isError: false,
                isDone: false
            ))

        case .toolOutput(_, let toolEventId, let output, let isError):
            toolOutputStore.append(output, to: toolEventId)
            updateToolCallPreview(id: toolEventId, isError: isError)

        case .toolEnd(_, let toolEventId):
            updateToolCallDone(id: toolEventId)

        case .permissionRequest(let request):
            items.append(.permission(request))

        case .permissionExpired(let id):
            resolvePermission(id: id, action: .deny)

        case .sessionEnded(_, let reason):
            finalizeAssistantMessage()
            items.append(.systemEvent(id: UUID().uuidString, message: "Session ended: \(reason)"))

        case .error(_, let message):
            // Check for retry pattern — render as system event, not error
            if message.hasPrefix("Retrying (") {
                items.append(.systemEvent(id: UUID().uuidString, message: message))
            } else {
                items.append(.error(id: UUID().uuidString, message: message))
            }
        }
    }

    // MARK: - User Message (from local prompt)

    func appendUserMessage(_ text: String) {
        items.append(.userMessage(
            id: UUID().uuidString,
            text: text,
            timestamp: Date()
        ))
        bumpRenderVersion()
    }

    // MARK: - Permission Resolution

    func resolvePermission(id: String, action: PermissionAction) {
        // Replace the permission item with a resolved badge
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = .permissionResolved(id: id, action: action)
            bumpRenderVersion()
        }
    }

    // MARK: - Private

    private func clearTurnBuffers() {
        assistantBuffer = ""
        thinkingBuffer = ""
        currentAssistantID = nil
        currentThinkingID = nil
    }

    private func upsertAssistantMessage() {
        let id = currentAssistantID ?? UUID().uuidString
        if currentAssistantID == nil { currentAssistantID = id }

        let item = ChatItem.assistantMessage(
            id: id,
            text: assistantBuffer,
            timestamp: Date()
        )

        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
    }

    private func upsertThinking() {
        let id = currentThinkingID ?? UUID().uuidString
        if currentThinkingID == nil { currentThinkingID = id }

        let preview = ChatItem.preview(thinkingBuffer)
        let item = ChatItem.thinking(
            id: id,
            preview: preview,
            hasMore: thinkingBuffer.count > ChatItem.maxPreviewLength
        )

        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
    }

    private func finalizeAssistantMessage() {
        guard !assistantBuffer.isEmpty else { return }
        upsertAssistantMessage()
        assistantBuffer = ""
        currentAssistantID = nil
    }

    private func finalizeThinking() {
        thinkingBuffer = ""
        currentThinkingID = nil
    }

    private func closeOrphanedTool() {
        // If the last tool item isn't marked done, mark it now
        if let last = items.last,
           case .toolCall(let id, let tool, let args, let preview, let bytes, let isErr, let isDone) = last,
           !isDone {
            items[items.count - 1] = .toolCall(
                id: id, tool: tool, argsSummary: args,
                outputPreview: preview, outputByteCount: bytes,
                isError: isErr, isDone: true
            )
        }
    }

    private func updateToolCallPreview(id: String, isError: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              case .toolCall(_, let tool, let args, _, _, let existingError, let isDone) = items[idx]
        else { return }

        let fullOutput = toolOutputStore.fullOutput(for: id)
        items[idx] = .toolCall(
            id: id,
            tool: tool,
            argsSummary: args,
            outputPreview: ChatItem.preview(fullOutput),
            outputByteCount: fullOutput.utf8.count,
            isError: existingError || isError,
            isDone: isDone
        )
    }

    private func updateToolCallDone(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              case .toolCall(_, let tool, let args, let preview, let bytes, let isErr, _) = items[idx]
        else { return }

        items[idx] = .toolCall(
            id: id, tool: tool, argsSummary: args,
            outputPreview: preview, outputByteCount: bytes,
            isError: isErr, isDone: true
        )
    }

    private func bumpRenderVersion() {
        renderVersion &+= 1
    }
}
