import Foundation

@MainActor @Observable
final class MessageQueueStore {
    private(set) var queuesBySessionId: [String: MessageQueueState] = [:]

    func queue(for sessionId: String?) -> MessageQueueState {
        guard let sessionId else { return .empty }
        return queuesBySessionId[sessionId] ?? .empty
    }

    func apply(_ state: MessageQueueState, for sessionId: String) {
        if let current = queuesBySessionId[sessionId], state.version < current.version {
            return
        }

        queuesBySessionId[sessionId] = state
    }

    func clear(sessionId: String) {
        queuesBySessionId.removeValue(forKey: sessionId)
    }

    @discardableResult
    func enqueueOptimisticItem(
        for sessionId: String,
        kind: MessageQueueKind,
        message: String,
        images: [ImageAttachment]?
    ) -> MessageQueueItem {
        var state = queuesBySessionId[sessionId] ?? .empty
        let item = MessageQueueItem(
            id: "local-\(UUID().uuidString)",
            message: message,
            images: images,
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
            return
        }

        switch kind {
        case .steer:
            remove(item: item, from: &state.steering)
        case .followUp:
            remove(item: item, from: &state.followUp)
        }

        state.version = queueVersion
        queuesBySessionId[sessionId] = state
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
