import Foundation

/// Batches high-frequency stream deltas for smooth 30fps rendering.
///
/// Rules:
/// - `textDelta` / `thinkingDelta` / `toolOutput`: buffer and flush every 33ms
/// - All other events: flush buffer immediately, then deliver event
///
/// This prevents per-token/chunk SwiftUI diff thrash while keeping tool starts,
/// permissions, and errors latency-free.
@MainActor
final class DeltaCoalescer {
    private var buffer: [AgentEvent] = []
    private var flushTask: Task<Void, Never>?
    private let flushInterval: Duration = .milliseconds(33)

    /// Guardrail caps to prevent runaway queue growth during bursty streams.
    private let maxBufferedEvents = 512
    private let maxBufferedBytes = 256 * 1024
    private var bufferedBytes = 0

    /// Called when coalesced events should be delivered.
    var onFlush: (([AgentEvent]) -> Void)?

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
        guard flushTask == nil else { return }
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
        buffer.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        onFlush?(events)
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
