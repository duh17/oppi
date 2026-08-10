import Foundation

struct DeltaCoalescerFlushWindow: Equatable, Sendable {
    let sessionId: String?
    let eventCount: Int
    let byteCount: Int
    let flushCount: Int
}

struct DeltaCoalescerLargeTimelinePayload: Equatable, Sendable {
    let sessionId: String?
    let eventCount: Int
    let byteCount: Int
    let largestEventByteCount: Int
}

struct DeltaCoalescerTelemetry: Sendable {
    let recordFlushWindow: @Sendable (DeltaCoalescerFlushWindow) async -> Void
    let recordLargeTimelinePayload: @Sendable (DeltaCoalescerLargeTimelinePayload) -> Void

    init(
        recordFlushWindow: @escaping @Sendable (DeltaCoalescerFlushWindow) async -> Void = { _ in },
        recordLargeTimelinePayload: @escaping @Sendable (DeltaCoalescerLargeTimelinePayload) -> Void = { _ in }
    ) {
        self.recordFlushWindow = recordFlushWindow
        self.recordLargeTimelinePayload = recordLargeTimelinePayload
    }

    static let none = DeltaCoalescerTelemetry()
}

/// Batches high-frequency stream deltas for smooth rendering.
///
/// Rules:
/// - `textDelta` / `thinkingDelta` / `toolOutput`: buffer and flush about every 50ms
/// - Repeated `toolUpdate` / duplicate `toolStart` events for the same tool
///   call are also coalesced so streamed args (for example write/edit content)
///   don't thrash the reducer and collection layout on every chunk.
/// - Initial `toolStart` / `toolUpdate` plus all other events: flush buffer
///   immediately, then deliver event while presentation is active.
/// - When paused, every event follows the bounded buffer path instead.
///
/// This prevents per-token/chunk SwiftUI diff thrash while keeping tool starts
/// and errors latency-free.
///
/// Call `pause()` when the scene is inactive or in the background. Pausing is
/// a hard presentation boundary: buffered events stay in this coalescer, but
/// no timeline callback runs until `resume()`.
/// Call `resume()` on foreground return to flush the bounded coalesced state in
/// one batch. The return value reports that an authoritative trace reload is
/// required because the paused buffer exceeded its safe bound.
@MainActor
final class DeltaCoalescer {
    private struct ToolStartKey: Hashable {
        let sessionId: String
        let toolEventId: String
    }

    private var buffer: [AgentEvent] = []
    private var flushTask: Task<Void, Never>?
    private var flushGeneration = 0
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

    /// When true, no timeline events are delivered. All events are accepted
    /// until the bounded buffer is full; after that, superseded presentation
    /// events are discarded and the next resume requests an authoritative
    /// trace reload. Shared session status is handled outside this callback.
    private var isPaused = false
    private var needsFullTraceReloadOnResume = false
    private var presentationReloadMarker = 0

    /// Active session ID for metric attribution. Set by SessionStreamCoordinator.
    var sessionId: String?

    private let telemetry: DeltaCoalescerTelemetry

    /// Called when coalesced events should be delivered.
    var onFlush: (([AgentEvent]) -> Void)?

    var isPresentationPaused: Bool { isPaused }

    /// True when an authoritative trace reload is still required after pause.
    /// Stays armed until `acknowledgePresentationTraceReload()` runs on a
    /// successful history apply, so a failed overflow reload can retry on the
    /// next resume/reconnect.
    var needsPresentationTraceReload: Bool { needsFullTraceReloadOnResume }

    /// Mark a non-coalesced timeline mutation for trace repair on resume.
    /// This keeps direct reducer paths behind the same hard presentation gate.
    func markPresentationNeedsTraceReload() {
        guard isPaused else { return }
        markFullTraceReloadRequired()
    }

    /// Marker for an authoritative reload attempt. A successful history apply
    /// must not clear a newer paused mutation that arrived while the fetch was
    /// in flight.
    var presentationTraceReloadMarker: Int { presentationReloadMarker }

    /// Clear the pending presentation reload after a successful authoritative
    /// history apply. Failed loads must leave the flag armed for retry.
    func acknowledgePresentationTraceReload(ifMarker marker: Int? = nil) {
        guard marker == nil || marker == presentationReloadMarker else { return }
        needsFullTraceReloadOnResume = false
    }

    init(telemetry: DeltaCoalescerTelemetry = .none) {
        self.telemetry = telemetry
    }

    /// Pause timeline presentation while the scene cannot present a useful
    /// frame. The buffer remains bounded; it never flushes from this state.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        cancelFlushTask()
    }

    /// Resume timeline presentation. Returns true when the paused buffer
    /// overflowed (or another paused mutation armed reload) and the caller
    /// must reload the authoritative trace instead of publishing an incomplete
    /// delta sequence.
    ///
    /// The reload flag stays armed until `acknowledgePresentationTraceReload()`
    /// so a failed overflow fetch can be retried on the next resume/reconnect.
    @discardableResult
    func resume() -> Bool {
        cancelFlushTask()
        isPaused = false

        guard needsFullTraceReloadOnResume else {
            deliverBuffer()
            return false
        }

        // Discard any partial buffer; the authoritative trace is required.
        // Keep needsFullTraceReloadOnResume set until history apply succeeds.
        buffer.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        return true
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
                deliverImmediately(event)
            }

        case .toolUpdate(let sessionId, let toolEventId, _, _, _):
            let key = ToolStartKey(sessionId: sessionId, toolEventId: toolEventId)
            if activeToolStarts.contains(key) || previewToolStarts.contains(key) {
                appendOrReplaceBufferedToolEvent(event, key: key)
            } else {
                previewToolStarts.insert(key)
                deliverImmediately(event)
            }

        case .toolEnd(let sessionId, let toolEventId, _, _, _):
            activeToolStarts.remove(ToolStartKey(sessionId: sessionId, toolEventId: toolEventId))
            previewToolStarts.remove(ToolStartKey(sessionId: sessionId, toolEventId: toolEventId))
            deliverImmediately(event)

        // Everything else: flush pending deltas first, then deliver immediately
        case .agentStart,
             .agentEnd,
             .agentSettled,
             .messageEnd,
             .cacheMiss,
             .sessionEnded,
             .error,
             .compactionStart,
             .compactionEnd,
             .retryStart,
             .retryEnd,
             .commandResult:
            if case .agentStart = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            } else if case .agentEnd = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            } else if case .agentSettled = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            } else if case .sessionEnded = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            } else if case .error = event {
                activeToolStarts.removeAll()
                previewToolStarts.removeAll()
            }
            deliverImmediately(event)
        }
    }

    /// Force flush (e.g., on disconnect). A paused coalescer never publishes
    /// through this escape hatch; the next resume owns delivery.
    func flushNow() {
        guard !isPaused else { return }
        cancelFlushTask()
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
        let generation = flushGeneration
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.flushInterval)
            guard !Task.isCancelled,
                  self.flushGeneration == generation,
                  !self.isPaused else {
                return
            }
            self.flushTask = nil
            self.deliverBuffer()
        }
    }

    private func cancelFlushTask() {
        flushGeneration &+= 1
        flushTask?.cancel()
        flushTask = nil
    }

    private func deliverBuffer() {
        guard !isPaused, !buffer.isEmpty else { return }
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

        let telemetry = telemetry
        let flushWindow = DeltaCoalescerFlushWindow(
            sessionId: sid,
            eventCount: windowEvents,
            byteCount: windowBytes,
            flushCount: windowFlushes
        )
        Task.detached(priority: .utility) {
            await telemetry.recordFlushWindow(flushWindow)
        }
    }

    private static func shouldRecordTelemetryWindow(events: Int, bytes: Int, flushes: Int) -> Bool {
        flushes >= telemetryDrainMinimumFlushes
            || events >= telemetryDrainMinimumEvents
            || bytes >= telemetryDrainMinimumBytes
    }

    private func appendAppendableEvent(_ event: AgentEvent) {
        switch event {
        case .textDelta(let sessionId, let delta, let contentIndex):
            recordOversizedTimelinePayloadIfNeeded(
                sessionId: sessionId,
                eventCount: 1,
                bytes: delta.utf8.count
            )
            appendChunkedText(delta) { chunk in
                .textDelta(sessionId: sessionId, delta: chunk, contentIndex: contentIndex)
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
        case .toolOutput(let payload) where payload.mode == .replace:
            appendOrReplaceBufferedToolOutput(payload)
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
        telemetry.recordLargeTimelinePayload(DeltaCoalescerLargeTimelinePayload(
            sessionId: sessionId,
            eventCount: eventCount,
            byteCount: bytes,
            largestEventByteCount: bytes
        ))
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
        if isPaused {
            guard !needsFullTraceReloadOnResume else { return }
            let eventBytes = estimatedPayloadBytes(event)
            guard buffer.count < maxBufferedEvents,
                  bufferedBytes + eventBytes <= Self.maxBufferedBytes else {
                markFullTraceReloadRequired()
                return
            }
            buffer.append(event)
            bufferedBytes += eventBytes
            return
        }

        buffer.append(event)
        bufferedBytes += estimatedPayloadBytes(event)

        if bufferCapacityReached {
            flushNow()
        } else {
            scheduleFlushIfNeeded()
        }
    }

    private func appendOrReplaceBufferedToolEvent(_ event: AgentEvent, key: ToolStartKey) {
        switch event {
        case .toolUpdate:
            // A preview update can arrive before the real toolStart. Keep that
            // preview in its original position; only coalesce updates after a
            // buffered toolStart so resume preserves lifecycle ordering.
            if let startIndex = buffer.firstIndex(where: { matchesBufferedToolStart($0, key: key) }) {
                if let updateIndex = buffer.indices.first(where: {
                    $0 > startIndex && matchesBufferedToolUpdate(buffer[$0], key: key)
                }) {
                    replaceBufferedEvent(at: updateIndex, with: event)
                } else {
                    appendBuffered(event)
                }
            } else if let updateIndex = buffer.firstIndex(where: { matchesBufferedToolUpdate($0, key: key) }) {
                replaceBufferedEvent(at: updateIndex, with: event)
            } else {
                appendBuffered(event)
            }

        case .toolStart:
            // A toolStart after a preview is a new lifecycle boundary, not a
            // replacement for the preview. Duplicate starts may still update
            // the already-buffered start in place.
            if let startIndex = buffer.firstIndex(where: { matchesBufferedToolStart($0, key: key) }) {
                replaceBufferedEvent(at: startIndex, with: event)
            } else {
                appendBuffered(event)
            }

        default:
            if let existingIndex = buffer.firstIndex(where: { matchesBufferedToolEvent($0, key: key) }) {
                replaceBufferedEvent(at: existingIndex, with: event)
            } else {
                appendBuffered(event)
            }
        }
    }

    private func replaceBufferedEvent(at index: Int, with event: AgentEvent) {
        let previousBytes = estimatedPayloadBytes(buffer[index])
        let eventBytes = estimatedPayloadBytes(event)
        if isPaused,
           bufferedBytes - previousBytes + eventBytes > Self.maxBufferedBytes {
            markFullTraceReloadRequired()
            return
        }
        bufferedBytes -= previousBytes
        buffer[index] = event
        bufferedBytes += eventBytes

        if isPaused {
            if pausedBufferExceeded {
                markFullTraceReloadRequired()
            }
        } else if bufferCapacityReached {
            flushNow()
        }
    }

    /// Replace-mode snapshots are last-write-wins. Collapse consecutive
    /// snapshots for one tool before they reach the reducer or byte cap.
    private func appendOrReplaceBufferedToolOutput(_ payload: ToolOutputEventPayload) {
        if let lastIndex = buffer.indices.last,
           case .toolOutput(let previous) = buffer[lastIndex],
           previous.mode == .replace,
           previous.sessionId == payload.sessionId,
           previous.toolEventId == payload.toolEventId {
            let mergedEvent = AgentEvent.toolOutput(.init(
                sessionId: payload.sessionId,
                toolEventId: payload.toolEventId,
                output: payload.output,
                isError: previous.isError || payload.isError,
                mode: payload.mode,
                truncated: payload.truncated,
                totalBytes: payload.totalBytes,
                details: payload.details ?? previous.details
            ))
            let previousBytes = estimatedPayloadBytes(buffer[lastIndex])
            let mergedBytes = estimatedPayloadBytes(mergedEvent)
            if isPaused,
               bufferedBytes - previousBytes + mergedBytes > Self.maxBufferedBytes {
                markFullTraceReloadRequired()
                return
            }
            bufferedBytes -= previousBytes
            buffer[lastIndex] = mergedEvent
            bufferedBytes += mergedBytes

            if isPaused {
                if pausedBufferExceeded {
                    markFullTraceReloadRequired()
                }
            } else if bufferCapacityReached {
                flushNow()
            } else {
                scheduleFlushIfNeeded()
            }
            return
        }

        appendBuffered(.toolOutput(payload))
    }

    private var bufferCapacityReached: Bool {
        buffer.count >= maxBufferedEvents || bufferedBytes >= Self.maxBufferedBytes
    }

    private var pausedBufferExceeded: Bool {
        buffer.count > maxBufferedEvents || bufferedBytes > Self.maxBufferedBytes
    }

    private func markFullTraceReloadRequired() {
        presentationReloadMarker &+= 1
        needsFullTraceReloadOnResume = true
        buffer.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        activeToolStarts.removeAll()
        previewToolStarts.removeAll()
        cancelFlushTask()
    }

    private func deliverImmediately(_ event: AgentEvent) {
        guard !isPaused else {
            appendBuffered(event)
            return
        }

        flushNow()
        onFlush?([event])
    }

    private func matchesBufferedToolEvent(_ event: AgentEvent, key: ToolStartKey) -> Bool {
        matchesBufferedToolStart(event, key: key) || matchesBufferedToolUpdate(event, key: key)
    }

    private func matchesBufferedToolStart(_ event: AgentEvent, key: ToolStartKey) -> Bool {
        guard case .toolStart(let sessionId, let toolEventId, _, _, _) = event else { return false }
        return sessionId == key.sessionId && toolEventId == key.toolEventId
    }

    private func matchesBufferedToolUpdate(_ event: AgentEvent, key: ToolStartKey) -> Bool {
        guard case .toolUpdate(let sessionId, let toolEventId, _, _, _) = event else { return false }
        return sessionId == key.sessionId && toolEventId == key.toolEventId
    }

    private func estimatedPayloadBytes(_ event: AgentEvent) -> Int {
        switch event {
        case .agentStart,
             .agentEnd,
             .agentSettled:
            return 0

        case .textDelta(_, let delta, _):
            return delta.utf8.count

        case .thinkingDelta(_, let delta, _):
            return delta.utf8.count

        case .messageEnd(_, let content, let assistantContent):
            return content.utf8.count + (assistantContent?.reduce(into: 0) { total, part in
                total += part.kind.utf8.count
                total += part.content?.utf8.count ?? 0
                total += part.toolCallId?.utf8.count ?? 0
            } ?? 0)

        case .cacheMiss(_, let id, let message):
            return id.utf8.count + message.utf8.count

        case .toolStart(_, _, let tool, let args, let callSegments),
             .toolUpdate(_, _, let tool, let args, let callSegments):
            return tool.utf8.count
                + estimatedPayloadBytes(args)
                + estimatedPayloadBytes(callSegments)

        case .toolOutput(let payload):
            return payload.output.utf8.count
                + estimatedPayloadBytes(payload.details)

        case .toolEnd(_, _, let details, _, let resultSegments):
            return estimatedPayloadBytes(details)
                + estimatedPayloadBytes(resultSegments)

        case .compactionStart(_, let reason):
            return reason.utf8.count

        case .compactionEnd(_, _, _, let summary, let tokensBefore):
            return estimatedPayloadBytes(summary)
                + (tokensBefore.map { String($0).utf8.count } ?? 0)

        case .retryStart(_, let attempt, let maxAttempts, let delayMs, let errorMessage):
            return String(attempt).utf8.count
                + String(maxAttempts).utf8.count
                + String(delayMs).utf8.count
                + errorMessage.utf8.count

        case .retryEnd(_, _, let attempt, let finalError):
            return String(attempt).utf8.count
                + estimatedPayloadBytes(finalError)

        case .commandResult(_, let command, let requestId, _, let data, let error):
            return command.utf8.count
                + estimatedPayloadBytes(requestId)
                + estimatedPayloadBytes(data)
                + estimatedPayloadBytes(error)

        case .sessionEnded(_, let reason):
            return reason.utf8.count

        case .error(_, let message):
            return message.utf8.count
        }
    }

    private func estimatedPayloadBytes(_ values: [String: JSONValue]) -> Int {
        values.reduce(into: 0) { partial, entry in
            partial += entry.key.utf8.count
            partial += estimatedPayloadBytes(entry.value)
        }
    }

    private func estimatedPayloadBytes(_ values: [StyledSegment]?) -> Int {
        values?.reduce(into: 0) { partial, segment in
            partial += segment.text.utf8.count
            partial += segment.style?.rawValue.utf8.count ?? 0
        } ?? 0
    }

    private func estimatedPayloadBytes(_ value: String?) -> Int {
        value?.utf8.count ?? 0
    }

    private func estimatedPayloadBytes(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        return estimatedPayloadBytes(value)
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
            return estimatedPayloadBytes(object)
        }
    }
}
