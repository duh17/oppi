import Testing
@testable import Oppi

@Suite("MessageQueueStore")
@MainActor
struct MessageQueueStoreTests {

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
            optimisticImages: nil
        )

        let queue = store.queue(for: "s1")
        #expect(queue.version == 10)
        #expect(queue.steering.count == 1)
    }

    @Test func removeQueuedItemDoesNotBumpServerVersion() {
        let store = MessageQueueStore()
        store.apply(
            MessageQueueState(
                version: 7,
                steering: [MessageQueueItem(id: "local-1", message: "queued", createdAt: 1)],
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

    @Test func enqueueOptimisticItemPreservesImagesAndAttachments() {
        let store = MessageQueueStore()
        let image = ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")
        let attachment = ChatAttachmentRef(
            id: "att-1",
            source: .upload,
            name: "image-1.png",
            mimeType: "image/png",
            sizeBytes: 5,
            workspacePath: ".pi/attachments/demo/image-1.png"
        )

        _ = store.enqueueOptimisticItem(
            for: "s1",
            kind: .steer,
            message: "queued",
            attachments: [attachment],
            optimisticImages: [image]
        )

        let queue = store.queue(for: "s1")
        #expect(queue.steering.first?.attachments == [attachment])
        #expect(queue.steering.first?.optimisticImages == [image])
    }

    @Test func enqueueOptimisticItemCanUseStableTurnId() {
        let store = MessageQueueStore()

        _ = store.enqueueOptimisticItem(
            for: "s1",
            kind: .steer,
            message: "queued",
            attachments: nil,
            id: "turn-123"
        )

        let queue = store.queue(for: "s1")
        #expect(queue.steering.first?.id == "turn-123")
    }

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
            optimisticImages: nil
        )

        store.applyQueueItemStarted(
            for: "s1",
            kind: .steer,
            item: MessageQueueItem(id: "server-1", message: "queued", createdAt: 2),
            queueVersion: 10
        )

        let queue = store.queue(for: "s1")
        #expect(queue.version == 10)
        #expect(queue.steering.isEmpty)
    }
}
