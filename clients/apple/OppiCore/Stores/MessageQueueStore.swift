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
    /// A session whose queue is its conversation replica's `pi.inbox`.
    private struct ConversationQueue {
        /// The replica's queue as last applied.
        var server = MessageQueueState.empty
        /// Optimistic items whose send the server acknowledged. Every frame after the
        /// acknowledgement reflects the input, queued or placed, so the next one drops them.
        var delivered: Set<String> = []
    }

    private let telemetry: MessageQueueStoreTelemetry
    private(set) var queuesBySessionId: [String: MessageQueueState] = [:]
    @ObservationIgnored private var conversationQueues: [String: ConversationQueue] = [:]
    /// Ids of the items `enqueueOptimisticItem` added that no server queue has replaced yet.
    /// A replica session keeps exactly these as pending; anything else in the store came from
    /// a server and the replica now says what the server holds.
    @ObservationIgnored private var optimisticIDs: [String: Set<String>] = [:]

    init(telemetry: MessageQueueStoreTelemetry = .none) {
        self.telemetry = telemetry
    }

    func queue(for sessionId: String?) -> MessageQueueState {
        guard let sessionId else { return .empty }
        return queuesBySessionId[sessionId] ?? .empty
    }

    /// Whether `sessionId`'s queue comes from its conversation replica, not `queue_state`.
    func isConversationQueue(_ sessionId: String) -> Bool {
        conversationQueues[sessionId] != nil
    }

    /// The queue of an attached durable session after a replica frame: the replica's items,
    /// then the optimistic items still waiting for their send. Takes the session over from
    /// `queue_state` until `endConversationQueue`; items a `get_queue` answer put in the store
    /// before that are the server's, and the replica replaces them.
    func applyConversationQueue(_ server: MessageQueueState, for sessionId: String) {
        var replica = conversationQueues[sessionId] ?? ConversationQueue()
        let current = queuesBySessionId[sessionId] ?? .empty
        let optimistic = optimisticIDs[sessionId] ?? []
        func pending(_ items: [MessageQueueItem]) -> [MessageQueueItem] {
            items.filter { optimistic.contains($0.id) && !replica.delivered.contains($0.id) }
        }
        let next = MessageQueueState(
            version: current.version,
            steering: server.steering + pending(current.steering),
            followUp: server.followUp + pending(current.followUp)
        )
        setOptimisticIDs(Set((pending(current.steering) + pending(current.followUp)).map(\.id)), for: sessionId)
        replica.server = server
        replica.delivered.removeAll()
        conversationQueues[sessionId] = replica
        if queuesBySessionId[sessionId] != next { queuesBySessionId[sessionId] = next }
    }

    /// `queue_state` owns the session's queue again.
    func endConversationQueue(for sessionId: String) {
        conversationQueues.removeValue(forKey: sessionId)
    }

    /// The server acknowledged the send of optimistic item `id`. A replica session drops it
    /// now if the replica already shows its input, else at the next frame; a classic
    /// session's next `queue_state` replaces it.
    func optimisticItemDelivered(_ id: String, kind: MessageQueueKind, message: String, for sessionId: String) {
        guard var replica = conversationQueues[sessionId] else { return }
        let shown = kind == .steer ? replica.server.steering : replica.server.followUp
        if shown.contains(where: { $0.message == message }) {
            removeQueuedItem(for: sessionId, kind: kind, id: id, messageFallback: message)
        } else {
            replica.delivered.insert(id)
            conversationQueues[sessionId] = replica
        }
    }

    func apply(_ state: MessageQueueState, for sessionId: String) {
        // The replica's `pi.inbox` is the queue; a `get_queue` answer does not replace it.
        guard !isConversationQueue(sessionId) else { return }
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
        // The server's queue replaces the optimistic items; an id it kept is the server's now.
        setOptimisticIDs([], for: sessionId)
    }

    private func setOptimisticIDs(_ ids: Set<String>, for sessionId: String) {
        if ids.isEmpty {
            optimisticIDs.removeValue(forKey: sessionId)
        } else {
            optimisticIDs[sessionId] = ids
        }
    }

    /// Drops the session's queue (a stop, an end). A replica session keeps what `pi.inbox`
    /// holds, since the server, not the stop, decides which inputs stay queued.
    func clear(sessionId: String) {
        setOptimisticIDs([], for: sessionId)
        if let replica = conversationQueues[sessionId] {
            queuesBySessionId[sessionId] = replica.server
        } else {
            queuesBySessionId.removeValue(forKey: sessionId)
        }
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
        optimisticIDs[sessionId, default: []].insert(id)
        return item
    }

    func removeQueuedItem(
        for sessionId: String,
        kind: MessageQueueKind,
        id: String,
        messageFallback: String
    ) {
        optimisticIDs[sessionId]?.remove(id)
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
        guard !isConversationQueue(sessionId) else { return }
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
