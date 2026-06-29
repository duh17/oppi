import Foundation

extension MessageQueueStoreTelemetry {
    static let appMetrics = MessageQueueStoreTelemetry { event in
        let metric: ChatMetricName
        switch event.name {
        case .staleDrop:
            metric = .messageQueueStaleDrop
        case .startMiss:
            metric = .messageQueueStartMiss
        }

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: metric,
                value: 1,
                unit: .count,
                sessionId: event.sessionId,
                tags: event.tags
            )
        }
    }
}
