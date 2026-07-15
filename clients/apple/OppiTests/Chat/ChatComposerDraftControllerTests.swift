import Foundation
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

    @Test func acknowledgedSubmissionClearsMatchingDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "send this")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = controller.beginSubmission()
        #expect(controller.text.isEmpty)
        #expect(store.record(for: key)?.payload.text == "send this")

        controller.completeSubmission(submission)
        #expect(store.record(for: key) == nil)
    }

    @Test func acknowledgedSubmissionDoesNotClearNewerTyping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController(initialText: "send this")
        controller.attach(store: store, key: key, isEphemeral: false)

        let submission = controller.beginSubmission()
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

        let submission = controller.beginSubmission()
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

        let submission = controller.beginSubmission()
        controller.text = "new typing"
        controller.repoPointers = [
            PendingFileReference(path: "Sources/New.swift", isDirectory: false),
        ]
        controller.failSubmission(submission)

        #expect(controller.text == "failed message\n\nnew typing")
        #expect(controller.repoPointers.map(\.path) == ["Sources/Old.swift", "Sources/New.swift"])
        #expect(store.record(for: key)?.payload.text == "failed message\n\nnew typing")
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

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
