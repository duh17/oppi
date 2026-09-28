import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("ChatView sendPrompt file-backed drafts")
@MainActor
struct ChatViewComposerPromptSendTests {
    @Test func reopenInlineUploadFailureReopenRetryUsesCanonicalDraftFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, videoBytes, draftURL) = try fixture.makeImportedVideo(store: store)

        var controller: ChatComposerDraftController? = ChatComposerDraftController(
            initialText: "watch this",
            initialPendingAttachments: [video]
        )
        controller?.attach(store: store, key: key, isEphemeral: false)
        await store.flush()
        controller = nil

        let afterReopen = ChatComposerDraftController()
        afterReopen.attach(store: store, key: key, isEphemeral: false)
        let reopenedURL = try #require(afterReopen.pendingAttachments.first?.localFileURL)
        #expect(reopenedURL.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(afterReopen.pendingAttachments.first?.localFileData == nil)
        #expect(try Data(contentsOf: reopenedURL) == videoBytes)

        let (failed, _) = await ChatView.sendPrompt(
            draftController: afterReopen,
            state: ChatView.ComposerPromptSendState(
                pendingAttachments: afterReopen.pendingAttachments,
                isPreparingAttachments: false
            ),
            draftClearance: .afterSuccess,
            actionIsSending: false,
            upload: { attachments in
                #expect(attachments.count == 1)
                #expect(attachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
                #expect(attachments.first?.localFileData == nil)
                throw APIError.server(status: 503, message: "upload failed")
            }
        )
        guard case .failed = failed else {
            Issue.record("expected upload failure, got \(String(describing: failed))")
            return
        }
        #expect(afterReopen.text == "watch this")
        #expect(afterReopen.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: draftURL.path))
        #expect(store.attachmentFileURL(for: key, attachmentID: video.id)?.standardizedFileURL == draftURL.standardizedFileURL)

        let afterFailureReopen = ChatComposerDraftController()
        afterFailureReopen.attach(store: store, key: key, isEphemeral: false)
        let retryURL = try #require(afterFailureReopen.pendingAttachments.first?.localFileURL)
        #expect(retryURL.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(try Data(contentsOf: retryURL) == videoBytes)

        let (succeeded, _) = await ChatView.sendPrompt(
            draftController: afterFailureReopen,
            state: ChatView.ComposerPromptSendState(
                pendingAttachments: afterFailureReopen.pendingAttachments,
                isPreparingAttachments: false
            ),
            draftClearance: .afterSuccess,
            actionIsSending: false,
            upload: { attachments in
                #expect(attachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
                #expect(attachments.first?.localFileData == nil)
                return [Self.uploadedVideoRef]
            }
        )
        guard case .uploaded(let submission, let attachments, let source) = succeeded else {
            Issue.record("expected upload success, got \(String(describing: succeeded))")
            return
        }
        #expect(attachments.map(\.id) == ["upload-video"])
        #expect(source.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(afterFailureReopen.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)

        let didClear = afterFailureReopen.completeSubmission(submission)
        #expect(didClear)
        #expect(afterFailureReopen.pendingAttachments.isEmpty)
        #expect(store.record(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
    }

    @Test func expandedSendUsesAfterSuccessAndTheSameCanonicalDraftFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.load()
        let key = try fixture.key()
        let (video, _, draftURL) = try fixture.makeImportedVideo(store: store)
        let controller = ChatComposerDraftController(
            initialText: "expanded clip",
            initialPendingAttachments: [video]
        )
        controller.attach(store: store, key: key, isEphemeral: false)

        let (outcome, _) = await ChatView.sendPrompt(
            draftController: controller,
            state: ChatView.ComposerPromptSendState(
                pendingAttachments: controller.pendingAttachments,
                isPreparingAttachments: false
            ),
            draftClearance: .afterSuccess,
            actionIsSending: false,
            upload: { attachments in
                #expect(attachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
                return [Self.uploadedVideoRef]
            }
        )
        guard case .uploaded(let submission, _, _) = outcome else {
            Issue.record("expected expanded upload success, got \(String(describing: outcome))")
            return
        }
        #expect(controller.pendingAttachments.first?.localFileURL?.standardizedFileURL == draftURL.standardizedFileURL)
        #expect(controller.text == "expanded clip")
        #expect(!controller.setPendingAttachments([]))

        let didClear = controller.completeSubmission(submission)
        #expect(didClear)
        #expect(controller.pendingAttachments.isEmpty)
        #expect(store.record(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
    }

    @Test func refusedImportCleansDestinationAndReportsError() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let (video, _, draftURL) = try fixture.makeImportedVideo(store: store)
        var pending: [PendingAttachment] = []
        var importError: String?
        let binding = Binding(get: { pending }, set: { pending = $0 })

        ComposerShared.finishPhotoLibraryImport(
            .init(attachments: [video], failures: []),
            into: binding,
            store: store,
            shouldAccept: { false },
            onFailure: { importError = $0 }
        )

        #expect(pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
        #expect(importError == ComposerShared.photoLibraryImportRefusedMessage)
    }

    @Test func bothComposerPresentationsClearAfterSuccess() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Oppi/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("onSend: { sendComposerAction(draftClearance: .afterSuccess) }"))
        #expect(!source.contains("onSend: { sendComposerAction() }"))
        #expect(source.contains("draftClearance: ChatComposerDraftController.SubmissionDraftClearance = .afterSuccess"))
    }

    private static let uploadedVideoRef = ChatAttachmentRef(
        type: "attachment",
        id: "upload-video",
        source: .upload,
        name: "clip.mp4",
        mimeType: "video/mp4",
        sizeBytes: 256,
        sha256: nil,
        kind: .video,
        workspacePath: ".pi/attachments/session/clip.mp4"
    )

    private struct Fixture {
        let rootURL: URL
        let fileURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appending(path: "ChatViewComposerPromptSendTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            fileURL = rootURL.appending(path: "drafts.json", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        @MainActor
        func makeStore() -> ComposerDraftStore {
            ComposerDraftStore(fileURL: fileURL, saveDelay: .seconds(60))
        }

        func key() throws -> ComposerDraftKey {
            try #require(ComposerDraftKey(
                serverID: "server",
                workspaceID: "workspace",
                sessionID: "session"
            ))
        }

        @MainActor
        func makeImportedVideo(
            store: ComposerDraftStore
        ) throws -> (PendingAttachment, Data, URL) {
            let source = FileManager.default.temporaryDirectory.appending(
                path: "\(UUID().uuidString).mp4",
                directoryHint: .notDirectory
            )
            let videoBytes = Data(repeating: 0x61, count: 256)
            try videoBytes.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let draftURL = try store.importAttachmentFile(from: source)
            let video = PendingAttachment.localFile(
                name: "clip.mp4",
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
