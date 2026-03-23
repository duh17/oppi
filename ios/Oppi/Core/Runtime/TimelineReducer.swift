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

    /// The session whose items are currently in the reducer.
    /// Set by `ChatSessionManager.connect()` before any async work.
    /// `ChatTimelineView` gates rendering on this — if it doesn't match
    /// the view's `sessionId`, no items are shown, preventing a flash
    /// of stale parent items during parent→child navigation.
    var activeSessionId: String?

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

    /// ID of the current in-flight compaction cycle's timeline item.
    ///
    /// Set on `compactionStart` (generates a new UUID or reuses the trace-derived ID).
    /// Used on `compactionEnd` to replace the start item in-place (collapse start+end
    /// into a single row). Cleared on `compactionEnd`, `reset`, and `loadSession`.
    ///
    /// When `loadSession` processes a `.compaction` trace event, this is set to the
    /// trace event's ID. If live WS `compaction_start`/`compaction_end` events arrive
    /// for the same compaction (race between trace rebuild and buffered WS events),
    /// they upsert the trace-derived item instead of appending duplicates.
    private var currentCompactionItemID: String?

    /// Expansion state — external from ChatItem payload to avoid Equatable cost.
    var expandedItemIDs: Set<String> = []

    /// Separate store for full tool output.
    let toolOutputStore = ToolOutputStore()

    /// O(1) item lookup by ID — avoids linear scans on every 33ms upsert.
    /// Invalidated on insert, remove, and reset.
    private let itemIndex = TimelineItemIndex()

    /// Separate store for structured tool args.
    let toolArgsStore = ToolArgsStore()

    /// Separate store for server-rendered styled segments.
    /// Populated from `callSegments`/`resultSegments` in tool_start/tool_end.
    let toolSegmentStore = ToolSegmentStore()

    /// Separate store for structured tool result details (`tool_end.details`).
    let toolDetailsStore = ToolDetailsStore()

    /// Start timestamps for in-progress tool calls (keyed by tool event ID).
    /// Used by the UI to display elapsed time on tool rows.
    private var toolStartTimes: [String: Date] = [:]

    /// Start time recorded when a tool call began, if available.
    func toolStartTime(for id: String) -> Date? {
        toolStartTimes[id]
    }

    /// Trace event IDs from the last successful history load.
    /// Used to detect append-only reloads and avoid full rebuilds.
    private var loadedTraceEventIDs: [String] = []

    /// True when current timeline rows are an exact projection of the last
    /// loaded trace (no live/local mutations since then).
    private var timelineMatchesTrace = false

    /// Test seam: true when the most recent `loadSession` used incremental
    /// append/no-op mode instead of a destructive full rebuild.
    private(set) var _lastLoadWasIncrementalForTesting = false

    // MARK: - Live Event Replay Buffer
    //
    // When a busy session re-entry loads a trace from the server, live events
    // from the WebSocket may have already been processed. A naive loadSession()
    // would replace the timeline, losing those live events permanently (they
    // won't be re-delivered).
    //
    // The replay buffer captures live AgentEvents during the history reload
    // window. When the trace arrives, we apply loadSession(trace) then
    // processBatch(buffer) in a single @MainActor turn — no interleaving.

    /// When non-nil, `processBatch` appends events to this buffer in addition
    /// to processing them normally. Set by `startReplayBuffer()`, consumed by
    /// `applyTraceWithLiveReplay()`.
    private var liveEventReplayBuffer: [AgentEvent]?

    /// True when replay buffering is active.
    var isReplayBuffering: Bool { liveEventReplayBuffer != nil }

    /// Start capturing live events for later replay after trace load.
    /// Call after transitioning to streaming state, before history reload completes.
    func startReplayBuffer() {
        liveEventReplayBuffer = []
    }

    /// Apply a trace and replay any buffered live events on top.
    ///
    /// This is the core fix for the busy re-entry gap bug:
    /// 1. loadSession(trace) rebuilds timeline from authoritative history
    /// 2. processBatch(buffer) re-creates live streaming state on top
    ///
    /// Both steps execute in a single @MainActor turn — no coalescer
    /// flush can interleave. The collection view sees one combined diff.
    ///
    /// Returns true if the trace was applied (false if no-op/skipped).
    @discardableResult
    func applyTraceWithLiveReplay(_ events: [TraceEvent]) -> Bool {
        let buffer = liveEventReplayBuffer ?? []
        liveEventReplayBuffer = nil

        // Fresh trace is authoritative — orphan detection disabled.
        // The replay buffer re-creates any live items on top.
        loadSession(events, preserveOrphans: false)

        if !buffer.isEmpty {
            processBatch(buffer)
        }

        return true
    }

    /// Asynchronous markdown cache prewarmer for history loads.
    private let markdownPrewarmer = MarkdownPrewarmer()

    // MARK: - Reset

    /// Clear all state — call when switching sessions.
    func reset() {
        markdownPrewarmer.cancel()

        let previousItemCount = items.count
        if previousItemCount >= MarkdownPrewarmer.cachePurgeItemThreshold {
            MarkdownSegmentCache.shared.clearAll()
        }

        items.removeAll()
        itemIndex.clear()
        clearTurnBuffers()
        currentCompactionItemID = nil
        liveEventReplayBuffer = nil
        itemsMutationSeq = 0
        activeSessionId = nil
        toolOutputStore.clearAll()
        toolArgsStore.clearAll()
        toolSegmentStore.clearAll()
        toolDetailsStore.clearAll()
        toolStartTimes.removeAll()
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
        markdownPrewarmer.cancel()

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
    ///
    /// - Parameter preserveOrphans: When true, locally-added user messages
    ///   not present in the trace are re-inserted after the rebuild. Set to
    ///   false when loading an authoritative fresh trace (e.g., from
    ///   `loadHistory`) to avoid "ghost" user messages at the bottom.
    func loadSession(_ events: [TraceEvent], preserveOrphans: Bool = true) {
        markdownPrewarmer.cancel()

        let dateFormatter = Self.makeTraceDateFormatter()

        switch loadSessionMode(events: events) {
        case .noOp:
            _lastLoadWasIncrementalForTesting = true
            return

        case .incremental(let appendStart):
            _lastLoadWasIncrementalForTesting = true

            clearTurnBuffers()

            var assistantTextsToCache: [String] = []
            assistantTextsToCache.reserveCapacity(events.count - appendStart)

            for event in events[appendStart...] {
                if let assistantText = applyTraceEvent(event, dateFormatter: dateFormatter, appendOnly: true) {
                    assistantTextsToCache.append(assistantText)
                }
            }

            loadedTraceEventIDs.append(contentsOf: events[appendStart...].map(\.id))
            bumpRenderVersion()
            timelineMatchesTrace = true

            loadSessionLog.info("[loadSession] incremental: +\(events.count - appendStart) events → \(self.items.count) items")

            markdownPrewarmer.prewarm(assistantTexts: assistantTextsToCache)
            return

        case .fullRebuild:
            _lastLoadWasIncrementalForTesting = false
        }

        // Preserve locally-added user messages that aren't yet in the trace.
        // Race condition: user sends a message (appendUserMessage adds it locally),
        // then a background history reload completes with a stale trace that
        // predates the JSONL write. The full rebuild would clear the optimistic
        // user message, and streaming events never re-emit it. Capture orphans
        // here and re-append them after the rebuild.
        //
        // Disabled when `preserveOrphans` is false (fresh trace from loadHistory
        // is authoritative — orphans become "ghost" user messages at the bottom
        // without matching assistant responses).
        //
        // Fast path: skip orphan detection when there are no existing user messages
        // (common case for initial load or after reset).
        let orphanedUserMessages: [ChatItem]
        if !preserveOrphans {
            orphanedUserMessages = []
        } else {
            let existingUserMessages = items.filter { item in
                if case .userMessage = item { return true }
                return false
            }
            if existingUserMessages.isEmpty {
                orphanedUserMessages = []
            } else {
                let traceUserTexts: Set<String> = Set(events.compactMap { event in
                    guard event.type == .user else { return nil }
                    return UserMessageImageExtractor.extractImagesFromText(event.text ?? "").0
                })
                orphanedUserMessages = existingUserMessages.filter { item in
                    guard case .userMessage(_, let text, _, _) = item else { return false }
                    return !traceUserTexts.contains(text)
                }
            }
        }
        items.removeAll(keepingCapacity: false)
        itemIndex.clear()
        clearTurnBuffers()
        toolOutputStore.clearAll()
        toolArgsStore.clearAll()
        toolSegmentStore.clearAll()
        toolDetailsStore.clearAll()

        // Pre-size arrays to avoid reallocation during event processing.
        items.reserveCapacity(events.count)
        var assistantTextsToCache: [String] = []
        assistantTextsToCache.reserveCapacity(events.count / 4)

        // Build the trace-event-ID list in the same pass as event processing
        // to avoid a redundant second traversal of the events array.
        loadedTraceEventIDs.removeAll(keepingCapacity: false)
        loadedTraceEventIDs.reserveCapacity(events.count)

        for event in events {
            loadedTraceEventIDs.append(event.id)
            if let assistantText = applyTraceEvent(event, dateFormatter: dateFormatter, appendOnly: true) {
                assistantTextsToCache.append(assistantText)
            }
        }

        // Re-insert orphaned user messages at their chronological position.
        for orphan in orphanedUserMessages {
            let insertIdx = Self.chronologicalInsertionIndex(for: orphan, in: items)
            items.insert(orphan, at: insertIdx)
        }
        // Only rebuild index when orphan insertion shifted item positions.
        // The appendOnly processing path builds the index incrementally,
        // so a full rebuild is redundant when no orphans were re-inserted.
        if !orphanedUserMessages.isEmpty {
            rebuildIndex()
        }
        bumpRenderVersion()
        // If we preserved orphans, the timeline no longer exactly matches the
        // trace — force a full rebuild on the next loadSession so the orphans
        // get reconciled once the trace catches up.
        timelineMatchesTrace = orphanedUserMessages.isEmpty

        let orphanInfo = orphanedUserMessages.isEmpty ? "" : " (preserved \(orphanedUserMessages.count) local user msgs)"
        loadSessionLog.info("[loadSession] full rebuild: \(events.count) events → \(self.items.count) items\(orphanInfo)")

        markdownPrewarmer.prewarm(assistantTexts: assistantTextsToCache)
    }

    @discardableResult
    private func applyTraceEvent(_ event: TraceEvent, dateFormatter: ISO8601DateFormatter, appendOnly: Bool = false) -> String? {
        // Lazy date — only .user and .assistant actually need a parsed timestamp.
        // Avoids ~0.5μs of date parsing for thinking, toolCall, toolResult, system events.
        lazy var date = FastISO8601Parser.parse(event.timestamp, fallback: dateFormatter)

        switch event.type {
        case .user:
            let rawText = event.text ?? ""
            let (cleanText, images) = UserMessageImageExtractor.extractImagesFromText(rawText)
            insertItem(.userMessage(
                id: event.id,
                text: cleanText,
                images: images,
                timestamp: date
            ), appendOnly: appendOnly)
            return nil

        case .assistant:
            let text = event.text ?? ""
            // Skip whitespace-only assistant messages. The API often emits
            // a leading "\n\n" text block before thinking/tool content blocks
            // in the same response. These create empty bubbles in the UI.
            guard !StringFastChecks.isEffectivelyEmpty(text) else {
                return nil
            }
            insertItem(.assistantMessage(
                id: event.id,
                text: text,
                timestamp: date
            ), appendOnly: appendOnly)
            return text

        case .thinking:
            let thinking = event.thinking ?? ""
            insertItem(.thinking(
                id: event.id,
                preview: thinking,
                hasMore: thinking.utf8.count > ChatItem.maxPreviewLength,
                isDone: true
            ), appendOnly: appendOnly)
            return nil

        case .toolCall:
            let args = event.args ?? [:]
            // Build summary directly without intermediate array allocation.
            var argsSummary = ""
            var isFirst = true
            for (key, value) in args {
                if isFirst { isFirst = false } else { argsSummary += ", " }
                argsSummary += key
                argsSummary += ": "
                argsSummary += value.summary()
            }

            insertItem(.toolCall(
                id: event.id,
                tool: event.tool ?? "unknown",
                argsSummary: ChatItem.preview(argsSummary),
                outputPreview: "",
                outputByteCount: 0,
                isError: false,
                isDone: true
            ), appendOnly: appendOnly)

            // Store structured args for smart rendering
            if !args.isEmpty {
                toolArgsStore.set(args, for: event.id)
            }
            return nil

        case .toolResult:
            let output = event.output ?? ""
            let matchId = event.toolCallId ?? event.id
            toolOutputStore.append(output, to: matchId)
            // Store structured details so catch-up rendering matches streaming.
            if let details = event.details {
                toolDetailsStore.set(details, for: matchId)
            }
            if appendOnly {
                // During loadSession, skip the equality check, fullOutput
                // retrieval, and outputByteCount lookup — we have the output
                // right here and know its byte count.
                updateToolCallPreviewDirect(
                    id: matchId,
                    output: output,
                    outputByteCount: output.utf8.count,
                    isError: event.isError ?? false
                )
            } else {
                updateToolCallPreview(id: matchId, isError: event.isError ?? false)
            }
            return nil

        case .system:
            insertItem(.systemEvent(
                id: event.id,
                message: event.text ?? ""
            ), appendOnly: appendOnly)
            return nil

        case .compaction:
            let compactionMessage = event.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = compactionMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Context compacted"
            // Track the trace compaction ID so that if buffered live WS
            // compaction_start/compaction_end events arrive for the SAME
            // compaction, they upsert this item instead of appending duplicates.
            currentCompactionItemID = event.id
            insertItem(.systemEvent(
                id: event.id,
                message: message
            ), appendOnly: appendOnly)
            return nil
        }
    }

    /// Insert item — append-only when IDs are known-new (loadSession full rebuild),
    /// upsert otherwise (incremental append where IDs might already exist).
    private func insertItem(_ item: ChatItem, appendOnly: Bool) {
        if appendOnly {
            items.append(item)
            indexAppend(item)
        } else {
            upsertHistoryItem(item)
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

    /// Cached fallback formatter — lazily initialized, reused across loadSession calls.
    /// The fast parser handles 99%+ of timestamps; the formatter is only used for
    /// non-standard formats, so lazy init avoids paying creation cost every call.
    nonisolated(unsafe) private static let sharedTraceDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func makeTraceDateFormatter() -> ISO8601DateFormatter {
        sharedTraceDateFormatter
    }

    private enum HistoryLoadMode: Equatable {
        case noOp
        case incremental(appendStart: Int)
        case fullRebuild
    }

    private func loadSessionMode(events: [TraceEvent]) -> HistoryLoadMode {
        guard timelineMatchesTrace else { return .fullRebuild }
        guard !loadedTraceEventIDs.isEmpty else { return .fullRebuild }
        guard events.count >= loadedTraceEventIDs.count else { return .fullRebuild }

        for (index, loadedID) in loadedTraceEventIDs.enumerated() {
            guard events[index].id == loadedID else { return .fullRebuild }
        }

        let appendStart = loadedTraceEventIDs.count
        if appendStart == events.count {
            return .noOp
        }

        return .incremental(appendStart: appendStart)
    }

    // MARK: - Process Agent Events

    /// Process a batch of events with a single renderVersion bump.
    /// Use this from the coalescer to avoid per-event SwiftUI diffs.
    ///
    /// Perf note: text/thinking/tool-output deltas are high-frequency. In a
    /// batch, append to local accumulators and upsert affected rows once.
    func processBatch(_ events: [AgentEvent]) {
        // Capture live events for replay if buffering is active.
        // Events are still processed normally below — the buffer is
        // only consumed later by applyTraceWithLiveReplay().
        if liveEventReplayBuffer != nil {
            liveEventReplayBuffer?.append(contentsOf: events)
        }

        var hasPendingAssistantUpsert = false
        var hasPendingThinkingUpsert = false
        var didMutate = false

        var pendingAssistantDeltas: [String] = []

        // Keep tool output chunks segmented during accumulation to avoid
        // repeated O(n²) string concatenation in large output bursts.
        var pendingToolOutputChunksByID: [String: [String]] = [:]
        var pendingToolOutputIsError: [String: Bool] = [:]
        var pendingToolOutputOrder: [String] = []
        /// Tracks whether the last output for a tool was a replace (tail preview).
        var pendingToolOutputIsReplace: [String: Bool] = [:]
        var pendingToolOutputIsPreviewOnly: [String: Bool] = [:]
        var pendingToolOutputTotalBytes: [String: Int] = [:]

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
                var didMutateToolOutputs = false

                for toolEventId in pendingToolOutputOrder {
                    let outputDidChange: Bool
                    let isReplace = pendingToolOutputIsReplace[toolEventId] ?? false
                    if let chunks = pendingToolOutputChunksByID[toolEventId], !chunks.isEmpty {
                        if isReplace, let lastChunk = chunks.last {
                            // Replace mode: keep only the latest preview snapshot.
                            outputDidChange = toolOutputStore.replace(
                                lastChunk,
                                for: toolEventId,
                                previewOnly: pendingToolOutputIsPreviewOnly[toolEventId] ?? false,
                                totalBytes: pendingToolOutputTotalBytes[toolEventId]
                            )
                        } else {
                            let mergedOutput = chunks.count == 1 ? chunks[0] : chunks.joined()
                            outputDidChange = toolOutputStore.append(mergedOutput, to: toolEventId)
                        }
                    } else {
                        outputDidChange = false
                    }

                    let previewDidChange = updateToolCallPreview(
                        id: toolEventId,
                        isError: pendingToolOutputIsError[toolEventId] ?? false
                    )

                    if outputDidChange || previewDidChange {
                        didMutateToolOutputs = true
                    }
                }
                pendingToolOutputChunksByID.removeAll(keepingCapacity: true)
                pendingToolOutputIsError.removeAll(keepingCapacity: true)
                pendingToolOutputOrder.removeAll(keepingCapacity: true)
                pendingToolOutputIsReplace.removeAll(keepingCapacity: true)
                pendingToolOutputIsPreviewOnly.removeAll(keepingCapacity: true)
                pendingToolOutputTotalBytes.removeAll(keepingCapacity: true)
                if didMutateToolOutputs {
                    didMutate = true
                }
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

            case .toolOutput(let payload):
                let toolEventId = payload.toolEventId
                if pendingToolOutputChunksByID[toolEventId] == nil {
                    pendingToolOutputOrder.append(toolEventId)
                }
                pendingToolOutputIsError[toolEventId] = (pendingToolOutputIsError[toolEventId] ?? false) || payload.isError

                if payload.mode == .replace {
                    pendingToolOutputChunksByID[toolEventId] = [payload.output]
                    pendingToolOutputIsReplace[toolEventId] = true
                    pendingToolOutputIsPreviewOnly[toolEventId] = payload.truncated
                    if let totalBytes = payload.totalBytes {
                        pendingToolOutputTotalBytes[toolEventId] = totalBytes
                    } else {
                        pendingToolOutputTotalBytes.removeValue(forKey: toolEventId)
                    }
                } else if pendingToolOutputIsReplace[toolEventId] != true {
                    pendingToolOutputChunksByID[toolEventId, default: []].append(payload.output)
                }

            default:
                flushPendingUpserts()
                if processInternal(event) {
                    didMutate = true
                }
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
        _ = processInternal(event)
        bumpRenderVersion()
        timelineMatchesTrace = false
    }

    /// Monotonic counter incremented on every items-array mutation.
    /// Used by `RenderMutationCheckpoint` instead of copying the full array.
    private var itemsMutationSeq: UInt64 = 0

    @inline(__always)
    private func bumpItemsMutationSeq() {
        itemsMutationSeq &+= 1
    }

    /// Lightweight mutation checkpoint that avoids O(n) items-array copies.
    /// Uses a monotonic mutation counter for items changes and byte-counts
    /// for string buffers instead of full string comparisons.
    private struct RenderMutationCheckpoint: Equatable {
        let itemsMutationSeq: UInt64
        let assistantBufferBytes: Int
        let currentAssistantID: String?
        let currentAssistantTimestamp: Date?
        let thinkingBufferBytes: Int
        let currentThinkingID: String?
        let turnInProgress: Bool
        let lastAssistantIDThisTurn: String?
    }

    private func renderMutationCheckpoint() -> RenderMutationCheckpoint {
        .init(
            itemsMutationSeq: itemsMutationSeq,
            assistantBufferBytes: assistantBuffer.utf8.count,
            currentAssistantID: currentAssistantID,
            currentAssistantTimestamp: currentAssistantTimestamp,
            thinkingBufferBytes: thinkingBuffer.utf8.count,
            currentThinkingID: currentThinkingID,
            turnInProgress: turnInProgress,
            lastAssistantIDThisTurn: lastAssistantIDThisTurn
        )
    }
    private func processInternal(_ event: AgentEvent) -> Bool {
        switch event {
        case .agentStart:
            let before = renderMutationCheckpoint()
            finalizeAssistantMessage()
            finalizeThinking()
            closeAllOrphanedTools()
            clearTurnBuffers()
            turnInProgress = true
            return renderMutationCheckpoint() != before

        case .agentEnd:
            let before = renderMutationCheckpoint()
            turnInProgress = false
            lastAssistantIDThisTurn = nil
            finalizeAssistantMessage()
            finalizeThinking()
            closeAllOrphanedTools()
            return renderMutationCheckpoint() != before

        case .textDelta(_, let delta):
            assistantBuffer += delta
            upsertAssistantMessage()
            return true

        case .thinkingDelta(_, let delta):
            if appendThinkingDelta(delta) {
                upsertThinking()
                return true
            }
            return false

        case .messageEnd(_, let content):
            let before = renderMutationCheckpoint()
            handleMessageEnd(content)
            return renderMutationCheckpoint() != before

        case .toolStart(_, let toolEventId, let tool, let args, let callSegments):
            return handleToolStart(toolEventId: toolEventId, tool: tool, args: args, callSegments: callSegments)

        case .toolOutput(let payload):
            let outputDidChange: Bool
            if payload.mode == .replace {
                outputDidChange = toolOutputStore.replace(
                    payload.output,
                    for: payload.toolEventId,
                    previewOnly: payload.truncated,
                    totalBytes: payload.totalBytes
                )
            } else {
                outputDidChange = toolOutputStore.append(payload.output, to: payload.toolEventId)
            }
            let previewDidChange = updateToolCallPreview(id: payload.toolEventId, isError: payload.isError)
            return outputDidChange || previewDidChange

        case .toolEnd(_, let toolEventId, let details, let isError, let resultSegments):
            return handleToolEnd(toolEventId: toolEventId, details: details, isError: isError, resultSegments: resultSegments)

        case .permissionRequest:
            return false
        case .permissionExpired:
            return false

        case .sessionEnded(_, let reason):
            let before = renderMutationCheckpoint()
            // Session termination is terminal for the current turn.
            // Clear streaming mode before finalizing buffered content.
            turnInProgress = false
            lastAssistantIDThisTurn = nil
            finalizeAssistantMessage()
            finalizeThinking()
            closeAllOrphanedTools()
            items.append(.systemEvent(id: UUID().uuidString, message: "Session ended: \(reason)"))
            return renderMutationCheckpoint() != before

        case .error(_, let message):
            items.append(.error(id: UUID().uuidString, message: message))
            return true

        case .compactionStart(_, let reason):
            return handleCompactionStart(reason: reason)

        case .compactionEnd(_, let aborted, let willRetry, let summary, let tokensBefore):
            return handleCompactionEnd(aborted: aborted, willRetry: willRetry, summary: summary, tokensBefore: tokensBefore)

        case .retryStart(_, let attempt, let maxAttempts, _, let errorMessage):
            items.append(.systemEvent(id: UUID().uuidString, message: "Retrying (\(attempt)/\(maxAttempts)): \(errorMessage)"))
            return true

        case .retryEnd(_, let success, _, let finalError):
            if !success, let err = finalError {
                items.append(.error(id: UUID().uuidString, message: "Retry failed: \(err)"))
                return true
            }
            return false

        case .commandResult(_, let command, _, let success, _, let error):
            return handleCommandResult(command: command, success: success, error: error)
        }
    }

    // MARK: - Event Handlers (extracted from processInternal)

    private func handleToolStart(toolEventId: String, tool: String, args: [String: JSONValue], callSegments: [StyledSegment]?) -> Bool {
        let before = renderMutationCheckpoint()
        let previousArgs = toolArgsStore.args(for: toolEventId)
        let previousCallSegments = toolSegmentStore.callSegments(for: toolEventId)
        finalizeAssistantMessage()
        // Record start time for elapsed display (only if not already set — replay/reconnect
        // can deliver duplicate tool_start for the same ID).
        if toolStartTimes[toolEventId] == nil {
            toolStartTimes[toolEventId] = Date()
        }
        let argsSummary = args.map { "\($0.key): \($0.value.summary())" }
            .joined(separator: ", ")
        let fullOutput = toolOutputStore.fullOutput(for: toolEventId)
        let outputPreview = ChatItem.preview(fullOutput)
        let outputByteCount = toolOutputStore.outputByteCount(for: toolEventId)

        if let idx = indexForID(toolEventId),
           case .toolCall(_, _, _, _, _, let existingError, _) = items[idx] {
            // Replay/reconnect can deliver duplicate tool_start for an
            // existing tool call ID. Update in place instead of appending
            // a second row with the same identifier.
            let newItem = TimelineTurnAssembler.makeToolCallItem(
                id: toolEventId,
                tool: tool,
                argsSummary: argsSummary,
                outputPreview: outputPreview,
                outputByteCount: outputByteCount,
                isError: existingError,
                isDone: false
            )
            if items[idx] != newItem {
                items[idx] = newItem
                bumpItemsMutationSeq()
            }
        } else {
            let toolItem = TimelineTurnAssembler.makeToolCallItem(
                id: toolEventId,
                tool: tool,
                argsSummary: argsSummary,
                outputPreview: outputPreview,
                outputByteCount: outputByteCount,
                isError: false,
                isDone: false
            )
            if let existingIndex = indexForID(toolEventId) {
                items[existingIndex] = toolItem
                bumpItemsMutationSeq()
            } else {
                items.append(toolItem)
                indexAppend(toolItem)
                bumpItemsMutationSeq()
            }
        }
        if !args.isEmpty {
            toolArgsStore.set(args, for: toolEventId)
        }
        if let callSegments, !callSegments.isEmpty {
            toolSegmentStore.setCallSegments(callSegments, for: toolEventId)
        }
        return renderMutationCheckpoint() != before ||
            toolArgsStore.args(for: toolEventId) != previousArgs ||
            toolSegmentStore.callSegments(for: toolEventId) != previousCallSegments
    }

    private func handleToolEnd(toolEventId: String, details: JSONValue?, isError: Bool, resultSegments: [StyledSegment]?) -> Bool {
        let before = renderMutationCheckpoint()
        let previousDetails = toolDetailsStore.details(for: toolEventId)
        let previousResultSegments = toolSegmentStore.resultSegments(for: toolEventId)
        if let details {
            toolDetailsStore.set(details, for: toolEventId)
        } else {
            toolDetailsStore.remove(for: toolEventId)
        }
        if let resultSegments, !resultSegments.isEmpty {
            toolSegmentStore.setResultSegments(resultSegments, for: toolEventId)
        }
        updateToolCallDone(id: toolEventId, isError: isError)
        return renderMutationCheckpoint() != before ||
            toolDetailsStore.details(for: toolEventId) != previousDetails ||
            toolSegmentStore.resultSegments(for: toolEventId) != previousResultSegments
    }

    // Compaction
    //
    // compactionStart + compactionEnd are collapsed into a single timeline
    // item per compaction cycle. compactionStart creates (or reuses) an item
    // with a tracked `currentCompactionItemID`; compactionEnd replaces it
    // in-place with the final message.
    //
    // When `loadSession` processes a `.compaction` trace event, it sets
    // `currentCompactionItemID` to the trace event's ID. If buffered live
    // WS events for the same compaction arrive afterward, they upsert the
    // trace-derived item instead of appending duplicates.

    private func handleCompactionStart(reason: String?) -> Bool {
        let label = reason == "overflow" ? String(localized: "Context overflow — compacting...") : String(localized: "Compacting context...")
        let id = currentCompactionItemID ?? UUID().uuidString
        currentCompactionItemID = id
        let item = ChatItem.systemEvent(id: id, message: label)
        if let idx = indexForID(id) {
            items[idx] = item
        } else {
            items.append(item)
            indexAppend(item)
        }
        return true
    }

    private func handleCompactionEnd(aborted: Bool, willRetry: Bool, summary: String?, tokensBefore: Int?) -> Bool {
        let message: String
        if aborted {
            message = String(localized: "Compaction cancelled")
        } else if willRetry {
            message = String(localized: "Context compacted — retrying...")
        } else {
            let tokenBadge = (tokensBefore ?? 0) > 0 ? " (\(formatTokenCountDecimal(tokensBefore ?? 0)) tokens)" : ""
            let cleanedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            message = if let cleanedSummary, !cleanedSummary.isEmpty {
                "Context compacted\(tokenBadge): \(cleanedSummary)"
            } else {
                "Context compacted\(tokenBadge)"
            }
        }
        let id = currentCompactionItemID ?? UUID().uuidString
        let item = ChatItem.systemEvent(id: id, message: message)
        if let idx = indexForID(id) {
            items[idx] = item
        } else {
            items.append(item)
            indexAppend(item)
        }
        currentCompactionItemID = nil
        return true
    }

    // RPC results — model changes get a system event, others are silent
    private func handleCommandResult(command: String, success: Bool, error: String?) -> Bool {
        if !success, let err = error {
            items.append(.error(id: UUID().uuidString, message: "\(command) failed: \(err)"))
            return true
        }
        if command == "set_model" || command == "cycle_model" {
            items.append(.systemEvent(id: UUID().uuidString, message: String(localized: "Model changed")))
            return true
        }
        if command == "set_thinking_level" || command == "cycle_thinking_level" {
            items.append(.systemEvent(id: UUID().uuidString, message: String(localized: "Thinking level changed")))
            return true
        }
        return false
    }

    // MARK: - User Message (from local prompt)

    /// Check if a user message with the given text already exists in the timeline.
    /// Used to avoid duplicating the user bubble when a server-side prompt is echoed back.
    func hasUserMessage(matching text: String) -> Bool {
        items.contains { item in
            if case .userMessage(_, let existingText, _, _) = item {
                return existingText == text
            }
            return false
        }
    }

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
        itemIndex.remove(id: id)
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

    // periphery:ignore - used by OppiTests via @testable import
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

        // Reconnect/history-reload race: suppress stale in-flight message_end duplicates.
        if shouldSuppressDuplicateMessageEnd(content) {
            finalizeAssistantMessage()
            return
        }

        // If we're actively streaming (currentAssistantID != nil), replace
        // the buffer with the authoritative messageEnd content and finalize.
        // If no active streaming, update the latest assistant message in-place
        // to avoid creating a duplicate row with different text.
        if currentAssistantID == nil, let latestID = latestAssistantItemID() {
            // Stale messageEnd after finalize — update the existing item
            // rather than appending a new one.
            let item = TimelineTurnAssembler.makeAssistantItem(
                id: latestID,
                text: content,
                timestamp: Date()
            )
            if let idx = indexForID(latestID) {
                items[idx] = item
                bumpItemsMutationSeq()
            }
        } else {
            assistantBuffer = content
            upsertAssistantMessage()
        }
        finalizeAssistantMessage()
    }

    private func shouldSuppressDuplicateMessageEnd(_ content: String) -> Bool {
        let latestAssistantItem = items.reversed().first {
            if case .assistantMessage = $0 { return true }
            return false
        }

        return TimelineTurnAssembler.shouldSuppressDuplicateMessageEnd(
            content: content,
            turnInProgress: turnInProgress,
            currentAssistantID: currentAssistantID,
            latestAssistantItem: latestAssistantItem
        )
    }

    /// ID of the most recent assistant message in the timeline.
    private func latestAssistantItemID() -> String? {
        for item in items.reversed() {
            if case .assistantMessage(let id, _, _) = item { return id }
        }
        return nil
    }

    private func upsertAssistantMessage() {
        let id: String
        if let currentAssistantID {
            id = currentAssistantID
        } else if !turnInProgress,
                  let lastItem = items.last,
                  case .assistantMessage(let latestID, _, let latestTimestamp) = lastItem {
            // Recovery path: if a premature/synthetic end finalized the most
            // recent assistant row and more text arrives before a new turn
            // starts, resume that same row instead of appending a duplicate.
            id = latestID
            currentAssistantID = latestID
            currentAssistantTimestamp = latestTimestamp
        } else {
            id = UUID().uuidString
            currentAssistantID = id
            currentAssistantTimestamp = Date()
        }
        lastAssistantIDThisTurn = id

        let item = TimelineTurnAssembler.makeAssistantItem(
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
        bumpItemsMutationSeq()
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
        let previousHasMore = thinkingBuffer.utf8.count > ChatItem.maxPreviewLength

        thinkingBuffer += delta

        let newPreview = thinkingPreviewText()
        let newHasMore = thinkingBuffer.utf8.count > ChatItem.maxPreviewLength
        return newPreview != previousPreview || newHasMore != previousHasMore
    }

    private func upsertThinking() {
        let id = ensureCurrentThinkingID()

        let item = TimelineTurnAssembler.makeThinkingItem(
            id: id,
            preview: thinkingPreviewText(),
            hasMore: thinkingBuffer.utf8.count > ChatItem.maxPreviewLength
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
        bumpItemsMutationSeq()
    }

    private func finalizeAssistantMessage() {
        guard !assistantBuffer.isEmpty else {
            return
        }
        // If the buffer is only whitespace (e.g., "\n\n" before a tool call),
        // discard it instead of creating an empty bubble.
        if TimelineTurnAssembler.isWhitespaceOnly(assistantBuffer) {
            // Remove the in-progress item if it was already appended
            if let id = currentAssistantID {
                items.removeAll { $0.id == id }
                bumpItemsMutationSeq()
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
                bumpItemsMutationSeq()
            } else {
                // Mark the thinking item as done so the spinner stops.
                items[idx] = TimelineTurnAssembler.makeThinkingItem(
                    id: id,
                    preview: preview,
                    hasMore: hasMore,
                    isDone: true
                )
                bumpItemsMutationSeq()
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
            guard case .toolCall = items[idx] else { continue }
            guard let doneItem = TimelineTurnAssembler.makeDoneToolCall(existing: items[idx], isError: false) else {
                continue
            }
            if doneItem != items[idx] {
                items[idx] = doneItem
                bumpItemsMutationSeq()
            }
        }
    }

    /// Fast path for loadSession: applies the preview update without equality
    /// checking or re-fetching fullOutput from the store.
    /// Direct preview update for loadSession — skips dictionary lookups for output
    /// since the caller already has the data.
    private func updateToolCallPreviewDirect(id: String, output: String, outputByteCount: Int, isError: Bool) {
        guard let idx = indexForID(id) else { return }
        guard let updated = TimelineTurnAssembler.makeUpdatedToolCallPreview(
            existing: items[idx],
            output: output,
            outputByteCount: outputByteCount,
            isError: isError
        ) else { return }
        items[idx] = updated
        bumpItemsMutationSeq()
    }

    @discardableResult
    private func updateToolCallPreview(id: String, isError: Bool) -> Bool {
        guard let idx = indexForID(id) else {
            return false
        }

        let fullOutput = toolOutputStore.fullOutput(for: id)
        let outputByteCount = toolOutputStore.outputByteCount(for: id)
        guard let updated = TimelineTurnAssembler.makeUpdatedToolCallPreview(
            existing: items[idx],
            output: fullOutput,
            outputByteCount: outputByteCount,
            isError: isError
        ) else {
            return false
        }

        if items[idx] == updated {
            return false
        }

        items[idx] = updated
        bumpItemsMutationSeq()
        return true
    }

    private func updateToolCallDone(id: String, isError: Bool = false) {
        guard let idx = indexForID(id),
              let doneItem = TimelineTurnAssembler.makeDoneToolCall(existing: items[idx], isError: isError)
        else {
            return
        }

        items[idx] = doneItem
        bumpItemsMutationSeq()
    }

    // trimIfNeeded() removed — full timeline is always preserved.

    private func bumpRenderVersion() {
        renderVersion &+= 1
    }

    // MARK: - Indexed Helpers

    /// Find an item's index by ID using the O(1) cache.
    /// Falls back to linear scan if cache is stale (should not happen in practice).
    private func indexForID(_ id: String) -> Int? {
        itemIndex.indexForID(id, items: items)
    }

    /// Rebuild the full index. Call after bulk mutations (reset, loadSession, trim).
    private func rebuildIndex() {
        itemIndex.rebuildIndex(items)
    }

    /// Register a newly appended item in the index.
    private func indexAppend(_ item: ChatItem) {
        itemIndex.indexAppend(item, itemCount: items.count)
    }

    // MARK: - Orphan Positioning

    /// Find the chronologically correct insertion index for an orphaned
    /// user message within the rebuilt items array.
    ///
    /// Scans backward for the last item whose timestamp is ≤ the orphan's.
    /// Items without timestamps (tools, thinking, system events) are skipped;
    /// the orphan lands after the nearest preceding timestamped item (typically
    /// the assistant message it was responding to). Falls back to the end
    /// when no earlier timestamped item exists.
    static func chronologicalInsertionIndex(for orphan: ChatItem, in items: [ChatItem]) -> Int {
        guard let orphanTs = orphan.timestamp else {
            return items.endIndex
        }

        for i in stride(from: items.count - 1, through: 0, by: -1) {
            if let itemTs = items[i].timestamp, itemTs <= orphanTs {
                return i + 1
            }
        }

        return items.endIndex
    }

}
