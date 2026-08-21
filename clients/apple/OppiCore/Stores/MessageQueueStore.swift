import Foundation

struct MessageQueueStoreMetricEvent: Equatable, Sendable {
    enum Name: String, Equatable, Sendable {
        case staleDrop
        case startMiss
    }

    let name: Name
    let sessionId: String
    let tags: [String: String]
}

struct MessageQueueStoreTelemetry: Sendable {
    let record: @Sendable (MessageQueueStoreMetricEvent) -> Void

    init(record: @escaping @Sendable (MessageQueueStoreMetricEvent) -> Void = { _ in }) {
        self.record = record
    }

    static let none = MessageQueueStoreTelemetry()
}

@MainActor @Observable
final class MessageQueueStore {
    private let telemetry: MessageQueueStoreTelemetry
    private(set) var queuesBySessionId: [String: MessageQueueState] = [:]

    init(telemetry: MessageQueueStoreTelemetry = .none) {
        self.telemetry = telemetry
    }

    func queue(for sessionId: String?) -> MessageQueueState {
        guard let sessionId else { return .empty }
        return queuesBySessionId[sessionId] ?? .empty
    }

    func apply(_ state: MessageQueueState, for sessionId: String) {
        if let current = queuesBySessionId[sessionId], state.version < current.version {
            recordQueueEventMetric(
                .staleDrop,
                sessionId: sessionId,
                tags: [
                    "source": "queue_state",
                    "incoming_version": String(state.version),
                    "current_version": String(current.version),
                ]
            )
            return
        }

        queuesBySessionId[sessionId] = state.preservingLocalMedia(
            from: queuesBySessionId[sessionId]
        )
    }

    func clear(sessionId: String) {
        queuesBySessionId.removeValue(forKey: sessionId)
    }

    @discardableResult
    func enqueueOptimisticItem(
        for sessionId: String,
        kind: MessageQueueKind,
        message: String,
        attachments: [ChatAttachmentRef]?,
        optimisticImages: [ImageAttachment]? = nil,
        id: String = "local-\(UUID().uuidString)"
    ) -> MessageQueueItem {
        var state = queuesBySessionId[sessionId] ?? .empty
        let item = MessageQueueItem(
            id: id,
            message: message,
            attachments: attachments,
            optimisticImages: optimisticImages,
            createdAt: Int(Date().timeIntervalSince1970 * 1_000)
        )

        switch kind {
        case .steer:
            state.steering.append(item)
        case .followUp:
            state.followUp.append(item)
        }

        queuesBySessionId[sessionId] = state
        return item
    }

    func removeQueuedItem(
        for sessionId: String,
        kind: MessageQueueKind,
        id: String,
        messageFallback: String
    ) {
        guard var state = queuesBySessionId[sessionId] else { return }

        let removed: Bool
        switch kind {
        case .steer:
            removed = remove(id: id, message: messageFallback, from: &state.steering)
        case .followUp:
            removed = remove(id: id, message: messageFallback, from: &state.followUp)
        }

        guard removed else { return }

        queuesBySessionId[sessionId] = state
    }

    func applyQueueItemStarted(
        for sessionId: String,
        kind: MessageQueueKind,
        item: MessageQueueItem,
        queueVersion: Int
    ) {
        var state = queuesBySessionId[sessionId] ?? .empty
        guard queueVersion >= state.version else {
            recordQueueEventMetric(
                .staleDrop,
                sessionId: sessionId,
                tags: [
                    "source": "queue_item_started",
                    "incoming_version": String(queueVersion),
                    "current_version": String(state.version),
                ]
            )
            return
        }

        let removed: Bool
        switch kind {
        case .steer:
            removed = remove(item: item, from: &state.steering)
        case .followUp:
            removed = remove(item: item, from: &state.followUp)
        }

        if !removed {
            recordQueueEventMetric(
                .startMiss,
                sessionId: sessionId,
                tags: [
                    "kind": kind.rawValue,
                    "queue_version": String(queueVersion),
                ]
            )
        }

        state.version = queueVersion
        queuesBySessionId[sessionId] = state
    }

    private func recordQueueEventMetric(
        _ name: MessageQueueStoreMetricEvent.Name,
        sessionId: String,
        tags: [String: String]
    ) {
        telemetry.record(MessageQueueStoreMetricEvent(
            name: name,
            sessionId: sessionId,
            tags: tags
        ))
    }

    @discardableResult
    private func remove(item: MessageQueueItem, from list: inout [MessageQueueItem]) -> Bool {
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            list.remove(at: index)
            return true
        }

        if let index = list.firstIndex(where: { $0.message == item.message }) {
            list.remove(at: index)
            return true
        }

        return false
    }

    @discardableResult
    private func remove(id: String, message: String, from list: inout [MessageQueueItem]) -> Bool {
        if let index = list.firstIndex(where: { $0.id == id }) {
            list.remove(at: index)
            return true
        }

        if let index = list.firstIndex(where: { $0.message == message }) {
            list.remove(at: index)
            return true
        }

        return false
    }
}
