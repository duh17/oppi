import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Chat composer draft controller")
@MainActor
struct ChatComposerDraftControllerTests {
    @Test func unknownSessionMetadataAndIncognitoSessionsStayMemoryOnly() {
        #expect(ChatView.composerDraftIsMemoryOnly(hasSessionMetadata: false, isEphemeral: nil))
        #expect(ChatView.composerDraftIsMemoryOnly(hasSessionMetadata: true, isEphemeral: true))
        #expect(!ChatView.composerDraftIsMemoryOnly(hasSessionMetadata: true, isEphemeral: false))
        #expect(!ChatView.composerDraftIsMemoryOnly(hasSessionMetadata: true, isEphemeral: nil))
    }

    @Test func localCompactAppearsWhenServerDoesNotReturnIt() {
        let commands = ChatView.availableSlashCommands(from: [])

        #expect(commands.map(\.name) == ["compact"])
        #expect(commands.first?.description == "Compact context")
        #expect(commands.first?.source == .builtin)
    }

    @Test func serverCompactMetadataIsPreservedWithoutDuplicates() {
        let serverCompact = SlashCommand(
            name: "CoMpAcT",
            description: "Server-provided compact command",
            source: .extension
        )

        let commands = ChatView.availableSlashCommands(from: [serverCompact])

        #expect(commands == [serverCompact])
    }

    @Test func exactCompactSlashCommandUsesTheLocalCompactAction() {
        #expect(ChatView.localSlashCommand(for: "/compact") == .compact)
        #expect(ChatView.localSlashCommand(for: "  /COMPACT\n") == .compact)
        #expect(ChatView.localSlashCommand(for: "/compact keep recent work") == nil)
        #expect(ChatView.localSlashCommand(for: "please /compact") == nil)
    }

    @Test func endingReviewModeReturnsToPendingAskBeforeMessageMode() {
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "session",
            questions: [
                AskQuestion(
                    id: "question-1",
                    question: "Proceed?",
                    options: [],
                    multiSelect: false
                ),
            ],
            allowCustom: true,
            timeout: nil
        )

        #expect(ChatView.resolvedComposerMode(
            hasReviewComment: true,
            hasAskRequest: true
        ) == .reviewComment)
        #expect(ChatView.resolvedComposerAskRequest(
            ask,
            hasReviewComment: true
        ) == nil)
        #expect(ChatView.resolvedComposerMode(
            hasReviewComment: false,
            hasAskRequest: true
        ) == .ask)
        #expect(ChatView.resolvedComposerAskRequest(
            ask,
            hasReviewComment: false
        )?.id == ask.id)
        #expect(ChatView.resolvedComposerMode(
            hasReviewComment: false,
            hasAskRequest: false
        ) == .message)
    }

    @Test func restoresOnlyTheAttachedSessionDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let firstKey = try fixture.key(sessionID: "session-a")
        let secondKey = try fixture.key(sessionID: "session-b")
        store.setDraft(
            .init(
                text: "session A draft",
                repoPointers: [
                    .init(
                        path: "Sources/App.swift",
                        isDirectory: false,
                        kind: .workspaceFile,
                        displayPrefix: nil
                    ),
                ]
            ),
            for: firstKey
        )

        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: firstKey, isEphemeral: false)
        #expect(controller.text == "session A draft")
        #expect(controller.repoPointers.map(\.path) == ["Sources/App.swift"])

        controller.attach(store: store, key: secondKey, isEphemeral: false)
        #expect(controller.text.isEmpty)
        #expect(controller.repoPointers.isEmpty)
    }

    @Test func unresolvedSessionSwitchCannotWriteThroughPreviousKey() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let firstKey = try fixture.key(sessionID: "session-a")
        let secondKey = try fixture.key(sessionID: "session-b")
        let controller = ChatComposerDraftController(initialText: "session A draft")
        controller.attach(store: store, key: firstKey, isEphemeral: false)

        controller.detachForSessionChange()
        controller.text = "typed before session B metadata"

        #expect(store.record(for: firstKey)?.payload.text == "session A draft")
        controller.attach(store: store, key: secondKey, isEphemeral: false)
        #expect(controller.text == "typed before session B metadata")
        #expect(store.record(for: secondKey)?.payload.text == "typed before session B metadata")
    }

    @Test func askAndReviewInputCannotOverwriteMessageDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(
            initialText: "normal message",
            initialRepoPointers: [
                PendingFileReference(path: "Sources/App.swift", isDirectory: false),
            ]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        controller.setMode(.ask)
        #expect(controller.text.isEmpty)
        #expect(controller.repoPointers.isEmpty)
        controller.text = "temporary ask answer"

        controller.setMode(.reviewComment)
        controller.text = "temporary review comment"

        controller.setMode(.message)
        #expect(controller.text == "normal message")
        #expect(controller.repoPointers.map(\.path) == ["Sources/App.swift"])
        #expect(store.record(for: key)?.payload.text == "normal message")
    }

    @Test func incomingAskBindingWriteCannotOverwriteMessageDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(
            initialText: "message waiting for approval",
            initialRepoPointers: [
                PendingFileReference(path: "Sources/App.swift", isDirectory: false),
            ]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        controller.updateVisibleText("", for: .ask)
        controller.updateVisibleText("approved", for: .ask)

        #expect(controller.text == "approved")
        #expect(store.record(for: key)?.payload.text == "message waiting for approval")

        controller.setMode(.message)
        #expect(controller.text == "message waiting for approval")
        #expect(controller.repoPointers.map(\.path) == ["Sources/App.swift"])
    }

    @Test func submittedAskAnswerDoesNotOverwriteRestoredMessageDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "pre-ask draft")
        controller.attach(store: store, key: key, isEphemeral: false)

        controller.setMode(.ask)
        controller.updateVisibleText("because the larger tables should download", for: .ask)
        #expect(store.record(for: key)?.payload.text == "pre-ask draft")

        controller.clearSubmittedAskAnswer()
        #expect(controller.text.isEmpty)
        #expect(store.record(for: key)?.payload.text == "pre-ask draft")

        controller.setMode(.message)
        #expect(controller.text == "pre-ask draft")

        controller.updateVisibleText("because the larger tables should download", for: .message)
        #expect(controller.text == "pre-ask draft")
        #expect(store.record(for: key)?.payload.text == "pre-ask draft")

        controller.updateVisibleText("next real message", for: .message)
        #expect(controller.text == "next real message")
        #expect(store.record(for: key)?.payload.text == "next real message")
    }

    @Test func submittedAskAnswerDoesNotBecomeMessageDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: key, isEphemeral: false)

        controller.setMode(.ask)
        controller.updateVisibleText("submitted custom answer", for: .ask)
        controller.clearSubmittedAskAnswer()
        #expect(controller.text.isEmpty)
        #expect(store.record(for: key) == nil)

        controller.setMode(.message)
        controller.updateVisibleText("submitted custom answer", for: .message)
        #expect(controller.text.isEmpty)
        #expect(store.record(for: key) == nil)
    }

    @Test func retargetingReviewCommentClearsOnlyTransientInput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "normal message")
        controller.attach(store: store, key: key, isEphemeral: false)

        controller.setMode(.reviewComment)
        controller.text = "comment for the first selection"
        controller.setMode(.reviewComment, resetTransientInput: true)

        #expect(controller.text.isEmpty)
        controller.setMode(.message)
        #expect(controller.text == "normal message")
        #expect(store.record(for: key)?.payload.text == "normal message")
    }

    @Test func immediateSubmissionReattachBeforeAcknowledgementRestoresEmptyComposer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "sent before replay")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .immediately))
        #expect(controller.text.isEmpty)

        let returningController = ChatComposerDraftController()
        returningController.attach(store: store, key: key, isEphemeral: false)
        #expect(returningController.text.isEmpty)
        #expect(store.record(for: key) == nil)

        controller.completeSubmission(submission)
        #expect(returningController.text.isEmpty)
    }

    @Test func dispatchClearingTheVisibleAttachmentBarDoesNotClearPendingSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let attachment = PendingAttachment.localFile(
            name: "notes.txt",
            data: Data("notes".utf8),
            mimeType: "text/plain"
        )
        let controller = ChatComposerDraftController(
            initialText: "send this",
            initialPendingAttachments: [attachment]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .immediately))
        controller.setPendingAttachments([]) // ChatView's dispatch cleanup

        #expect(store.record(for: key) == nil)
        #expect(submission.payload.text == "send this")
        #expect(submission.payload.attachments.map(\.id) == [attachment.id])
        #expect(submission.pendingAttachments.first?.composerDraftData == Data("notes".utf8))

        controller.failSubmission(submission)
        #expect(controller.text == "send this")
        #expect(controller.pendingAttachments.map(\.id) == [attachment.id])
        #expect(controller.pendingAttachments.first?.composerDraftData == Data("notes".utf8))
        #expect(store.record(for: key)?.payload.text == "send this")
        #expect(store.record(for: key)?.payload.attachments.map(\.id) == [attachment.id])
    }

    @Test func askAndReviewTransitionsRestoreMessageAttachments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let attachment = PendingAttachment.localFile(
            name: "notes.txt",
            data: Data("notes".utf8),
            mimeType: "text/plain"
        )
        let controller = ChatComposerDraftController(
            initialText: "message",
            initialPendingAttachments: [attachment]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        controller.setMode(.ask)
        controller.setPendingAttachments([])
        controller.setMode(.reviewComment)
        controller.setPendingAttachments([])
        controller.setMode(.message)

        #expect(controller.pendingAttachments.map(\.id) == [attachment.id])
        #expect(store.record(for: key)?.payload.attachments.map(\.id) == [attachment.id])
    }

    @Test func acknowledgedSubmissionClearsMatchingDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "send this")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        #expect(controller.text == "send this")
        #expect(store.record(for: key)?.payload.text == "send this")

        controller.completeSubmission(submission)
        #expect(controller.text.isEmpty)
        #expect(store.record(for: key) == nil)
    }

    @Test func retainedSubmissionFailureKeepsSharedDraftWithoutDuplication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "retry me")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        #expect(controller.text == "retry me")

        controller.text = "edited while dispatching"
        controller.failSubmission(submission)

        #expect(controller.text == "edited while dispatching")
        #expect(store.record(for: key)?.payload.text == "edited while dispatching")
    }

    @Test func fileBackedSubmissionBlocksAttachmentMutationUntilAcknowledgement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let sentAttachment = PendingAttachment.localFile(
            name: "sent.txt",
            data: Data("sent".utf8),
            mimeType: "text/plain"
        )
        let newerAttachment = PendingAttachment.localFile(
            name: "next.txt",
            data: Data("next".utf8),
            mimeType: "text/plain"
        )
        let controller = ChatComposerDraftController(
            initialText: "send this",
            initialPendingAttachments: [sentAttachment]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        #expect(!controller.setPendingAttachments([newerAttachment]))
        #expect(controller.pendingAttachments.map(\.displayName) == ["sent.txt"])
        let didClearSubmittedDraft = controller.completeSubmission(submission)

        #expect(didClearSubmittedDraft)
        #expect(controller.text.isEmpty)
        #expect(controller.pendingAttachments.isEmpty)
        #expect(store.record(for: key) == nil)
    }

    @Test func retainedSubmissionCannotBeOverwrittenBySynchronousResubmit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "send once")
        controller.attach(store: store, key: key, isEphemeral: false)

        #expect(!ChatView.composerSendIsInFlight(
            isPreparingAttachments: false,
            actionIsSending: false,
            draftSubmissionIsInFlight: controller.isSubmissionInFlight
        ))

        let firstSubmission = try #require(ChatView.beginComposerSubmission(
            draftController: controller,
            draftClearance: .afterSuccess,
            isPreparingAttachments: false,
            actionIsSending: false
        ))
        #expect(ChatView.composerSendIsInFlight(
            isPreparingAttachments: false,
            actionIsSending: false,
            draftSubmissionIsInFlight: controller.isSubmissionInFlight
        ))
        let secondSubmission = ChatView.beginComposerSubmission(
            draftController: controller,
            draftClearance: .afterSuccess,
            isPreparingAttachments: false,
            actionIsSending: false
        )
        let didClearFirstSubmission = controller.completeSubmission(firstSubmission)

        #expect(secondSubmission.map { _ in true } == nil)
        #expect(didClearFirstSubmission)
        #expect(controller.text.isEmpty)
        #expect(store.record(for: key) == nil)
    }

    @Test func acknowledgedSubmissionTombstonesDetachedSessionDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "sent before navigation")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        controller.detachForSessionChange()
        let didClearVisibleDraft = controller.completeSubmission(submission)

        #expect(!didClearVisibleDraft)
        #expect(store.record(for: key) == nil)

        let returningController = ChatComposerDraftController()
        returningController.attach(store: store, key: key, isEphemeral: false)
        #expect(returningController.text.isEmpty)
    }

    @Test func acknowledgedSubmissionDoesNotClearNewerTyping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "send this")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        controller.text = "next message"
        controller.completeSubmission(submission)

        #expect(controller.text == "next message")
        #expect(store.record(for: key)?.payload.text == "next message")
    }

    @Test func acknowledgedImmediateSubmissionDoesNotClearNewerTyping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "send this")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .immediately))
        controller.text = "next message"
        controller.completeSubmission(submission)

        #expect(controller.text == "next message")
        #expect(store.record(for: key)?.payload.text == "next message")
    }

    @Test func failedSubmissionRestoresDurableDraftIfStorageWasCleared() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "retry me")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        store.clearDraft(for: key)
        controller.failSubmission(submission)

        #expect(controller.text == "retry me")
        #expect(store.record(for: key)?.payload.text == "retry me")
    }

    @Test func failedSubmissionRestoresWithoutDroppingNewerTyping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(
            initialText: "failed message",
            initialRepoPointers: [
                PendingFileReference(path: "Sources/Old.swift", isDirectory: false),
            ]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .immediately))
        controller.text = "new typing"
        controller.repoPointers = [
            PendingFileReference(path: "Sources/New.swift", isDirectory: false),
        ]
        controller.failSubmission(submission)

        #expect(controller.text == "failed message\n\nnew typing")
        #expect(controller.repoPointers.map(\.path) == ["Sources/Old.swift", "Sources/New.swift"])
        #expect(store.record(for: key)?.payload.text == "failed message\n\nnew typing")
    }

    @Test func restoresPhotoAndFileAttachmentsWithTheMessageDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let photo = PendingAttachment(
            id: "photo-1",
            source: .image,
            displayName: "photo.png",
            thumbnail: nil,
            imageAttachment: ImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(), mimeType: "image/png"),
            localFileData: nil,
            localMimeType: nil,
            uploadedReference: nil
        )
        let file = PendingAttachment.localFile(name: "notes.txt", data: Data("notes".utf8), mimeType: "text/plain")
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: key, isEphemeral: false)
        controller.setPendingAttachments([photo, file])
        controller.text = "Review these"
        await store.flush()

        let reloadedStore = fixture.makeStore()
        await reloadedStore.load()
        let reloadedController = ChatComposerDraftController()
        reloadedController.attach(store: reloadedStore, key: key, isEphemeral: false)

        #expect(reloadedController.text == "Review these")
        #expect(reloadedController.pendingAttachments.map(\.displayName) == ["photo.png", "notes.txt"])
        #expect(reloadedController.pendingAttachments.map(\.source) == [.image, .localFile])
    }

    @Test func restoresFileBackedVideoWithoutLoadingTheClipIntoMemory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, videoBytes, draftURL) = try fixture.makeImportedVideo(store: store, named: "clip.mp4", byte: 0x22)
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: key, isEphemeral: false)
        #expect(controller.setPendingAttachments([video]))
        controller.text = "See clip"
        await store.flush()

        #expect(store.attachmentData(for: key, attachmentID: video.id) == nil)
        #expect(store.attachmentFileURL(for: key, attachmentID: video.id)?.standardizedFileURL == draftURL.standardizedFileURL)

        let reloadedStore = fixture.makeStore()
        await reloadedStore.load()
        let reloaded = ChatComposerDraftController()
        reloaded.attach(store: reloadedStore, key: key, isEphemeral: false)

        #expect(reloaded.text == "See clip")
        let restored = try #require(reloaded.pendingAttachments.first)
        #expect(restored.source == .localFile)
        #expect(restored.displayName == "clip.mp4")
        #expect(restored.localFileData == nil)
        #expect(restored.composerDraftData == nil)
        let restoredURL = try #require(restored.localFileURL)
        #expect(restoredURL.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(try Data(contentsOf: restoredURL) == videoBytes)
        #expect(reloadedStore.attachmentData(for: key, attachmentID: restored.id) == nil)
    }

    @Test func releasingComposerKeepsTheCanonicalDraftVideo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, videoBytes, draftURL) = try fixture.makeImportedVideo(store: store, named: "clip.mp4", byte: 0x44)

        var controller: ChatComposerDraftController? = ChatComposerDraftController()
        controller?.attach(store: store, key: key, isEphemeral: false)
        #expect(controller?.setPendingAttachments([video]) == true)
        controller?.text = "See clip"
        await store.flush()
        #expect(controller?.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)

        controller = nil
        #expect(FileManager.default.fileExists(atPath: draftURL.path))
        #expect(try Data(contentsOf: draftURL) == videoBytes)

        let reloaded = ChatComposerDraftController()
        reloaded.attach(store: store, key: key, isEphemeral: false)
        let restoredURL = try #require(reloaded.pendingAttachments.first?.localFileURL)
        #expect(restoredURL.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(try Data(contentsOf: restoredURL) == videoBytes)
    }

    @Test func sessionSwitchKeepsTheCanonicalDraftVideo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, videoBytes, draftURL) = try fixture.makeImportedVideo(store: store, named: "clip.mp4", byte: 0x46)
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: key, isEphemeral: false)
        #expect(controller.setPendingAttachments([video]))
        controller.text = "See clip"

        controller.detachForSessionChange()
        await store.flush()

        #expect(store.record(for: key)?.payload.text == "See clip")
        #expect(store.attachmentFileURL(for: key, attachmentID: video.id)?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(try Data(contentsOf: draftURL) == videoBytes)

        let reloaded = ChatComposerDraftController()
        reloaded.attach(store: store, key: key, isEphemeral: false)
        #expect(reloaded.text == "See clip")
        let restoredURL = try #require(reloaded.pendingAttachments.first?.localFileURL)
        #expect(restoredURL.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(reloaded.pendingAttachments.first?.localFileData == nil)
        #expect(try Data(contentsOf: restoredURL) == videoBytes)
    }

    @Test func refusedNonMessageAttachmentUpdateDeletesDraftVideo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let (video, _, draftURL) = try fixture.makeImportedVideo(store: store, named: "ask.mp4", byte: 0x45)
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: try fixture.key(), isEphemeral: false)
        controller.setMode(.ask)

        let accepted = ChatView.applyPendingAttachments(
            [video],
            draftController: controller,
            current: []
        )

        #expect(accepted == nil)
        #expect(controller.pendingAttachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
    }

    @Test func failedAfterSuccessSendKeepsCanonicalDraftVideoForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, videoBytes, draftURL) = try fixture.makeImportedVideo(store: store, named: "retry.mp4", byte: 0x33)
        let controller = ChatComposerDraftController(
            initialText: "retry clip",
            initialPendingAttachments: [video]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        #expect(controller.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(submission.pendingAttachments.first?.localFileData == nil)
        #expect(submission.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)

        controller.failSubmission(submission)
        await store.flush()

        #expect(controller.text == "retry clip")
        #expect(controller.pendingAttachments.map(\.id) == [video.id])
        let restoredURL = try #require(controller.pendingAttachments.first?.localFileURL)
        #expect(restoredURL.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(controller.pendingAttachments.first?.localFileData == nil)
        #expect(try Data(contentsOf: restoredURL) == videoBytes)
        #expect(store.attachmentFileURL(for: key, attachmentID: video.id)?.standardizedFileURL == draftURL.standardizedFileURL)
    }

    @Test func reopenThenFailedSendKeepsCanonicalDraftVideo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, videoBytes, draftURL) = try fixture.makeImportedVideo(store: store, named: "retry.mp4", byte: 0x48)
        var controller: ChatComposerDraftController? = ChatComposerDraftController(
            initialText: "retry clip",
            initialPendingAttachments: [video]
        )
        controller?.attach(store: store, key: key, isEphemeral: false)
        await store.flush()
        controller = nil

        let reloaded = ChatComposerDraftController()
        reloaded.attach(store: store, key: key, isEphemeral: false)
        let restored = try #require(reloaded.pendingAttachments.first)
        #expect(restored.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)

        let submission = try #require(reloaded.beginSubmission(draftClearance: .afterSuccess))
        #expect(submission.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: draftURL.path))

        reloaded.failSubmission(submission)
        await store.flush()

        #expect(reloaded.text == "retry clip")
        let retryURL = try #require(reloaded.pendingAttachments.first?.localFileURL)
        #expect(retryURL.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(try Data(contentsOf: retryURL) == videoBytes)
        #expect(store.record(for: key)?.payload.attachments.map(\.id) == [video.id])
    }

    @Test func filesPickedVideoAdmitsIntoCanonicalDraftAndKeepsTextEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let source = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).mp4",
            directoryHint: .notDirectory
        )
        let videoBytes = Data(repeating: 0x71, count: 512)
        try videoBytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var pending: [PendingAttachment] = []
        var importError: String?
        let binding = Binding(get: { pending }, set: { pending = $0 })
        await ComposerShared.importSelectedFiles(
            .success([source]),
            into: binding,
            store: store,
            shouldAccept: { true },
            onFailure: { importError = $0 }
        )

        #expect(importError == nil)
        let imported = try #require(pending.first)
        let draftURL = try #require(imported.localFileURL)
        #expect(imported.localFileData == nil)
        #expect(imported.composerDraftData == nil)
        #expect(store.isImportedAttachmentFile(draftURL))
        #expect(try Data(contentsOf: draftURL) == videoBytes)
        #expect(try Data(contentsOf: source) == videoBytes)

        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: key, isEphemeral: false)
        #expect(controller.setPendingAttachments([imported]))
        controller.text = "caption after files pick"
        await store.flush()

        #expect(store.record(for: key)?.payload.text == "caption after files pick")
        #expect(store.attachmentFileURL(for: key, attachmentID: imported.id)?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(store.attachmentData(for: key, attachmentID: imported.id) == nil)

        let reloaded = ChatComposerDraftController()
        reloaded.attach(store: store, key: key, isEphemeral: false)
        #expect(reloaded.text == "caption after files pick")
        #expect(reloaded.pendingAttachments.first?.localFileData == nil)
        #expect(reloaded.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(try Data(contentsOf: draftURL) == videoBytes)
    }

    @Test func filesPickedTextFileStillLoadsAsInMemoryAttachment() async throws {
        let source = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).txt",
            directoryHint: .notDirectory
        )
        let bytes = Data("notes from files".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var pending: [PendingAttachment] = []
        var importError: String?
        let binding = Binding(get: { pending }, set: { pending = $0 })
        await ComposerShared.importSelectedFiles(
            .success([source]),
            into: binding,
            store: nil,
            shouldAccept: { true },
            onFailure: { importError = $0 }
        )

        #expect(importError == nil)
        let imported = try #require(pending.first)
        #expect(imported.localFileData == bytes)
        #expect(imported.localFileURL == nil)
        #expect(imported.localMimeType == "text/plain")
    }

    @Test func filesPickedVideoRefusedImportDeletesDraftFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).mp4",
            directoryHint: .notDirectory
        )
        try Data(repeating: 0x74, count: 128).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let imported = await ComposerShared.importSelectedFileURLs([source], store: store)
        let draftURL = try #require(imported.attachments.first?.localFileURL)
        #expect(FileManager.default.fileExists(atPath: draftURL.path))

        var pending: [PendingAttachment] = []
        var importError: String?
        let binding = Binding(get: { pending }, set: { pending = $0 })
        ComposerShared.finishPhotoLibraryImport(
            imported,
            into: binding,
            store: store,
            shouldAccept: { false },
            onFailure: { importError = $0 }
        )

        #expect(pending.isEmpty)
        #expect(importError == ComposerShared.photoLibraryImportRefusedMessage)
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
    }

    @Test func filesPickedVideoWithoutDraftStoreDoesNotCreateAChip() async throws {
        let source = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).mp4",
            directoryHint: .notDirectory
        )
        try Data(repeating: 0x72, count: 64).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var pending: [PendingAttachment] = []
        var importError: String?
        let binding = Binding(get: { pending }, set: { pending = $0 })
        await ComposerShared.importSelectedFiles(
            .success([source]),
            into: binding,
            store: nil,
            shouldAccept: { true },
            onFailure: { importError = $0 }
        )

        #expect(pending.isEmpty)
        #expect(importError == "Couldn't attach \(source.lastPathComponent).")
    }

    @Test func acknowledgedSubmissionRemovesInFlightVideoWhenTextChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, _, draftURL) = try fixture.makeImportedVideo(store: store, named: "clip.mp4", byte: 0x73)
        let controller = ChatComposerDraftController(
            initialText: "send this",
            initialPendingAttachments: [video]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = try #require(controller.beginSubmission(draftClearance: .afterSuccess))
        controller.text = "next message"
        let didClearSubmittedDraft = controller.completeSubmission(submission)

        #expect(didClearSubmittedDraft)
        #expect(controller.text == "next message")
        #expect(controller.pendingAttachments.isEmpty)
        #expect(store.record(for: key)?.payload.text == "next message")
        #expect(store.record(for: key)?.payload.attachments.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
    }

    @Test func ephemeralSessionDraftRemainsMemoryOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "private draft")

        controller.attach(store: store, key: key, isEphemeral: true)
        controller.text += " stays in memory"

        #expect(controller.text == "private draft stays in memory")
        #expect(store.record(for: key) == nil)
    }

    @Test func becomingEphemeralKeepsVisibleDraftButRemovesDiskRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "private after transition")

        controller.attach(store: store, key: key, isEphemeral: false)
        #expect(store.record(for: key) != nil)

        controller.attach(store: store, key: key, isEphemeral: true)

        #expect(controller.text == "private after transition")
        #expect(store.record(for: key) == nil)
    }

    private struct Fixture {
        let rootURL: URL
        let fileURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appending(path: "ChatComposerDraftControllerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            fileURL = rootURL.appending(path: "drafts.json", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        @MainActor
        func makeStore() -> ComposerDraftStore {
            ComposerDraftStore(fileURL: fileURL, saveDelay: .seconds(60))
        }

        func key(sessionID: String = "session") throws -> ComposerDraftKey {
            try #require(ComposerDraftKey(
                serverID: "server",
                workspaceID: "workspace",
                sessionID: sessionID
            ))
        }

        @MainActor
        func makeImportedVideo(
            store: ComposerDraftStore,
            named displayName: String,
            byte: UInt8,
            count: Int = 512
        ) throws -> (PendingAttachment, Data, URL) {
            let source = FileManager.default.temporaryDirectory.appending(
                path: "\(UUID().uuidString).mp4",
                directoryHint: .notDirectory
            )
            let videoBytes = Data(repeating: byte, count: count)
            try videoBytes.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let draftURL = try store.importAttachmentFile(from: source)
            let video = PendingAttachment.localFile(
                name: displayName,
                fileURL: draftURL,
                mimeType: "video/mp4",
                sizeBytes: videoBytes.count
            )
            return (video, videoBytes, draftURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
