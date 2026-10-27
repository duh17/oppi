import Foundation

extension MessageQueueStoreTelemetry {
    static let appMetrics = MessageQueueStoreTelemetry { event in
        switch event.detail {
        case .staleDrop(let source, let incomingVersion, let currentVersion):
            guard let queueEvent = TelemetryTag.QueueEvent(rawValue: source.rawValue) else { return }
            Telemetry.record(
                AppMessageQueueStaleDrop(
                    incomingVersion: incomingVersion,
                    currentVersion: currentVersion,
                    queueEvent: queueEvent
                ),
                sessionId: event.sessionId
            )
        case .startMiss(let kind, let queueVersion):
            guard let intent = TelemetryTag.Intent(rawValue: kind.rawValue) else { return }
            Telemetry.record(
                AppMessageQueueStartMiss(queueVersion: queueVersion, intent: intent),
                sessionId: event.sessionId
            )
        }
    }
}
