import Foundation

/// Batches high-frequency stream deltas for smooth 30fps rendering.
///
/// Rules:
/// - `textDelta` / `thinkingDelta` / `toolOutput`: buffer and flush every 33ms
/// - Repeated `toolStart` updates for the same in-flight tool call are also
///   coalesced so streamed args (for example write/edit content) don't thrash
///   the reducer and collection layout on every chunk.
/// - Initial `toolStart` plus all other events: flush buffer immediately,
///   then deliver event.
///
/// This prevents per-token/chunk SwiftUI diff thrash while keeping tool starts,
/// permissions, and errors latency-free.
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
    private let flushInterval: Duration = .milliseconds(33)
    private var activeToolStarts: Set<ToolStartKey> = []

    /// Guardrail caps to prevent runaway queue growth during bursty streams.
    private let maxBufferedEvents = 512
    private let maxBufferedBytes = 256 * 1024
    private var bufferedBytes = 0

    // Telemetry accumulator — aggregate over ~1s window instead of emitting
    // per-flush (~30/sec). Cuts telemetry volume from ~60 samples/sec to ~2.
    private var telemetryWindowEvents = 0
    private var telemetryWindowBytes = 0
    private var telemetryWindowFlushes = 0
    private static let telemetryFlushesPerWindow = 30

    /// When true, high-frequency events accumulate but don't flush on timer.
    /// Immediate events (tool start, permissions, etc.) still flush + deliver.
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
            appendBuffered(event)

        case .toolStart(let sessionId, let toolEventId, _, _, _):
            let key = ToolStartKey(sessionId: sessionId, toolEventId: toolEventId)
            if activeToolStarts.contains(key) {
                appendOrReplaceBufferedToolStart(event, key: key)
            } else {
                activeToolStarts.insert(key)
                flushNow()
                onFlush?([event])
            }

        case .toolEnd(let sessionId, let toolEventId, _, _, _):
            flushNow()
            activeToolStarts.remove(ToolStartKey(sessionId: sessionId, toolEventId: toolEventId))
            onFlush?([event])

        // Everything else: flush pending deltas first, then deliver immediately
        case .permissionRequest,
             .permissionExpired,
             .agentStart,
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
            } else if case .agentEnd = event {
                activeToolStarts.removeAll()
            } else if case .sessionEnded = event {
                activeToolStarts.removeAll()
            } else if case .error = event {
                activeToolStarts.removeAll()
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
        guard telemetryWindowFlushes > 0 else { return }
        let windowEvents = telemetryWindowEvents
        let windowBytes = telemetryWindowBytes
        let windowFlushes = telemetryWindowFlushes
        let sid = sessionId
        telemetryWindowEvents = 0
        telemetryWindowBytes = 0
        telemetryWindowFlushes = 0

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

    // MARK: - Private

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil, !isPaused else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.flushInterval ?? .milliseconds(33))
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

        // Accumulate telemetry over ~1s window (~30 flushes at 33ms)
        // instead of emitting 2 samples per flush.
        telemetryWindowEvents += events.count
        telemetryWindowBytes += flushedBytes
        telemetryWindowFlushes += 1

        if telemetryWindowFlushes >= Self.telemetryFlushesPerWindow {
            let windowEvents = telemetryWindowEvents
            let windowBytes = telemetryWindowBytes
            let windowFlushes = telemetryWindowFlushes
            let sid = sessionId
            telemetryWindowEvents = 0
            telemetryWindowBytes = 0
            telemetryWindowFlushes = 0

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
    }

    private func appendBuffered(_ event: AgentEvent) {
        buffer.append(event)
        bufferedBytes += estimatedPayloadBytes(event)

        if buffer.count >= maxBufferedEvents || bufferedBytes >= maxBufferedBytes {
            flushNow()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func appendOrReplaceBufferedToolStart(_ event: AgentEvent, key: ToolStartKey) {
        if let existingIndex = buffer.firstIndex(where: { matchesBufferedToolStart($0, key: key) }) {
            bufferedBytes -= estimatedPayloadBytes(buffer[existingIndex])
            buffer[existingIndex] = event
            bufferedBytes += estimatedPayloadBytes(event)

            if buffer.count >= maxBufferedEvents || bufferedBytes >= maxBufferedBytes {
                flushNow()
            }
            return
        }

        appendBuffered(event)
    }

    private func matchesBufferedToolStart(_ event: AgentEvent, key: ToolStartKey) -> Bool {
        guard case .toolStart(let sessionId, let toolEventId, _, _, _) = event else {
            return false
        }
        return sessionId == key.sessionId && toolEventId == key.toolEventId
    }

    private func estimatedPayloadBytes(_ event: AgentEvent) -> Int {
        switch event {
        case .textDelta(_, let delta):
            return delta.utf8.count
        case .thinkingDelta(_, let delta):
            return delta.utf8.count
        case .toolStart(_, _, let tool, let args, _):
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
