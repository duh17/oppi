import Foundation
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Oppi

@Suite("Photo library media importer")
@MainActor
struct PhotoLibraryMediaImporterTests {
    @Test func pickerConfigurationAllowsPhotosAndVideosWithoutTranscoding() {
        let configuration = PhotoLibraryPicker.makeConfiguration(selectionLimit: 10)
        #expect(configuration.selectionLimit == 10)
        #expect(configuration.preferredAssetRepresentationMode == .current)
    }

    @Test func livePhotosPreferStillImageOverMovie() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.movie.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }

        #expect(PhotoLibraryMediaImporter.kind(for: provider) == .image)
    }

    @Test func movieOnlyProvidersAreVideos() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.mpeg4Movie.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }

        #expect(PhotoLibraryMediaImporter.kind(for: provider) == .video)
    }

    @Test func mpeg4ProvidersUseMpeg4TypeIdentifierNotGenericMovie() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.mpeg4Movie.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }

        #expect(PhotoLibraryMediaImporter.kind(for: provider) == .video)
        #expect(
            PhotoLibraryMediaImporter.typeIdentifier(for: .video, provider: provider)
                == UTType.mpeg4Movie.identifier
        )
        #expect(UTType.mpeg4Movie.identifier != UTType.movie.identifier)
    }

    @Test func genericMovieTypeGetsVideoMimeAndFilenameExtension() {
        let url = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .notDirectory
        )
        let provider = NSItemProvider()
        provider.suggestedName = "Vacation"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.movie.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }

        let typeIdentifier = PhotoLibraryMediaImporter.typeIdentifier(for: .video, provider: provider)
        let mime = PhotoLibraryMediaImporter.mimeType(for: url, typeIdentifier: typeIdentifier)
        #expect(mime.hasPrefix("video/"))
        #expect(mime != "application/octet-stream")
        #expect(
            PhotoLibraryMediaImporter.displayName(
                for: provider,
                fallbackURL: url,
                typeIdentifier: typeIdentifier
            ) == "Vacation.mp4"
        )
        #expect(
            PhotoLibraryMediaImporter.displayName(
                forSuggestedName: nil,
                fallbackURL: url,
                typeIdentifier: typeIdentifier
            ) == "\(url.lastPathComponent).mp4"
        )
    }

    @Test func mixedSelectionCreatesAnnotatablePhotoAndFileBackedVideo() throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let photoURL = try makePNG()
        let videoURL = try makeVideoFile()
        defer {
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: videoURL)
        }

        let copiedPhoto = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).png",
            directoryHint: .notDirectory
        )
        try FileManager.default.copyItem(at: photoURL, to: copiedPhoto)
        let importedVideo = try store.importAttachmentFile(from: videoURL)
        let photo = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: copiedPhoto,
            kind: .image,
            displayName: "photo.png",
            mimeType: "image/png",
            store: store
        )
        let video = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: importedVideo,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4",
            store: store
        )

        #expect(photo.source == .image)
        #expect(photo.imageAttachment != nil)
        #expect(photo.localFileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: copiedPhoto.path))

        #expect(video.source == .localFile)
        #expect(video.imageAttachment == nil)
        #expect(video.localFileData == nil)
        #expect(video.localFileURL?.standardizedFileURL == importedVideo.standardizedFileURL)
        #expect(store.isImportedAttachmentFile(importedVideo))
        #expect(FileManager.default.fileExists(atPath: importedVideo.path))
        #expect(video.composerDraftData == nil)
    }

    @Test func videoImportCopiesProviderTempThenSurvivesSourceDeletion() throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = try makeVideoFile()
        let imported = try store.importAttachmentFile(from: source)
        try FileManager.default.removeItem(at: source)
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: imported,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4",
            store: store
        )

        let draftURL = try #require(attachment.localFileURL)
        #expect(draftURL.standardizedFileURL == imported.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: draftURL.path))
        #expect(attachment.localFileData == nil)
        #expect(try Data(contentsOf: draftURL).count > 0)
    }

    @Test func removingAVideoChipDeletesTheDraftFileViaStore() throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try store.importAttachmentFile(from: source)
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: imported,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4",
            store: store
        )
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: try fixture.key(), isEphemeral: false)
        #expect(controller.setPendingAttachments([attachment]))
        #expect(FileManager.default.fileExists(atPath: imported.path))

        #expect(controller.setPendingAttachments([]))
        #expect(!FileManager.default.fileExists(atPath: imported.path))
    }

    @Test func staleImportEpochDropsVideoAndDeletesDraftFile() throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try store.importAttachmentFile(from: source)
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: imported,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4",
            store: store
        )
        let gate = ComposerMediaImportGate()
        let captured = gate.epoch
        gate.invalidate()

        var pending: [PendingAttachment] = []
        var importError: String?
        if gate.isCurrent(captured) {
            pending.append(attachment)
        } else {
            PhotoLibraryMediaImporter.discardImportedFiles([attachment], store: store)
            importError = ComposerShared.photoLibraryImportRefusedMessage
        }

        #expect(pending.isEmpty)
        #expect(!gate.isCurrent(captured))
        #expect(!FileManager.default.fileExists(atPath: imported.path))
        #expect(importError == ComposerShared.photoLibraryImportRefusedMessage)
    }

    @Test func importedDraftVideosUseCompleteUnlessOpenProtection() throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try store.importAttachmentFile(from: source)
        defer { store.deleteImportedAttachmentFile(imported) }

        #expect(try imported.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(store.isImportedAttachmentFile(imported))

#if !targetEnvironment(simulator)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: imported.path)
        #expect(fileAttributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen)
#endif
    }

    @Test func refusedComposerImportDeletesDraftVideoAndSurfacesError() throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try store.importAttachmentFile(from: source)
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: imported,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4",
            store: store
        )
        let controller = ChatComposerDraftController()
        controller.attach(store: store, key: try fixture.key(), isEphemeral: false)
        controller.setMode(.ask)
        var pending: [PendingAttachment] = []
        var importError: String?
        let binding = Binding(
            get: { pending },
            set: { newValue in
                guard let accepted = ChatView.applyPendingAttachments(
                    newValue,
                    draftController: controller,
                    current: pending
                ) else { return }
                pending = accepted
            }
        )

        let rejected = ComposerShared.commitImportedAttachments([attachment], into: binding)
        if !rejected.isEmpty {
            PhotoLibraryMediaImporter.discardImportedFiles(rejected, store: store)
            importError = ComposerShared.photoLibraryImportRefusedMessage
        }

        #expect(pending.isEmpty)
        #expect(controller.pendingAttachments.isEmpty)
        #expect(rejected.map(\.id) == [attachment.id])
        #expect(!FileManager.default.fileExists(atPath: imported.path))
        #expect(importError == ComposerShared.photoLibraryImportRefusedMessage)
    }

    @Test func shouldAcceptFalseDeletesDraftVideoAndReportsError() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try store.importAttachmentFile(from: source)
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: imported,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4",
            store: store
        )
        var pending: [PendingAttachment] = []
        var importError: String?
        let binding = Binding(get: { pending }, set: { pending = $0 })
        let result = PhotoLibraryMediaImporter.ImportResult(attachments: [attachment], failures: [])

        let shouldAccept = false
        if !shouldAccept {
            PhotoLibraryMediaImporter.discardImportedFiles(result.attachments, store: store)
            importError = ComposerShared.photoLibraryImportRefusedMessage
        } else {
            _ = ComposerShared.commitImportedAttachments(result.attachments, into: binding)
        }

        #expect(pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: imported.path))
        #expect(importError == ComposerShared.photoLibraryImportRefusedMessage)
    }

    @Test func invalidImageSurfacesAnImportFailure() throws {
        let junk = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).png",
            directoryHint: .notDirectory
        )
        try Data("not-an-image".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let copied = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString)-broken.png",
            directoryHint: .notDirectory
        )
        try FileManager.default.copyItem(at: junk, to: copied)

        #expect(throws: PhotoLibraryMediaImporter.ImportError.invalidImage) {
            _ = try PhotoLibraryMediaImporter.makePendingAttachment(
                fromCopiedFile: copied,
                kind: .image,
                displayName: "broken.png",
                mimeType: "image/png"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: copied.path))
    }

    private func makePNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).png",
            directoryHint: .notDirectory
        )
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let data = try #require(image.pngData())
        try data.write(to: url)
        return url
    }

    private func makeVideoFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).mp4",
            directoryHint: .notDirectory
        )
        try Data(repeating: 0x01, count: 256).write(to: url)
        return url
    }

    private struct DraftFixture {
        let rootURL: URL
        let fileURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appending(path: "PhotoLibraryMediaImporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            fileURL = rootURL.appending(path: "drafts.json", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        @MainActor
        func makeStore() -> ComposerDraftStore {
            ComposerDraftStore(fileURL: fileURL, saveDelay: .seconds(60))
        }

        func key() throws -> ComposerDraftKey {
            try #require(ComposerDraftKey(serverID: "server", workspaceID: "workspace", sessionID: "session"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
