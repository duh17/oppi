import Foundation

/// Batches high-frequency stream deltas for smooth 30fps rendering.
///
/// Rules:
/// - `textDelta` / `thinkingDelta` / `toolOutput`: buffer and flush every 33ms
/// - All other events: flush buffer immediately, then deliver event
///
/// This prevents per-token/chunk SwiftUI diff thrash while keeping tool starts,
/// permissions, and errors latency-free.
///
/// Call `pause()` when the app enters background to stop the flush timer.
/// Call `resume()` on foreground return to flush accumulated events in one batch.
@MainActor
final class DeltaCoalescer {
    private var buffer: [AgentEvent] = []
    private var flushTask: Task<Void, Never>?
    private let flushInterval: Duration = .milliseconds(33)

    /// Guardrail caps to prevent runaway queue growth during bursty streams.
    private let maxBufferedEvents = 512
    private let maxBufferedBytes = 256 * 1024
    private var bufferedBytes = 0

    /// When true, high-frequency events accumulate but don't flush on timer.
    /// Immediate events (tool start, permissions, etc.) still flush + deliver.
    private var isPaused = false

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

        // Everything else: flush pending deltas first, then deliver immediately
        case .permissionRequest,
             .permissionExpired,
             .toolStart,
             .toolEnd,
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
            onFlush?([event])
        }
    }

    /// Force flush (e.g., on disconnect).
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        deliverBuffer()
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

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .coalescerFlushEvents,
                value: Double(events.count),
                unit: .count
            )
            await ChatMetricsService.shared.record(
                metric: .coalescerFlushBytes,
                value: Double(flushedBytes),
                unit: .count
            )
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

    private func estimatedPayloadBytes(_ event: AgentEvent) -> Int {
        switch event {
        case .textDelta(_, let delta):
            return delta.utf8.count
        case .thinkingDelta(_, let delta):
            return delta.utf8.count
        case .toolOutput(_, _, let output, _):
            return output.utf8.count
        default:
            return 0
        }
    }
}
