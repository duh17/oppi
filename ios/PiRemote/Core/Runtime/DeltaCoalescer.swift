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

    /// Called when coalesced events should be delivered.
    var onFlush: (([AgentEvent]) -> Void)?

    func receive(_ event: AgentEvent) {
        switch event {
        // High-frequency: batch
        case .textDelta, .thinkingDelta, .toolOutput:
            buffer.append(event)
            scheduleFlushIfNeeded()

        // Everything else: flush pending deltas first, then deliver immediately
        case .permissionRequest,
             .permissionExpired,
             .toolStart,
             .toolEnd,
             .agentStart,
             .agentEnd,
             .sessionEnded,
             .error:
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
        onFlush?(events)
    }
}
