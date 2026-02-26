// swiftlint:disable file_length
import Foundation
import os.log

private let loadSessionLog = Logger(subsystem: AppIdentifiers.subsystem, category: "LoadSession")

/// Reduces `AgentEvent` stream into a `[ChatItem]` timeline.
///
/// State machine that accumulates deltas into items, manages tool correlation,
/// and produces the item array that drives the chat collection timeline.
@MainActor @Observable
final class TimelineReducer { // swiftlint:disable:this type_body_length
    // No timeline trimming — the full session history is always preserved.
    // The collection view uses lazy rendering so item count doesn't affect
    // frame rate, only memory. A 1000-event session ≈ ~2MB — fine on any device.

    private(set) var items: [ChatItem] = []

    /// Incremented on timeline mutations so ChatView can react to row content
    /// updates (not only item insert/remove).
    private(set) var renderVersion: Int = 0

    // Turn-local buffers (reset on agentStart, finalized on agentEnd)
    private var currentAssistantID: String?
    private var assistantBuffer: String = ""
    /// Stable timestamp for the streaming assistant message — avoids
    /// creating a new Date() on every 33ms upsert, which would cause
    /// unnecessary Equatable mismatches and ForEach re-diffs.
    private var currentAssistantTimestamp: Date?

    private var currentThinkingID: String?
    /// Live thinking buffer. Unlike tool output previews, thinking is not
    /// truncated in the timeline; the row container handles viewport limits.
    private var thinkingBuffer: String = ""

    /// True between agentStart and agentEnd — used to keep the last assistant
    /// message in streaming render mode during tool calls (avoiding expensive
    /// streamingBody → finalizedBody transitions that cause layout cascades).
    private var turnInProgress = false
    /// The last assistant item ID created during this turn, preserved across
    /// `finalizeAssistantMessage()` so the view stays in streaming mode.
    private var lastAssistantIDThisTurn: String?

    /// The item ID currently being rendered in streaming mode.
    /// Non-nil while deltas arrive AND during tool-call gaps within a turn.
    /// This prevents MarkdownText from switching to finalizedBody (cache miss
    /// → placeholder → async parse → height change → collection layout cascade).
    var streamingAssistantID: String? {
        currentAssistantID ?? (turnInProgress ? lastAssistantIDThisTurn : nil)
    }

    /// Expansion state — external from ChatItem payload to avoid Equatable cost.
    var expandedItemIDs: Set<String> = []

    /// Separate store for full tool output.
    let toolOutputStore = ToolOutputStore()

    /// O(1) item lookup by ID — avoids linear scans on every 33ms upsert.
    /// Invalidated on insert, remove, and reset.
    private var itemIndexByID: [String: Int] = [:]

    /// Separate store for structured tool args.
    let toolArgsStore = ToolArgsStore()

    /// Separate store for server-rendered styled segments.
    /// Populated from `callSegments`/`resultSegments` in tool_start/tool_end.
    let toolSegmentStore = ToolSegmentStore()

    /// Separate store for structured tool result details (`tool_end.details`).
    let toolDetailsStore = ToolDetailsStore()

    /// Trace event IDs from the last successful history load.
    /// Used to detect append-only reloads and avoid full rebuilds.
    private var loadedTraceEventIDs: [String] = []

    /// True when current timeline rows are an exact projection of the last
    /// loaded trace (no live/local mutations since then).
    private var timelineMatchesTrace = false

    /// Test seam: true when the most recent `loadSession` used incremental
    /// append/no-op mode instead of a destructive full rebuild.
    private(set) var _lastLoadWasIncrementalForTesting = false

    /// Detached markdown cache prewarm task for history loads.
    /// Cancelled on reset/new load to avoid piling up background parse jobs
    /// during rapid session switching.
    private var markdownPrewarmTask: Task<Void, Never>?

    /// Prewarm limits — sized for 128+ item sessions to avoid layout cascades.
    private static let markdownPrewarmMaxMessages = 48
    private static let markdownPrewarmMaxCharsPerMessage = 12_000
    private static let markdownPrewarmMaxTotalChars = 192_000
    /// Purge global markdown cache when resetting after a very large timeline.
    private static let markdownCachePurgeItemThreshold = 250

    // MARK: - Reset

    /// Clear all state — call when switching sessions.
    func reset() {
        cancelMarkdownPrewarm()

        let previousItemCount = items.count
        if previousItemCount >= Self.markdownCachePurgeItemThreshold {
            MarkdownSegmentCache.shared.clearAll()
        }

        items.removeAll()
        itemIndexByID.removeAll()
        clearTurnBuffers()
        toolOutputStore.clearAll()
        toolArgsStore.clearAll()
        toolSegmentStore.clearAll()
        toolDetailsStore.clearAll()
        loadedTraceEventIDs.removeAll()
        timelineMatchesTrace = false
        _lastLoadWasIncrementalForTesting = false
        renderVersion &+= 1
    }

    // Drop non-essential in-memory state on iOS memory warning.
    // Keeps visible timeline rows intact, but clears expandable payloads
    // and strips heavy data (base64 images) from retained items.
    // swiftlint:disable:next large_tuple
    func handleMemoryWarning() -> (toolOutputBytesCleared: Int, expandedItemsCollapsed: Int, imagesStripped: Int) {
        cancelMarkdownPrewarm()

        let clearedBytes = toolOutputStore.totalBytes
        toolOutputStore.clearAll()
        toolArgsStore.clearAll()
        toolSegmentStore.clearAll()
        toolDetailsStore.clearAll()

        let expandedCount = expandedItemIDs.count
        expandedItemIDs.removeAll()

        // Strip base64 image data from user messages — these can be 1-2MB each.
        // The message text is preserved; images show "unavailable" placeholder.
        var imagesStripped = 0
        for (index, item) in items.enumerated() {
            if case .userMessage(let id, let text, let images, let ts) = item, !images.isEmpty {
                imagesStripped += images.count
                items[index] = .userMessage(id: id, text: text, images: [], timestamp: ts)
            }
        }

        // Drop trace event IDs — forces full rebuild on next loadSession
        // instead of incremental append, freeing the ID array.
        loadedTraceEventIDs.removeAll()
        timelineMatchesTrace = false

        bumpRenderVersion()

        return (
            toolOutputBytesCleared: clearedBytes,
            expandedItemsCollapsed: expandedCount,
            imagesStripped: imagesStripped
        )
    }

    // MARK: - Load Session (full history including tool calls)

    /// Rebuild timeline from pi session context.
    ///
    /// The server builds session context from JSONL entries using the same
    /// algorithm as pi TUI's `buildSessionContext()` — tree walk from leaf
    /// to root, compaction-aware (pre-compaction messages hidden).
    ///
    /// Includes tool calls, tool results, thinking blocks, compaction
    /// summaries, and system events (model/thinking level changes).
    func loadSession(_ events: [TraceEvent]) {
        cancelMarkdownPrewarm()

        let dateFormatter = Self.makeTraceDateFormatter()

        if let appendStart = incrementalAppendStartIndex(for: events) {
            _lastLoadWasIncrementalForTesting = true

            // No-op reload: trace unchanged and timeline already canonical.
            if appendStart == events.count {
                return
            }

            clearTurnBuffers()

            var assistantTextsToCache: [String] = []
            assistantTextsToCache.reserveCapacity(events.count - appendStart)

            for event in events[appendStart...] {
                if let assistantText = applyTraceEvent(event, dateFormatter: dateFormatter) {
                    assistantTextsToCache.append(assistantText)
                }
            }

            loadedTraceEventIDs.append(contentsOf: events[appendStart...].map(\.id))
            bumpRenderVersion()
            timelineMatchesTrace = true

            loadSessionLog.info("[loadSession] incremental: +\(events.count - appendStart) events → \(self.items.count) items")

            prewarmMarkdownCache(for: assistantTextsToCache)
            return
        }

        _lastLoadWasIncrementalForTesting = false

        items.removeAll()
        itemIndexByID.removeAll()
        clearTurnBuffers()
        toolOutputStore.clearAll()
        toolArgsStore.clearAll()
        toolSegmentStore.clearAll()
        toolDetailsStore.clearAll()

        var assistantTextsToCache: [String] = []
        assistantTextsToCache.reserveCapacity(events.count)

        for event in events {
            if let assistantText = applyTraceEvent(event, dateFormatter: dateFormatter) {
                assistantTextsToCache.append(assistantText)
            }
        }

        loadedTraceEventIDs = events.map(\.id)
        rebuildIndex()
        bumpRenderVersion()
        timelineMatchesTrace = true

        loadSessionLog.info("[loadSession] full rebuild: \(events.count) events → \(self.items.count) items")

        prewarmMarkdownCache(for: assistantTextsToCache)
    }

    private func incrementalAppendStartIndex(for events: [TraceEvent]) -> Int? {
        guard timelineMatchesTrace else { return nil }
        guard !loadedTraceEventIDs.isEmpty else { return nil }
        guard events.count >= loadedTraceEventIDs.count else { return nil }

        for (index, loadedID) in loadedTraceEventIDs.enumerated() {
            guard events[index].id == loadedID else { return nil }
        }

        return loadedTraceEventIDs.count
    }

    @discardableResult
    private func applyTraceEvent(_ event: TraceEvent, dateFormatter: ISO8601DateFormatter) -> String? {
        let date = dateFormatter.date(from: event.timestamp) ?? Date()

        switch event.type {
        case .user:
            let rawText = event.text ?? ""
            let (cleanText, images) = Self.extractImagesFromText(rawText)
            upsertHistoryItem(.userMessage(
                id: event.id,
                text: cleanText,
                images: images,
                timestamp: date
            ))
            return nil

        case .assistant:
            let text = event.text ?? ""
            // Skip whitespace-only assistant messages. The API often emits
            // a leading "\n\n" text block before thinking/tool content blocks
            // in the same response. These create empty bubbles in the UI.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            upsertHistoryItem(.assistantMessage(
                id: event.id,
                text: text,
                timestamp: date
            ))
            return text

        case .thinking:
            let thinking = event.thinking ?? ""
            upsertHistoryItem(.thinking(
                id: event.id,
                preview: thinking,
                hasMore: thinking.count > ChatItem.maxPreviewLength,
                isDone: true
            ))
            return nil

        case .toolCall:
            let args = event.args ?? [:]
            let argsSummary = args.map { "\($0.key): \($0.value.summary())" }
                .joined(separator: ", ")

            upsertHistoryItem(.toolCall(
                id: event.id,
                tool: event.tool ?? "unknown",
                argsSummary: ChatItem.preview(argsSummary),
                outputPreview: "",
                outputByteCount: 0,
                isError: false,
                isDone: true
            ))

            // Store structured args for smart rendering
            if !args.isEmpty {
                toolArgsStore.set(args, for: event.id)
            }
            return nil

        case .toolResult:
            let output = event.output ?? ""
            let matchId = event.toolCallId ?? event.id
            toolOutputStore.append(output, to: matchId)
            updateToolCallPreview(id: matchId, isError: event.isError ?? false)
            return nil

        case .system:
            upsertHistoryItem(.systemEvent(
                id: event.id,
                message: event.text ?? ""
            ))
            return nil

        case .compaction:
            let compactionMessage = event.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = compactionMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Context compacted"
            upsertHistoryItem(.systemEvent(
                id: event.id,
                message: message
            ))
            return nil
        }
    }

    private func upsertHistoryItem(_ item: ChatItem) {
        if let idx = indexForID(item.id) {
            items[idx] = item
        } else {
            items.append(item)
            indexAppend(item)
        }
    }

    private func prewarmMarkdownCache(for assistantTexts: [String]) {
        cancelMarkdownPrewarm()
        guard !assistantTexts.isEmpty else { return }

        var seen: Set<String> = []
        var totalChars = 0
        var textsToCache: [String] = []
        textsToCache.reserveCapacity(min(Self.markdownPrewarmMaxMessages, assistantTexts.count))

        let themeID = ThemeRuntimeState.currentThemeID()

        // Prefer newest assistant messages first, with conservative size limits.
        for text in assistantTexts.reversed() {
            guard seen.insert(text).inserted else { continue }
            guard text.count <= Self.markdownPrewarmMaxCharsPerMessage else { continue }
            guard MarkdownSegmentCache.shared.shouldCache(text) else { continue }
            guard MarkdownSegmentCache.shared.get(text, themeID: themeID) == nil else { continue }

            if totalChars + text.count > Self.markdownPrewarmMaxTotalChars {
                continue
            }

            textsToCache.append(text)
            totalChars += text.count

            if textsToCache.count >= Self.markdownPrewarmMaxMessages {
                break
            }
        }

        guard !textsToCache.isEmpty else { return }
        textsToCache.reverse()

        markdownPrewarmTask = Task.detached(priority: .utility) {
            for text in textsToCache {
                if Task.isCancelled { return }
                if MarkdownSegmentCache.shared.get(text, themeID: themeID) != nil { continue }

                let blocks = parseCommonMark(text)
                if Task.isCancelled { return }

                let segments = FlatSegment.build(from: blocks, themeID: themeID)
                MarkdownSegmentCache.shared.set(text, themeID: themeID, segments: segments)
            }
        }
    }

    private func cancelMarkdownPrewarm() {
        markdownPrewarmTask?.cancel()
        markdownPrewarmTask = nil
    }

    private static func makeTraceDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func formatTokenCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    // MARK: - Process Agent Events

    /// Process a batch of events with a single renderVersion bump.
    /// Use this from the coalescer to avoid per-event SwiftUI diffs.
    ///
    /// Perf note: text/thinking/tool-output deltas are high-frequency. In a
    /// batch, append to local accumulators and upsert affected rows once.
    func processBatch(_ events: [AgentEvent]) {
        var hasPendingAssistantUpsert = false
        var hasPendingThinkingUpsert = false
        var didMutate = false

        var pendingAssistantDeltas: [String] = []

        // Keep tool output chunks segmented during accumulation to avoid
        // repeated O(n²) string concatenation in large output bursts.
        var pendingToolOutputChunksByID: [String: [String]] = [:]
        var pendingToolOutputIsError: [String: Bool] = [:]
        var pendingToolOutputOrder: [String] = []

        func flushPendingUpserts() {
            if hasPendingThinkingUpsert {
                upsertThinking()
                hasPendingThinkingUpsert = false
                didMutate = true
            }

            if hasPendingAssistantUpsert {
                if !pendingAssistantDeltas.isEmpty {
                    assistantBuffer += pendingAssistantDeltas.joined()
                    pendingAssistantDeltas.removeAll(keepingCapacity: true)
                }
                upsertAssistantMessage()
                hasPendingAssistantUpsert = false
                didMutate = true
            }

            if !pendingToolOutputOrder.isEmpty {
                for toolEventId in pendingToolOutputOrder {
                    if let chunks = pendingToolOutputChunksByID[toolEventId], !chunks.isEmpty {
                        let mergedOutput = chunks.count == 1 ? chunks[0] : chunks.joined()
                        toolOutputStore.append(mergedOutput, to: toolEventId)
                    }
                    updateToolCallPreview(
                        id: toolEventId,
                        isError: pendingToolOutputIsError[toolEventId] ?? false
                    )
                }
                pendingToolOutputChunksByID.removeAll(keepingCapacity: true)
                pendingToolOutputIsError.removeAll(keepingCapacity: true)
                pendingToolOutputOrder.removeAll(keepingCapacity: true)
                didMutate = true
            }
        }

        for event in events {
            switch event {
            case .textDelta(_, let delta):
                pendingAssistantDeltas.append(delta)
                hasPendingAssistantUpsert = true

            case .thinkingDelta(_, let delta):
                // Keep only preview-size text in memory for live rendering.
                // Once overflowed, continue collecting full text in ToolOutputStore
                // for post-turn expansion, but skip no-op rerenders.
                if appendThinkingDelta(delta) {
                    hasPendingThinkingUpsert = true
                }

            case .toolOutput(_, let toolEventId, let output, let isError):
                if pendingToolOutputChunksByID[toolEventId] == nil {
                    pendingToolOutputOrder.append(toolEventId)
                }
                pendingToolOutputChunksByID[toolEventId, default: []].append(output)
                pendingToolOutputIsError[toolEventId] = (pendingToolOutputIsError[toolEventId] ?? false) || isError

            default:
                flushPendingUpserts()
                processInternal(event)
                didMutate = true
            }
        }

        flushPendingUpserts()
        if didMutate {
            bumpRenderVersion()
            timelineMatchesTrace = false
        }
    }

    /// Process a single event. Bumps renderVersion once.
    func process(_ event: AgentEvent) {
        processInternal(event)
        bumpRenderVersion()
        timelineMatchesTrace = false
    }

    private func processInternal(_ event: AgentEvent) { // swiftlint:disable:this cyclomatic_complexity
        switch event {
        case .agentStart:
            // Finalize any leftover state from a previous turn that didn't
            // end cleanly (missed agentEnd, reconnect gap, etc.).
            finalizeAssistantMessage()
            finalizeThinking()
            closeAllOrphanedTools()
            clearTurnBuffers()
            turnInProgress = true

        case .agentEnd:
            // End the turn BEFORE finalizing so streamingAssistantID goes nil
            // and MarkdownText transitions to finalizedBody for caching.
            turnInProgress = false
            lastAssistantIDThisTurn = nil
            finalizeAssistantMessage()
            finalizeThinking()
            closeAllOrphanedTools()

        case .textDelta(_, let delta):
            assistantBuffer += delta
            upsertAssistantMessage()

        case .thinkingDelta(_, let delta):
            if appendThinkingDelta(delta) {
                upsertThinking()
            }

        case .messageEnd(_, let content):
            handleMessageEnd(content)

        case .toolStart(_, let toolEventId, let tool, let args, let callSegments):
            // Split assistant text around tool boundaries so chronology in the
            // timeline matches execution order (text-before-tool, tool row,
            // text-after-tool).
            finalizeAssistantMessage()

            let argsSummary = args.map { "\($0.key): \($0.value.summary())" }
                .joined(separator: ", ")
            let fullOutput = toolOutputStore.fullOutput(for: toolEventId)
            let outputPreview = ChatItem.preview(fullOutput)
            let outputByteCount = fullOutput.utf8.count

            if let idx = indexForID(toolEventId),
               case .toolCall(_, _, _, _, _, let existingError, _) = items[idx] {
                // Replay/reconnect can deliver duplicate tool_start for an
                // existing tool call ID. Update in place instead of appending
                // a second row with the same identifier.
                items[idx] = .toolCall(
                    id: toolEventId,
                    tool: tool,
                    argsSummary: ChatItem.preview(argsSummary),
                    outputPreview: outputPreview,
                    outputByteCount: outputByteCount,
                    isError: existingError,
                    isDone: false
                )
            } else {
                let toolItem = ChatItem.toolCall(
                    id: toolEventId,
                    tool: tool,
                    argsSummary: ChatItem.preview(argsSummary),
                    outputPreview: outputPreview,
                    outputByteCount: outputByteCount,
                    isError: false,
                    isDone: false
                )
                if let existingIndex = indexForID(toolEventId) {
                    // ID collision with a non-tool row should replace in place
                    // to preserve uniqueness guarantees for diffable snapshots.
                    items[existingIndex] = toolItem
                } else {
                    items.append(toolItem)
                    indexAppend(toolItem)
                }
            }

            // Store structured args for smart rendering
            if !args.isEmpty {
                toolArgsStore.set(args, for: toolEventId)
            }

            // Store server-rendered segments for collapsed display
            if let callSegments, !callSegments.isEmpty {
                toolSegmentStore.setCallSegments(callSegments, for: toolEventId)
            }

        case .toolOutput(_, let toolEventId, let output, let isError):
            toolOutputStore.append(output, to: toolEventId)
            updateToolCallPreview(id: toolEventId, isError: isError)

        case .toolEnd(_, let toolEventId, let details, let isError, let resultSegments):
            if let details {
                toolDetailsStore.set(details, for: toolEventId)
            } else {
                toolDetailsStore.remove(for: toolEventId)
            }

            if let resultSegments, !resultSegments.isEmpty {
                toolSegmentStore.setResultSegments(resultSegments, for: toolEventId)
            }
            updateToolCallDone(id: toolEventId, isError: isError)

        case .permissionRequest:
            // Pending permissions live in PermissionStore/overlay, not the timeline.
            // ServerConnection routes these to PermissionStore directly.
            break

        case .permissionExpired:
            // Handled by ServerConnection via PermissionStore.take() + resolvePermission().
            break

        case .sessionEnded(_, let reason):
            // Session termination is terminal for the current turn.
            // Clear streaming mode before finalizing buffered content.
            turnInProgress = false
            lastAssistantIDThisTurn = nil
            finalizeAssistantMessage()
            finalizeThinking()
            closeAllOrphanedTools()
            items.append(.systemEvent(id: UUID().uuidString, message: "Session ended: \(reason)"))

        case .error(_, let message):
            items.append(.error(id: UUID().uuidString, message: message))

        // Compaction
        case .compactionStart(_, let reason):
            let label = reason == "overflow" ? String(localized: "Context overflow — compacting...") : String(localized: "Compacting context...")
            items.append(.systemEvent(id: UUID().uuidString, message: label))

        case .compactionEnd(_, let aborted, let willRetry, let summary, let tokensBefore):
            if aborted {
                items.append(.systemEvent(id: UUID().uuidString, message: String(localized: "Compaction cancelled")))
            } else if willRetry {
                items.append(.systemEvent(id: UUID().uuidString, message: String(localized: "Context compacted — retrying...")))
            } else {
                let tokenBadge: String
                if let tokensBefore, tokensBefore > 0 {
                    tokenBadge = " (\(Self.formatTokenCount(tokensBefore)) tokens)"
                } else {
                    tokenBadge = ""
                }

                let cleanedSummary = summary?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let message: String
                if let cleanedSummary, !cleanedSummary.isEmpty {
                    message = "Context compacted\(tokenBadge): \(cleanedSummary)"
                } else {
                    message = "Context compacted\(tokenBadge)"
                }

                items.append(.systemEvent(id: UUID().uuidString, message: message))
            }

        // Retry
        case .retryStart(_, let attempt, let maxAttempts, _, let errorMessage):
            items.append(.systemEvent(id: UUID().uuidString, message: "Retrying (\(attempt)/\(maxAttempts)): \(errorMessage)"))

        case .retryEnd(_, let success, _, let finalError):
            if !success, let err = finalError {
                items.append(.error(id: UUID().uuidString, message: "Retry failed: \(err)"))
            }

        // RPC results — model changes get a system event, others are silent
        case .commandResult(_, let command, _, let success, _, let error):
            if !success, let err = error {
                items.append(.error(id: UUID().uuidString, message: "\(command) failed: \(err)"))
            } else if command == "set_model" || command == "cycle_model" {
                items.append(.systemEvent(id: UUID().uuidString, message: String(localized: "Model changed")))
            } else if command == "set_thinking_level" || command == "cycle_thinking_level" {
                items.append(.systemEvent(id: UUID().uuidString, message: String(localized: "Thinking level changed")))
            }
        }
    }

    // MARK: - User Message (from local prompt)

    @discardableResult
    func appendUserMessage(_ text: String, images: [ImageAttachment] = []) -> String {
        let id = UUID().uuidString
        items.append(.userMessage(
            id: id,
            text: text,
            images: images,
            timestamp: Date()
        ))
        bumpRenderVersion()
        timelineMatchesTrace = false
        return id
    }

    /// Remove a specific item by ID (e.g., retract optimistic user message on send failure).
    func removeItem(id: String) {
        items.removeAll { $0.id == id }
        itemIndexByID.removeValue(forKey: id)
        rebuildIndex()
        bumpRenderVersion()
        timelineMatchesTrace = false
    }

    // MARK: - System Events (from local actions)

    /// Append a system event directly (not from the agent event pipeline).
    /// Used for local-only events like force-stop confirmations.
    func appendSystemEvent(_ message: String) {
        items.append(.systemEvent(id: UUID().uuidString, message: message))
        bumpRenderVersion()
        timelineMatchesTrace = false
    }

    /// Append a locally generated audio clip to the timeline.
    func appendAudioClip(title: String, fileURL: URL) {
        let item = ChatItem.audioClip(
            id: UUID().uuidString,
            title: title,
            fileURL: fileURL,
            timestamp: Date()
        )
        items.append(item)
        indexAppend(item)
        bumpRenderVersion()
        timelineMatchesTrace = false
    }

    // MARK: - Permission Resolution

    func resolvePermission(id: String, outcome: PermissionOutcome, tool: String, summary: String) {
        let resolved = ChatItem.permissionResolved(id: id, outcome: outcome, tool: tool, summary: summary)
        if let idx = indexForID(id) {
            // Replace old inline card (trace replay or prior state)
            items[idx] = resolved
        } else {
            // New flow: permission was never inline — append the marker
            items.append(resolved)
            indexAppend(resolved)
        }
        bumpRenderVersion()
        timelineMatchesTrace = false
    }

    // MARK: - Private

    private func clearTurnBuffers() {
        assistantBuffer = ""
        thinkingBuffer = ""
        currentAssistantID = nil
        currentAssistantTimestamp = nil
        currentThinkingID = nil
        turnInProgress = false
        lastAssistantIDThisTurn = nil
    }

    private func handleMessageEnd(_ content: String) {
        // Thinking is per-message — finalize it when the message ends,
        // not just on agentEnd. This ensures the spinner stops even if
        // agentEnd is delayed (e.g., tool calls follow this message).
        finalizeThinking()

        guard !content.isEmpty else {
            finalizeAssistantMessage()
            return
        }

        // Reconnect/history-reload race: trace may already include this
        // finalized assistant text, while in-flight message_end still arrives.
        // If no turn is in progress and no streaming assistant is active,
        // suppress duplicate append.
        if shouldSuppressDuplicateMessageEnd(content) {
            finalizeAssistantMessage()
            return
        }

        assistantBuffer = content
        upsertAssistantMessage()
        finalizeAssistantMessage()
    }

    private func shouldSuppressDuplicateMessageEnd(_ content: String) -> Bool {
        guard !turnInProgress, currentAssistantID == nil else { return false }
        guard let lastAssistant = items.last else { return false }
        guard case .assistantMessage(_, let existingText, _) = lastAssistant else { return false }

        return existingText.trimmingCharacters(in: .whitespacesAndNewlines)
            == content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func upsertAssistantMessage() {
        let id = currentAssistantID ?? UUID().uuidString
        if currentAssistantID == nil {
            currentAssistantID = id
            currentAssistantTimestamp = Date()
        }
        lastAssistantIDThisTurn = id

        let item = ChatItem.assistantMessage(
            id: id,
            text: assistantBuffer,
            timestamp: currentAssistantTimestamp ?? Date()
        )

        if let idx = indexForID(id) {
            items[idx] = item
        } else {
            items.append(item)
            indexAppend(item)
        }
    }

    private func ensureCurrentThinkingID() -> String {
        if let currentThinkingID {
            return currentThinkingID
        }
        let id = UUID().uuidString
        currentThinkingID = id
        return id
    }

    private func thinkingPreviewText() -> String {
        thinkingBuffer
    }

    /// Append a thinking delta into the live buffer.
    ///
    /// Thinking is intentionally not truncated in the timeline row; the row
    /// container manages viewport height and full-screen takes over for full
    /// reading.
    @discardableResult
    private func appendThinkingDelta(_ delta: String) -> Bool {
        guard !delta.isEmpty else { return false }

        let previousPreview = thinkingPreviewText()
        let previousHasMore = thinkingBuffer.count > ChatItem.maxPreviewLength

        thinkingBuffer += delta

        let newPreview = thinkingPreviewText()
        let newHasMore = thinkingBuffer.count > ChatItem.maxPreviewLength
        return newPreview != previousPreview || newHasMore != previousHasMore
    }

    private func upsertThinking() {
        let id = ensureCurrentThinkingID()

        let item = ChatItem.thinking(
            id: id,
            preview: thinkingPreviewText(),
            hasMore: thinkingBuffer.count > ChatItem.maxPreviewLength
        )

        if let idx = indexForID(id) {
            items[idx] = item
        } else {
            // Thinking streams before text, so this normally appends in order.
            // Fallback: if thinking arrives via message_end recovery (after text
            // has already streamed), insert before the assistant message so the
            // timeline reads: thinking → response text.
            if let assistantID = currentAssistantID,
               let assistantIdx = indexForID(assistantID) {
                items.insert(item, at: assistantIdx)
                rebuildIndex()
            } else {
                items.append(item)
                indexAppend(item)
            }
        }
    }

    private func finalizeAssistantMessage() {
        guard !assistantBuffer.isEmpty else {
            return
        }
        // If the buffer is only whitespace (e.g., "\n\n" before a tool call),
        // discard it instead of creating an empty bubble.
        if assistantBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Remove the in-progress item if it was already appended
            if let id = currentAssistantID {
                items.removeAll { $0.id == id }
            }
            assistantBuffer = ""
            currentAssistantID = nil
            return
        }
        upsertAssistantMessage()
        assistantBuffer = ""
        currentAssistantID = nil
    }

    private func finalizeThinking() {
        if let thinkingID = currentThinkingID,
           let idx = indexForID(thinkingID),
           case .thinking(let id, let preview, let hasMore, _) = items[idx] {
            // Remove empty/whitespace-only thinking rows to avoid blank bubbles.
            if preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.remove(at: idx)
                rebuildIndex()
            } else {
                // Mark the thinking item as done so the spinner stops.
                items[idx] = .thinking(id: id, preview: preview, hasMore: hasMore, isDone: true)
            }
        }
        thinkingBuffer = ""
        currentThinkingID = nil
    }

    /// Close ALL in-progress tool call rows, not just the last one.
    /// Handles cases where multiple tool calls are orphaned (e.g., missed
    /// agentEnd during reconnect, or concurrent tool calls in future protocol).
    private func closeAllOrphanedTools() {
        for idx in items.indices {
            if case .toolCall(let id, let tool, let args, let preview, let bytes, let isErr, let isDone) = items[idx],
               !isDone {
                items[idx] = .toolCall(
                    id: id, tool: tool, argsSummary: args,
                    outputPreview: preview, outputByteCount: bytes,
                    isError: isErr, isDone: true
                )
            }
        }
    }

    private func updateToolCallPreview(id: String, isError: Bool) {
        guard let idx = indexForID(id),
              case .toolCall(_, let tool, let args, _, _, let existingError, let isDone) = items[idx]
        else {
            return
        }

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

    private func updateToolCallDone(id: String, isError: Bool = false) {
        guard let idx = indexForID(id),
              case .toolCall(_, let tool, let args, let preview, let bytes, let streamIsErr, _) = items[idx]
        else {
            return
        }

        // tool_end isError is authoritative; streaming error state is a hint.
        let finalIsError = isError || streamIsErr
        items[idx] = .toolCall(
            id: id, tool: tool, argsSummary: args,
            outputPreview: preview, outputByteCount: bytes,
            isError: finalIsError, isDone: true
        )
    }

    // trimIfNeeded() removed — full timeline is always preserved.

    private func bumpRenderVersion() {
        renderVersion &+= 1
    }

    // MARK: - Indexed Helpers

    /// Find an item's index by ID using the O(1) cache.
    /// Falls back to linear scan if cache is stale (should not happen in practice).
    private func indexForID(_ id: String) -> Int? {
        if let idx = itemIndexByID[id], idx < items.count, items[idx].id == id {
            return idx
        }
        // Cache miss — linear fallback + repair
        if let idx = items.firstIndex(where: { $0.id == id }) {
            itemIndexByID[id] = idx
            return idx
        }
        return nil
    }

    /// Rebuild the full index. Call after bulk mutations (reset, loadSession, trim).
    private func rebuildIndex() {
        itemIndexByID.removeAll(keepingCapacity: true)
        for (i, item) in items.enumerated() {
            itemIndexByID[item.id] = i
        }
    }

    /// Register a newly appended item in the index.
    private func indexAppend(_ item: ChatItem) {
        itemIndexByID[item.id] = items.count - 1
    }

    // MARK: - Image Extraction

    /// Extract data URI images from user message text.
    ///
    /// Trace events store images as `data:image/...;base64,...` inline in the
    /// text field. Rendering 1MB+ of base64 as `SwiftUI.Text` freezes the
    /// main thread. This splits the text into clean display text + image
    /// attachments for proper thumbnail rendering.
    private static func extractImagesFromText(_ text: String) -> (String, [ImageAttachment]) {
        let extracted = ImageExtractor.extract(from: text)
        guard !extracted.isEmpty else { return (text, []) }

        var cleanText = text
        // Remove data URIs from text in reverse order to preserve ranges
        for image in extracted.reversed() {
            cleanText.removeSubrange(image.range)
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        let attachments = extracted.map { img in
            ImageAttachment(data: img.base64, mimeType: img.mimeType ?? "image/jpeg")
        }

        return (cleanText, attachments)
    }
}
