import Foundation
import Testing
@testable import Oppi

private final class MessageQueueTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [MessageQueueStoreMetricEvent] = []

    var telemetry: MessageQueueStoreTelemetry {
        MessageQueueStoreTelemetry { [weak self] event in
            self?.append(event)
        }
    }

    var events: [MessageQueueStoreMetricEvent] {
        lock.withLock { recordedEvents }
    }

    private func append(_ event: MessageQueueStoreMetricEvent) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}

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
            attachments: nil,
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
            type: "attachment",
            id: "att-1",
            source: .upload,
            name: "image-1.png",
            mimeType: "image/png",
            sizeBytes: 5,
            sha256: nil,
            kind: nil,
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
            attachments: nil,
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

    @Test func staleQueueStateRecordsTelemetryAndKeepsCurrentState() {
        let recorder = MessageQueueTelemetryRecorder()
        let store = MessageQueueStore(telemetry: recorder.telemetry)
        store.apply(
            MessageQueueState(version: 10, steering: [], followUp: []),
            for: "s1"
        )

        store.apply(
            MessageQueueState(version: 9, steering: [], followUp: []),
            for: "s1"
        )

        #expect(store.queue(for: "s1").version == 10)
        #expect(recorder.events == [
            MessageQueueStoreMetricEvent(
                name: .staleDrop,
                sessionId: "s1",
                tags: [
                    "source": "queue_state",
                    "incoming_version": "9",
                    "current_version": "10",
                ]
            )
        ])
    }

    @Test func queueItemStartedMissRecordsTelemetry() {
        let recorder = MessageQueueTelemetryRecorder()
        let store = MessageQueueStore(telemetry: recorder.telemetry)
        store.apply(
            MessageQueueState(version: 10, steering: [], followUp: []),
            for: "s1"
        )

        store.applyQueueItemStarted(
            for: "s1",
            kind: .followUp,
            item: MessageQueueItem(id: "server-1", message: "missing", createdAt: 2),
            queueVersion: 10
        )

        #expect(recorder.events == [
            MessageQueueStoreMetricEvent(
                name: .startMiss,
                sessionId: "s1",
                tags: [
                    "kind": "follow_up",
                    "queue_version": "10",
                ]
            )
        ])
    }

    @Test func applyKeepsOptimisticMediaWhenServerOmitsAttachments() {
        let store = MessageQueueStore()
        let image = ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")
        let photo = ChatAttachmentRef(
            type: "attachment",
            id: "att-photo",
            source: .upload,
            name: "shot.png",
            mimeType: "image/png",
            sizeBytes: 5,
            sha256: nil,
            kind: nil,
            workspacePath: ".pi/attachments/demo/shot.png"
        )
        let file = ChatAttachmentRef(
            type: "attachment",
            id: "att-file",
            source: .upload,
            name: "notes.txt",
            mimeType: "text/plain",
            sizeBytes: 4,
            sha256: nil,
            kind: .text,
            workspacePath: ".pi/attachments/demo/notes.txt"
        )

        _ = store.enqueueOptimisticItem(
            for: "s1",
            kind: .steer,
            message: "look at these",
            attachments: [photo, file],
            optimisticImages: [image],
            id: "turn-1"
        )

        store.apply(
            MessageQueueState(
                version: 3,
                steering: [
                    MessageQueueItem(
                        id: "turn-1",
                        message: "look at these",
                        createdAt: 2
                    )
                ],
                followUp: []
            ),
            for: "s1"
        )

        let item = store.queue(for: "s1").steering.first
        #expect(item?.attachments == [photo, file])
        #expect(item?.optimisticImages == [image])
        #expect(store.queue(for: "s1").version == 3)
    }

    @Test func applyDoesNotCopyMediaOntoADifferentQueuedItem() {
        let store = MessageQueueStore()
        let image = ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")
        let file = ChatAttachmentRef(
            type: "attachment",
            id: "att-file",
            source: .upload,
            name: "notes.txt",
            mimeType: "text/plain",
            sizeBytes: 4,
            sha256: nil,
            kind: .text,
            workspacePath: nil
        )

        _ = store.enqueueOptimisticItem(
            for: "s1",
            kind: .steer,
            message: "with file",
            attachments: [file],
            optimisticImages: [image],
            id: "turn-1"
        )

        store.apply(
            MessageQueueState(
                version: 4,
                steering: [
                    MessageQueueItem(id: "turn-2", message: "plain text", createdAt: 3)
                ],
                followUp: []
            ),
            for: "s1"
        )

        let item = store.queue(for: "s1").steering.first
        #expect(item?.id == "turn-2")
        #expect(item?.attachments == nil)
        #expect(item?.optimisticImages == nil)
    }

    @Test func applyKeepsLocalThumbsWhenServerQueueHasAttachmentRefs() {
        let store = MessageQueueStore()
        let image = ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")
        let photo = ChatAttachmentRef(
            type: "attachment",
            id: "att-photo",
            source: .upload,
            name: "shot.png",
            mimeType: "image/png",
            sizeBytes: 5,
            sha256: nil,
            kind: nil,
            workspacePath: ".pi/attachments/demo/shot.png"
        )

        _ = store.enqueueOptimisticItem(
            for: "s1",
            kind: .steer,
            message: "look",
            attachments: [photo],
            optimisticImages: [image],
            id: "turn-1"
        )

        store.apply(
            MessageQueueState(
                version: 3,
                steering: [
                    MessageQueueItem(
                        id: "turn-1",
                        message: "look",
                        attachments: [photo],
                        createdAt: 2
                    )
                ],
                followUp: []
            ),
            for: "s1"
        )

        let item = store.queue(for: "s1").steering.first
        #expect(item?.attachments == [photo])
        #expect(item?.optimisticImages == [image])
    }
}
