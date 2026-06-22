import Foundation

/// Batches high-frequency stream deltas for smooth rendering.
///
/// Rules:
/// - `textDelta` / `thinkingDelta` / `toolOutput`: buffer and flush about every 50ms
/// - Repeated `toolUpdate` / duplicate `toolStart` events for the same tool
///   call are also coalesced so streamed args (for example write/edit content)
///   don't thrash the reducer and collection layout on every chunk.
/// - Initial `toolStart` / `toolUpdate` plus all other events: flush buffer
///   immediately, then deliver event.
///
/// This prevents per-token/chunk SwiftUI diff thrash while keeping tool starts
/// and errors latency-free.
///
/// Call `pause()` when the app enters background to stop the flush timer.
/// Call `resume()` on foreground return to flush accumulated events in one batch.
@MainActor
final class DeltaCoalescer {
    private struct ToolStartKey: Hashable {
        let sessionId: String
        let toolEventId: String
    }

    private var buffer: [AgentEvent] = []
    private var flushTask: Task<Void, Never>?
    private let flushInterval: Duration = .milliseconds(50)
    private var activeToolStarts: Set<ToolStartKey> = []
    private var previewToolStarts: Set<ToolStartKey> = []

    /// Guardrail caps to prevent runaway queue growth during bursty streams.
    private let maxBufferedEvents = 512
    private static let maxBufferedBytes = 256 * 1024
    private var bufferedBytes = 0

    // periphery:ignore - validates large-payload chunking without duplicating the production cap in tests
    static var maxBufferedBytesForTesting: Int { maxBufferedBytes }

    // Telemetry accumulator — aggregate over ~10s of active flushes instead
    // of emitting per-flush (~30/sec). Flush/disconnect drains partial windows
    // only when they contain enough signal to explain render/coalescing cost.
    private var telemetryWindowEvents = 0
    private var telemetryWindowBytes = 0
    private var telemetryWindowFlushes = 0
    private static let telemetryFlushesPerWindow = 200
    private static let telemetryDrainMinimumFlushes = 10
    private static let telemetryDrainMinimumEvents = 20
    private static let telemetryDrainMinimumBytes = 64 * 1024

    /// When true, high-frequency events accumulate but don't flush on timer.
    /// Immediate events (tool start, lifecycle, errors, etc.) still flush + deliver.
    private var isPaused = false

    /// Active session ID for metric attribution. Set by SessionStreamCoordinator.
    var sessionId: String?

    /// Called when coalesced events should be delivered.
    var onFlush: (([AgentEvent]) -> Void)?

    /// Pause flush timer (call on app background). Buffer accumulates
    /// but no timer fires, saving CPU/battery while screen is off.
    func pause() {
        isPaused = true
        flushTask?.cancel()
        flushTask = nil
    }

    /// Resume flushing (call on app foreground). Immediately delivers
    /// any events that accumulated while paused.
    func resume() {
        isPaused = false
        deliverBuffer()
    }

    func receive(_ event: AgentEvent) {
        switch event {
        // High-frequency: batch
        case .textDelta, .thinkingDelta, .toolOutput:
            appendAppendableEvent(event)

        case .toolStart(let sessionId, let toolEventId, _, _, _):
            let key = ToolStartKey(sessionId: sessionId, toolEventId: toolEventId)
            if activeToolStarts.contains(key) {
                appendOrReplaceBufferedToolEvent(event, key: key)
            } else {
                activeToolStarts.insert(key)
                previewToolStarts.remove(key)
                flushNow()
                onFlush?([event])
            }

        case .toolUpdate(let sessionId, let toolEventId, _, _, _):
            let key = ToolStartKey(sessionId: sessionId, toolEventId: toolEventId)
            if activeToolStarts.contains(key) || previewToolStarts.contains(key) {
                appendOrReplaceBufferedToolEvent(event, key: key)
            } else {
                previewToolStarts.insert(key)
                flushNow()
                onFlush?([event])
            }

        case .toolEnd(let sessionId, let toolEventId, _, _, _):
            flushNow()
            activeToolStarts.remove(ToolStartKey(sessionId: sessionId, toolEventId: toolEventId))
            previewToolStarts.remove(ToolStartKey(sessionId: sessionId, toolEventId: toolEventId))
            onFlush?([event])

        // Everything else: flush pending deltas first, then deliver immediately
        case .agentStart,
             .agentEnd,
             .messageEnd,
             .sessionEnded,
             .error,
             .compactionStart,
             .compactionEnd,
             .retryStart,
             .retryEnd,
             .commandResult:
            flushNow()
            if case .agentStart = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            } else if case .agentEnd = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            } else if case .sessionEnded = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            } else if case .error = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            }
            onFlush?([event])
        }
    }

    /// Force flush (e.g., on disconnect).
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        deliverBuffer()
        drainTelemetryWindow()
    }

    /// Emit any accumulated telemetry that hasn't hit the window threshold yet.
    private func drainTelemetryWindow() {
        emitTelemetryWindow(force: false)
    }

    // MARK: - Private

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil, !isPaused else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.flushInterval ?? .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.deliverBuffer()
            self?.flushTask = nil
        }
    }

    private func deliverBuffer() {
        guard !buffer.isEmpty else { return }
        let events = buffer
        let flushedBytes = bufferedBytes
        buffer.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        onFlush?(events)

        telemetryWindowEvents += events.count
        telemetryWindowBytes += flushedBytes
        telemetryWindowFlushes += 1

        if telemetryWindowFlushes >= Self.telemetryFlushesPerWindow {
            emitTelemetryWindow(force: true)
        }
    }

    private func emitTelemetryWindow(force: Bool) {
        guard telemetryWindowFlushes > 0 else { return }
        let windowEvents = telemetryWindowEvents
        let windowBytes = telemetryWindowBytes
        let windowFlushes = telemetryWindowFlushes
        let sid = sessionId
        telemetryWindowEvents = 0
        telemetryWindowBytes = 0
        telemetryWindowFlushes = 0

        guard force || Self.shouldRecordTelemetryWindow(
            events: windowEvents,
            bytes: windowBytes,
            flushes: windowFlushes
        ) else { return }

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .coalescerFlushEvents,
                value: Double(windowEvents),
                unit: .count,
                sessionId: sid,
                tags: ["flushes": String(windowFlushes)]
            )
            await ChatMetricsService.shared.record(
                metric: .coalescerFlushBytes,
                value: Double(windowBytes),
                unit: .count,
                sessionId: sid,
                tags: ["flushes": String(windowFlushes)]
            )
        }
    }

    private static func shouldRecordTelemetryWindow(events: Int, bytes: Int, flushes: Int) -> Bool {
        flushes >= telemetryDrainMinimumFlushes
            || events >= telemetryDrainMinimumEvents
            || bytes >= telemetryDrainMinimumBytes
    }

    private func appendAppendableEvent(_ event: AgentEvent) {
        switch event {
        case .textDelta(let sessionId, let delta):
            recordOversizedTimelinePayloadIfNeeded(
                sessionId: sessionId,
                eventCount: 1,
                bytes: delta.utf8.count
            )
            appendChunkedText(delta) { chunk in
                .textDelta(sessionId: sessionId, delta: chunk)
            }
        case .thinkingDelta(let sessionId, let delta, let contentIndex):
            recordOversizedTimelinePayloadIfNeeded(
                sessionId: sessionId,
                eventCount: 1,
                bytes: delta.utf8.count
            )
            appendChunkedText(delta) { chunk in
                .thinkingDelta(sessionId: sessionId, delta: chunk, contentIndex: contentIndex)
            }
        case .toolOutput(let payload) where payload.mode == .append:
            recordOversizedTimelinePayloadIfNeeded(
                sessionId: payload.sessionId,
                eventCount: 1,
                bytes: payload.output.utf8.count
            )
            appendChunkedText(payload.output) { chunk in
                .toolOutput(.init(
                    sessionId: payload.sessionId,
                    toolEventId: payload.toolEventId,
                    output: chunk,
                    isError: payload.isError,
                    mode: payload.mode,
                    truncated: payload.truncated,
                    totalBytes: payload.totalBytes,
                    details: payload.details
                ))
            }
        default:
            appendBuffered(event)
        }
    }

    private func recordOversizedTimelinePayloadIfNeeded(sessionId: String?, eventCount: Int, bytes: Int) {
        guard bytes > Self.maxBufferedBytes else { return }
        MetricKitCrashContextStore.recordLargeTimelinePayload(
            sessionId: sessionId,
            eventCount: eventCount,
            bytes: bytes,
            largestEventBytes: bytes
        )
    }

    private func appendChunkedText(_ text: String, makeEvent: (String) -> AgentEvent) {
        guard text.utf8.count > Self.maxBufferedBytes else {
            appendBuffered(makeEvent(text))
            return
        }

        var chunk = ""
        chunk.reserveCapacity(Self.maxBufferedBytes)
        var chunkBytes = 0

        for scalar in text.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            if chunkBytes > 0, chunkBytes + scalarBytes > Self.maxBufferedBytes {
                appendBuffered(makeEvent(chunk))
                chunk.removeAll(keepingCapacity: true)
                chunkBytes = 0
            }
            chunk.unicodeScalars.append(scalar)
            chunkBytes += scalarBytes
        }

        if !chunk.isEmpty {
            appendBuffered(makeEvent(chunk))
        }
    }

    private func appendBuffered(_ event: AgentEvent) {
        buffer.append(event)
        bufferedBytes += estimatedPayloadBytes(event)

        if buffer.count >= maxBufferedEvents || bufferedBytes >= Self.maxBufferedBytes {
            flushNow()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func appendOrReplaceBufferedToolEvent(_ event: AgentEvent, key: ToolStartKey) {
        if let existingIndex = buffer.firstIndex(where: { matchesBufferedToolEvent($0, key: key) }) {
            bufferedBytes -= estimatedPayloadBytes(buffer[existingIndex])
            buffer[existingIndex] = event
            bufferedBytes += estimatedPayloadBytes(event)

            if buffer.count >= maxBufferedEvents || bufferedBytes >= Self.maxBufferedBytes {
                flushNow()
            }
            return
        }

        appendBuffered(event)
    }

    private func matchesBufferedToolEvent(_ event: AgentEvent, key: ToolStartKey) -> Bool {
        switch event {
        case .toolStart(let sessionId, let toolEventId, _, _, _),
             .toolUpdate(let sessionId, let toolEventId, _, _, _):
            return sessionId == key.sessionId && toolEventId == key.toolEventId
        default:
            return false
        }
    }

    private func estimatedPayloadBytes(_ event: AgentEvent) -> Int {
        switch event {
        case .textDelta(_, let delta):
            return delta.utf8.count
        case .thinkingDelta(_, let delta, _):
            return delta.utf8.count
        case .toolStart(_, _, let tool, let args, _),
             .toolUpdate(_, _, let tool, let args, _):
            return tool.utf8.count + args.reduce(into: 0) { partial, entry in
                partial += entry.key.utf8.count
                partial += estimatedPayloadBytes(entry.value)
            }
        case .toolOutput(let payload):
            return payload.output.utf8.count
        default:
            return 0
        }
    }

    private func estimatedPayloadBytes(_ value: JSONValue) -> Int {
        switch value {
        case .string(let string):
            return string.utf8.count
        case .number:
            return MemoryLayout<Double>.size
        case .bool:
            return 1
        case .null:
            return 0
        case .array(let values):
            return values.reduce(into: 0) { partial, element in
                partial += estimatedPayloadBytes(element)
            }
        case .object(let object):
            return object.reduce(into: 0) { partial, entry in
                partial += entry.key.utf8.count
                partial += estimatedPayloadBytes(entry.value)
            }
        }
    }
}
