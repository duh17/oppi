import Foundation
import Testing
@testable import Oppi

@Suite("Composer draft local store")
@MainActor
struct ComposerDraftStoreTests {
    @Test func roundTripsExactTextAndRepoPointers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let key = try #require(ComposerDraftKey(
            serverID: "sha256:server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a"
        ))
        let payload = ComposerDraftPayload(
            text: "  keep leading whitespace\n\nand trailing whitespace  ",
            repoPointers: [
                ComposerDraftRepoPointer(
                    path: "Sources/App.swift",
                    isDirectory: false,
                    kind: .workspaceFile,
                    displayPrefix: nil
                ),
                ComposerDraftRepoPointer(
                    path: "Tests/AppTests.swift",
                    isDirectory: false,
                    kind: .reviewFile,
                    displayPrefix: "Review"
                ),
            ]
        )

        let store = fixture.makeStore()
        await store.load()
        store.setDraft(payload, for: key)
        await store.flush()

        let reloaded = fixture.makeStore()
        await reloaded.load()

        #expect(reloaded.record(for: key)?.payload == payload)
        #expect(reloaded.record(for: key)?.revision == 1)
    }

    @Test func roundTripsPhotoAndFileMetadataWithSidecarBytesWithoutEmbeddingBinaryInJSON() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let key = try fixture.key()
        let photoBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00])
        let fileBytes = Data("log contents".utf8)
        let payload = ComposerDraftPayload(
            text: "",
            repoPointers: [],
            attachments: [
                .init(id: "photo-1", displayName: "photo.png", mimeType: "image/png", source: .image, relativePath: nil, sizeBytes: photoBytes.count),
                .init(id: "file-1", displayName: "notes.txt", mimeType: "text/plain", source: .localFile, relativePath: nil, sizeBytes: fileBytes.count),
            ]
        )

        let store = fixture.makeStore()
        await store.load()
        store.setDraft(payload, attachmentData: [
            "photo-1": photoBytes,
            "file-1": fileBytes,
        ], for: key)
        await store.flush()

        let json = try Data(contentsOf: fixture.fileURL)
        #expect(String(decoding: json, as: UTF8.self).contains("photo.png"))
        #expect(!json.elementsEqual(photoBytes))
        #expect(FileManager.default.fileExists(atPath: fixture.sidecarDirectoryURL.path))

        let reloaded = fixture.makeStore()
        await reloaded.load()
        #expect(reloaded.record(for: key)?.payload.attachments.map(\.displayName) == ["photo.png", "notes.txt"])
        #expect(reloaded.attachmentData(for: key, attachmentID: "photo-1") == photoBytes)
        #expect(reloaded.attachmentData(for: key, attachmentID: "file-1") == fileBytes)
    }

    @Test func sidecarWriteFailureDoesNotPublishTheDraftRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let payload = ComposerDraftPayload(
            text: "",
            repoPointers: [],
            attachments: [.init(
                id: "invalid-path",
                displayName: "photo.jpg",
                mimeType: "image/jpeg",
                source: .image,
                relativePath: "outside/photo.blob",
                sizeBytes: 3
            )]
        )

        #expect(store.setDraft(payload, attachmentData: ["invalid-path": Data("jpg".utf8)], for: key) == nil)
        #expect(store.record(for: key) == nil)
    }

    @Test func updatingAnotherKeyDoesNotDeleteFirstKeysSidecarBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let firstKey = try fixture.key(sessionID: "session-a")
        let secondKey = try fixture.key(sessionID: "session-b")
        let firstBytes = Data("session A photo".utf8)

        store.setDraft(
            .init(
                text: "",
                repoPointers: [],
                attachments: [.init(id: "photo-a", displayName: "a.jpg", mimeType: "image/jpeg", source: .image, relativePath: nil, sizeBytes: firstBytes.count)]
            ),
            attachmentData: ["photo-a": firstBytes],
            for: firstKey
        )
        await store.flush()

        store.setDraft(.init(text: "session B text", repoPointers: []), for: secondKey)
        await store.flush()

        #expect(store.attachmentData(for: firstKey, attachmentID: "photo-a") == firstBytes)
        let reloaded = fixture.makeStore()
        await reloaded.load()
        #expect(reloaded.attachmentData(for: firstKey, attachmentID: "photo-a") == firstBytes)
    }

    @Test func photoOnlyDraftIsNonEmptyAndClearDeletesSidecars() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let key = try fixture.key()
        let store = fixture.makeStore()
        await store.load()
        let record = store.setDraft(
            .init(
                text: "",
                repoPointers: [],
                attachments: [.init(id: "photo-1", displayName: "photo.jpg", mimeType: "image/jpeg", source: .image, relativePath: nil, sizeBytes: 3)]
            ),
            attachmentData: ["photo-1": Data("jpg".utf8)],
            for: key
        )
        #expect(record != nil)
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: fixture.sidecarDirectoryURL.path))

        #expect(store.clearDraft(for: key))
        #expect(!FileManager.default.fileExists(atPath: fixture.sidecarDirectoryURL.path))
        let reloaded = fixture.makeStore()
        await reloaded.load()
        #expect(reloaded.record(for: key) == nil)
    }

    @Test func ephemeralFallbackDoesNotCreateSidecars() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: key, isEphemeral: true)
        controller.setPendingAttachments([.localFile(name: "secret.txt", data: Data("secret".utf8), mimeType: "text/plain")])
        #expect(store.record(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.sidecarDirectoryURL.path))
    }

    @Test func quickSessionTextSurvivesReloadAndClearsDurably() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let draft = "  Quick session first line\nsecond line  "

        let store = fixture.makeStore()
        await store.load()
        store.setQuickSessionDraftText(draft)
        #expect(store.quickSessionDraftText == draft)
        store.saveQuickSessionLifecycleFallback()

        let relaunchedBeforeDebouncedSave = fixture.makeStore()
        await relaunchedBeforeDebouncedSave.load()
        #expect(relaunchedBeforeDebouncedSave.quickSessionDraftText == draft)

        await store.flush()
        let reloaded = fixture.makeStore()
        await reloaded.load()
        #expect(reloaded.quickSessionDraftText == draft)

        reloaded.setQuickSessionDraftText("")
        #expect(reloaded.quickSessionDraftText.isEmpty)

        let relaunchedBeforeDebouncedClear = fixture.makeStore()
        await relaunchedBeforeDebouncedClear.load()
        #expect(relaunchedBeforeDebouncedClear.quickSessionDraftText.isEmpty)
    }

    @Test func quickSessionRevisionGuardPreservesNewerTyping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()

        let submitted = try #require(store.setQuickSessionDraftText("submitted draft"))
        let newer = try #require(store.setQuickSessionDraftText("newer draft"))

        #expect(!store.clearQuickSessionDraft(ifRevision: submitted.revision))
        #expect(store.quickSessionDraftText == "newer draft")
        #expect(store.clearQuickSessionDraft(ifRevision: newer.revision))
        #expect(store.quickSessionDraftText.isEmpty)
    }

    @Test func isolatesDraftsByServerWorkspaceAndSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()

        let first = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a"
        ))
        let otherSession = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-b"
        ))
        let otherWorkspace = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "workspace-b",
            sessionID: "session-a"
        ))
        let otherServer = try #require(ComposerDraftKey(
            serverID: "server-b",
            workspaceID: "workspace-a",
            sessionID: "session-a"
        ))

        store.setDraft(.init(text: "first", repoPointers: []), for: first)

        #expect(store.record(for: first)?.payload.text == "first")
        #expect(store.record(for: otherSession) == nil)
        #expect(store.record(for: otherWorkspace) == nil)
        #expect(store.record(for: otherServer) == nil)
    }

    @Test func exactEmptyPayloadDeletesButWhitespaceDoesNot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try #require(ComposerDraftKey(
            serverID: "server",
            workspaceID: "workspace",
            sessionID: "session"
        ))

        store.setDraft(.init(text: "   ", repoPointers: []), for: key)
        #expect(store.record(for: key)?.payload.text == "   ")

        store.setDraft(.empty, for: key)
        #expect(store.record(for: key) == nil)
    }

    @Test func synchronousClearTombstonePreventsCrashResurrection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try #require(ComposerDraftKey(
            serverID: "server",
            workspaceID: "workspace",
            sessionID: "session"
        ))
        store.setDraft(.init(text: "already sent", repoPointers: []), for: key)
        await store.flush()

        store.clearDraft(for: key)

        let relaunchedBeforeDebouncedClear = fixture.makeStore()
        await relaunchedBeforeDebouncedClear.load()
        #expect(relaunchedBeforeDebouncedClear.record(for: key) == nil)
    }

    @Test func revisionGuardDoesNotClearNewerTyping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try #require(ComposerDraftKey(
            serverID: "server",
            workspaceID: "workspace",
            sessionID: "session"
        ))

        let submitted = try #require(store.setDraft(.init(text: "send me", repoPointers: []), for: key))
        let newer = try #require(store.setDraft(.init(text: "next message", repoPointers: []), for: key))

        #expect(!store.clearDraft(for: key, ifRevision: submitted.revision))
        #expect(store.record(for: key)?.revision == newer.revision)
        #expect(store.record(for: key)?.payload.text == "next message")
        #expect(store.clearDraft(for: key, ifRevision: newer.revision))
        #expect(store.record(for: key) == nil)

        let afterClear = try #require(store.setDraft(
            .init(text: "typed after clear", repoPointers: []),
            for: key
        ))
        #expect(afterClear.revision > newer.revision)
    }

    @Test func synchronousLifecycleFallbackSurvivesBeforeDebouncedWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try #require(ComposerDraftKey(
            serverID: "server",
            workspaceID: "workspace",
            sessionID: "session"
        ))
        let payload = ComposerDraftPayload(
            text: "latest keystroke",
            repoPointers: [
                .init(
                    path: "Sources/App.swift",
                    isDirectory: false,
                    kind: .workspaceFile,
                    displayPrefix: nil
                ),
            ],
            attachments: [
                .init(
                    id: "lifecycle-file",
                    displayName: "latest.log",
                    mimeType: "text/plain",
                    source: .localFile,
                    relativePath: "draft-attachments/lifecycle-file.blob",
                    sizeBytes: 12
                ),
            ]
        )
        let record = try #require(store.setDraft(
            payload,
            attachmentData: ["lifecycle-file": Data("latest log!".utf8)],
            for: key
        ))

        store.saveLifecycleFallback(record)

        let fallbackValues = try fixture.fallbackURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(fallbackValues.isExcludedFromBackup == true)
        let relaunched = fixture.makeStore()
        await relaunched.load()
        #expect(relaunched.record(for: key)?.payload == payload)
        #expect(relaunched.attachmentData(for: key, attachmentID: "lifecycle-file") == Data("latest log!".utf8))

        relaunched.clearDraft(for: key)
        let afterClear = fixture.makeStore()
        await afterClear.load()
        #expect(afterClear.record(for: key) == nil)
    }

    @Test func synchronousFallbackPreservesQuickSessionAndChatDraftsTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let chatKey = try #require(ComposerDraftKey(
            serverID: "server",
            workspaceID: "workspace",
            sessionID: "session"
        ))

        store.setQuickSessionDraftText("quick draft")
        store.saveQuickSessionLifecycleFallback()
        let chatRecord = try #require(store.setDraft(
            .init(text: "chat draft", repoPointers: []),
            for: chatKey
        ))
        store.saveLifecycleFallback(chatRecord)

        let relaunched = fixture.makeStore()
        await relaunched.load()
        #expect(relaunched.quickSessionDraftText == "quick draft")
        #expect(relaunched.record(for: chatKey)?.payload.text == "chat draft")
    }

    @Test func recoversNewerSynchronousLifecycleBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try #require(ComposerDraftKey(
            serverID: "server",
            workspaceID: "workspace",
            sessionID: "session"
        ))
        let persisted = try #require(store.setDraft(
            .init(text: "debounced value", repoPointers: []),
            for: key
        ))
        let backup = ComposerDraftRecord(
            key: key,
            payload: .init(text: "latest lifecycle value", repoPointers: []),
            revision: persisted.revision + 1,
            updatedAt: persisted.updatedAt.addingTimeInterval(1)
        )

        store.recoverDraft(backup)

        #expect(store.record(for: key) == backup)
    }

    @Test func migratesLegacyDraftOnlyToMatchingServerAndSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let matching = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a"
        ))
        let other = try #require(ComposerDraftKey(
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-b"
        ))

        store.stageLegacyDraft(text: "old draft", serverID: "server-a", sessionID: "session-a")

        #expect(store.consumeLegacyDraft(for: other) == nil)
        #expect(store.consumeLegacyDraft(for: matching)?.text == "old draft")
        #expect(store.consumeLegacyDraft(for: matching) == nil)
    }

    @Test func corruptStorageFailsOpenWithoutCrashing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not json".utf8).write(to: fixture.fileURL, options: .atomic)

        let store = fixture.makeStore()
        await store.load()

        #expect(store.isLoaded)
        #expect(store.lastError == "Failed to load local message drafts.")
    }

    private struct Fixture {
        let rootURL: URL
        let fileURL: URL

        var fallbackURL: URL {
            rootURL.appending(path: "active-draft-fallback-v2.json", directoryHint: .notDirectory)
        }

        var sidecarDirectoryURL: URL {
            rootURL.appending(path: "draft-attachments", directoryHint: .isDirectory)
        }

        func key(sessionID: String = "session") throws -> ComposerDraftKey {
            try #require(ComposerDraftKey(serverID: "server", workspaceID: "workspace", sessionID: sessionID))
        }

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appending(path: "ComposerDraftStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            fileURL = rootURL.appending(path: "drafts.json", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        @MainActor
        func makeStore() -> ComposerDraftStore {
            ComposerDraftStore(fileURL: fileURL, saveDelay: .seconds(60))
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
