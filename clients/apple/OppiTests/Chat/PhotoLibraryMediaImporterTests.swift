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
        let photoURL = try makePNG()
        let videoURL = try makeVideoFile()
        defer {
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: videoURL)
        }

        let ownedPhoto = try PendingComposerFileStore.copyFile(from: photoURL, displayName: "photo.png")
        let ownedVideo = try PendingComposerFileStore.copyFile(from: videoURL, displayName: "clip.mp4")
        let photo = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: ownedPhoto,
            kind: .image,
            displayName: "photo.png",
            mimeType: "image/png"
        )
        let video = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: ownedVideo,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4"
        )
        defer { PendingAttachment.releaseOwnedFiles([photo, video]) }

        #expect(photo.source == .image)
        #expect(photo.imageAttachment != nil)
        #expect(photo.localFileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: ownedPhoto.path))

        #expect(video.source == .localFile)
        #expect(video.imageAttachment == nil)
        #expect(video.localFileData == nil)
        #expect(video.localFileURL != nil)
        #expect(video.ownsLocalFile)
        #expect(FileManager.default.fileExists(atPath: video.localFileURL!.path))
        #expect(video.composerDraftData == nil)
    }

    @Test func videoImportCopiesProviderTempThenSurvivesSourceDeletion() throws {
        let source = try makeVideoFile()
        let owned = try PendingComposerFileStore.copyFile(from: source, displayName: "clip.mp4")
        try FileManager.default.removeItem(at: source)
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: owned,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4"
        )
        defer { PendingAttachment.releaseOwnedFiles([attachment]) }

        let ownedURL = try #require(attachment.localFileURL)
        #expect(FileManager.default.fileExists(atPath: ownedURL.path))
        #expect(attachment.localFileData == nil)
        #expect(try Data(contentsOf: ownedURL).count > 0)
    }

    @Test func removingAVideoChipDeletesTheOwnedFile() throws {
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let owned = try PendingComposerFileStore.copyFile(from: source, displayName: "clip.mp4")
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: owned,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4"
        )
        let ownedURL = try #require(attachment.localFileURL)
        #expect(FileManager.default.fileExists(atPath: ownedURL.path))

        var pending = [attachment]
        let binding = Binding(get: { pending }, set: { pending = $0 })
        ComposerShared.removeAttachment(attachment.id, from: binding)

        #expect(pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
    }

    @Test func staleImportEpochDropsVideoAndDeletesOwnedFile() throws {
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let owned = try PendingComposerFileStore.copyFile(from: source, displayName: "clip.mp4")
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: owned,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4"
        )
        let ownedURL = try #require(attachment.localFileURL)
        let gate = ComposerMediaImportGate()
        let captured = gate.epoch
        gate.invalidate()

        var pending: [PendingAttachment] = []
        if gate.isCurrent(captured) {
            pending.append(attachment)
        } else {
            PendingAttachment.releaseOwnedFiles([attachment])
        }

        #expect(pending.isEmpty)
        #expect(!gate.isCurrent(captured))
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
    }

    @Test func ownedComposerFilesUseCompleteUnlessOpenProtection() throws {
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let owned = try PendingComposerFileStore.copyFile(from: source, displayName: "clip.mp4")
        defer { PendingComposerFileStore.remove(owned) }

        #expect(try owned.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let directory = try PendingComposerFileStore.directoryURL()
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

#if !targetEnvironment(simulator)
        // The simulator does not report data-protection classes; devices do.
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: owned.path)
        #expect(fileAttributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(directoryAttributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen)
#endif
    }

    @Test func refusedComposerImportDeletesOwnedVideoAndSurfacesError() throws {
        let source = try makeVideoFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let owned = try PendingComposerFileStore.copyFile(from: source, displayName: "clip.mp4")
        let attachment = try PhotoLibraryMediaImporter.makePendingAttachment(
            fromCopiedFile: owned,
            kind: .video,
            displayName: "clip.mp4",
            mimeType: "video/mp4"
        )
        let ownedURL = try #require(attachment.localFileURL)
        let controller = ChatComposerDraftController()
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
            importError = ComposerShared.photoLibraryImportRefusedMessage
        }

        #expect(pending.isEmpty)
        #expect(controller.pendingAttachments.isEmpty)
        #expect(rejected.map(\.id) == [attachment.id])
        #expect(!FileManager.default.fileExists(atPath: ownedURL.path))
        #expect(importError == ComposerShared.photoLibraryImportRefusedMessage)
    }

    @Test func invalidImageSurfacesAnImportFailure() throws {
        let junk = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString).png",
            directoryHint: .notDirectory
        )
        try Data("not-an-image".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let owned = try PendingComposerFileStore.copyFile(from: junk, displayName: "broken.png")

        #expect(throws: PhotoLibraryMediaImporter.ImportError.invalidImage) {
            _ = try PhotoLibraryMediaImporter.makePendingAttachment(
                fromCopiedFile: owned,
                kind: .image,
                displayName: "broken.png",
                mimeType: "image/png"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: owned.path))
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
}
