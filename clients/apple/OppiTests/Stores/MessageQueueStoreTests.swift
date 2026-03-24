import Testing
@testable import Oppi

@Suite("MessageQueueStore")
struct MessageQueueStoreTests {

    @MainActor
    @Test func enqueueOptimisticItemDoesNotBumpServerVersion() {
        let store = MessageQueueStore()
        store.apply(
            MessageQueueState(
                version: 10,
                steering: [],
                followUp: []
            ),
            for: "s1"
        )

        _ = store.enqueueOptimisticItem(
            for: "s1",
            kind: .steer,
            message: "queued",
            images: nil
        )

        let queue = store.queue(for: "s1")
        #expect(queue.version == 10)
        #expect(queue.steering.count == 1)
    }

    @MainActor
    @Test func removeQueuedItemDoesNotBumpServerVersion() {
        let store = MessageQueueStore()
        store.apply(
            MessageQueueState(
                version: 7,
                steering: [MessageQueueItem(id: "local-1", message: "queued", images: nil, createdAt: 1)],
                followUp: []
            ),
            for: "s1"
        )

        store.removeQueuedItem(
            for: "s1",
            kind: .steer,
            id: "local-1",
            messageFallback: "queued"
        )

        let queue = store.queue(for: "s1")
        #expect(queue.version == 7)
        #expect(queue.steering.isEmpty)
    }

    @MainActor
    @Test func queueItemStartedRemovesOptimisticItemAtCurrentServerVersion() {
        let store = MessageQueueStore()
        store.apply(
            MessageQueueState(
                version: 10,
                steering: [],
                followUp: []
            ),
            for: "s1"
        )

        _ = store.enqueueOptimisticItem(
            for: "s1",
            kind: .steer,
            message: "queued",
            images: nil
        )

        store.applyQueueItemStarted(
            for: "s1",
            kind: .steer,
            item: MessageQueueItem(id: "server-1", message: "queued", images: nil, createdAt: 2),
            queueVersion: 10
        )

        let queue = store.queue(for: "s1")
        #expect(queue.version == 10)
        #expect(queue.steering.isEmpty)
    }
}
