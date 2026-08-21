import Foundation
import Testing
@testable import Oppi

@Suite("Stopping a busy turn with queued messages")
struct MessageQueueComposerRestoreTests {
    @Test("Given steering and follow-up messages, when stop restores the queue, then every queued message moves into the composer")
    func queuedMessagesArePrependedToComposerText() {
        let queue = MessageQueueState(
            version: 12,
            steering: [
                MessageQueueItem(id: "s1", message: "first steer", createdAt: 1),
                MessageQueueItem(id: "s2", message: "second steer", createdAt: 2),
            ],
            followUp: [
                MessageQueueItem(id: "f1", message: "first follow-up", createdAt: 3),
            ]
        )

        let plan = MessageQueueComposerRestore.plan(
            queue: queue,
            currentText: "current draft"
        )

        #expect(plan?.restoredCount == 3)
        #expect(plan?.text == "first steer\n\nsecond steer\n\nfirst follow-up\n\ncurrent draft")
        #expect(plan?.clearedQueue.version == 13)
        #expect(plan?.clearedQueue.steering.isEmpty == true)
        #expect(plan?.clearedQueue.followUp.isEmpty == true)
    }

    @Test("Given queued messages and an empty composer, when stop restores the queue, then the composer contains only queued text")
    func emptyComposerDoesNotAddTrailingSpacing() {
        let queue = MessageQueueState(
            version: 1,
            steering: [
                MessageQueueItem(id: "s1", message: "retry this", createdAt: 1),
            ],
            followUp: []
        )

        let plan = MessageQueueComposerRestore.plan(
            queue: queue,
            currentText: "  \n"
        )

        #expect(plan?.restoredCount == 1)
        #expect(plan?.text == "retry this")
        #expect(plan?.clearedQueue.version == 2)
    }

    @Test("Given an empty queue, when stop asks for restore text, then no composer update is produced")
    func emptyQueueProducesNoRestorePlan() {
        let plan = MessageQueueComposerRestore.plan(
            queue: .empty,
            currentText: "current draft"
        )

        #expect(plan == nil)
    }

    @Test("Given queued uploaded files, when stop restores the queue, then attachments return to the composer")
    func uploadedFileReferencesReturnAsPendingAttachments() {
        let attachment = ChatAttachmentRef(
            type: "attachment",
            id: "att-1",
            source: .upload,
            name: "notes.txt",
            mimeType: "text/plain",
            sizeBytes: 42,
            sha256: nil,
            kind: nil,
            workspacePath: ".pi/attachments/s1/notes.txt"
        )
        let queue = MessageQueueState(
            version: 2,
            steering: [
                MessageQueueItem(
                    id: "s1",
                    message: "read this",
                    attachments: [attachment],
                    createdAt: 1
                ),
            ],
            followUp: []
        )

        let plan = MessageQueueComposerRestore.plan(
            queue: queue,
            currentText: ""
        )

        #expect(plan?.restoredCount == 1)
        #expect(plan?.text == "read this")
        #expect(plan?.pendingAttachments.map(\.id) == ["att-1"])
        if let source = plan?.pendingAttachments.first?.source,
           case .uploaded(let restored) = source {
            #expect(restored == attachment)
        } else {
            Issue.record("Queued attachment was not restored as an uploaded pending attachment")
        }
        #expect(plan?.clearedQueue.version == 3)
    }

    @Test("Given queued and current attachments, when stop restores the queue, then all attachments stay on the bar")
    func queuedAttachmentsJoinCurrentComposerAttachments() {
        let queued = ChatAttachmentRef(
            type: "attachment",
            id: "queued",
            source: .upload,
            name: "queued.txt",
            mimeType: "text/plain",
            sizeBytes: 4,
            sha256: nil,
            kind: .text,
            workspacePath: nil
        )
        let current = PendingAttachment.localFile(name: "current.txt", data: Data("now".utf8), mimeType: "text/plain")
        let plan = MessageQueueComposerRestore.plan(
            queue: MessageQueueState(
                version: 1,
                steering: [MessageQueueItem(id: "s1", message: "queued", attachments: [queued], createdAt: 1)],
                followUp: []
            ),
            currentText: "draft",
            currentPendingAttachments: [current]
        )

        #expect(plan?.text == "queued\n\ndraft")
        #expect(plan?.pendingAttachments.map(\.id) == ["queued", current.id])
    }
}

@Suite("MessageQueueAttachmentPresentation")
struct MessageQueueAttachmentPresentationTests {
    @Test func visibleAttachmentsShowPhotoThumbnailsAndFilePills() {
        let photo = ChatAttachmentRef(
            type: "attachment",
            id: "att-photo",
            source: .upload,
            name: "shot.png",
            mimeType: "image/png",
            sizeBytes: 5,
            sha256: nil,
            kind: nil,
            workspacePath: nil
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
            workspacePath: nil
        )
        let image = ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")
        let item = MessageQueueItem(
            id: "q1",
            message: "look",
            attachments: [photo, file],
            optimisticImages: [image],
            createdAt: 1
        )

        let chips = MessageQueueAttachmentPresentation.visibleAttachments(for: item)
        #expect(chips == [
            .photo(id: "att-photo", name: "shot.png", image: image),
            .file(id: "att-file", name: "notes.txt"),
        ])
    }

    @Test func widgetSubtitleNamesQueuedPhotosAndFiles() {
        #expect(
            MessageQueueAttachmentPresentation.widgetSubtitle(
                steeringCount: 1,
                followUpCount: 0,
                photoCount: 0,
                fileCount: 0
            ) == "1 steering • 0 follow-up"
        )
        #expect(
            MessageQueueAttachmentPresentation.widgetSubtitle(
                steeringCount: 1,
                followUpCount: 1,
                photoCount: 1,
                fileCount: 2
            ) == "1 steering • 1 follow-up • 1 photo • 2 files"
        )
        #expect(
            MessageQueueAttachmentPresentation.mediaHint(photoCount: 1, fileCount: 2)
                == "1 photo • 2 files"
        )
        #expect(MessageQueueAttachmentPresentation.mediaHint(photoCount: 0, fileCount: 0) == nil)
    }

    @Test func imageAttachmentsWithoutLocalBytesStayPhotos() {
        let photo = ChatAttachmentRef(
            type: "attachment",
            id: "att-photo",
            source: .upload,
            name: "shot.png",
            mimeType: "image/png",
            sizeBytes: 5,
            sha256: nil,
            kind: nil,
            workspacePath: nil
        )
        let item = MessageQueueItem(
            id: "q1",
            message: "look",
            attachments: [photo],
            createdAt: 1
        )

        #expect(
            MessageQueueAttachmentPresentation.visibleAttachments(for: item) == [
                .photo(id: "att-photo", name: "shot.png", image: nil),
            ]
        )
        let counts = MessageQueueAttachmentPresentation.mediaCounts(
            in: MessageQueueState(version: 1, steering: [item], followUp: [])
        )
        #expect(counts.photos == 1)
        #expect(counts.files == 0)
    }

    @Test func mediaCountsUseVisibleAttachments() {
        let queue = MessageQueueState(
            version: 1,
            steering: [
                MessageQueueItem(
                    id: "s1",
                    message: "photo",
                    attachments: [
                        ChatAttachmentRef(
                            type: "attachment",
                            id: "att-photo",
                            source: .upload,
                            name: "shot.png",
                            mimeType: "image/png",
                            sizeBytes: 5,
                            sha256: nil,
                            kind: nil,
                            workspacePath: nil
                        )
                    ],
                    optimisticImages: [ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")],
                    createdAt: 1
                )
            ],
            followUp: [
                MessageQueueItem(
                    id: "f1",
                    message: "file",
                    attachments: [
                        ChatAttachmentRef(
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
                    ],
                    createdAt: 2
                )
            ]
        )

        let counts = MessageQueueAttachmentPresentation.mediaCounts(in: queue)
        #expect(counts.photos == 1)
        #expect(counts.files == 1)
    }
}
