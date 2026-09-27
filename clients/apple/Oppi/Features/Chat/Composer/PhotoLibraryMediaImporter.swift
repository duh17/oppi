import Foundation
import UniformTypeIdentifiers
import UIKit

/// Loads Photo Library picks as composer attachments.
///
/// Photos stay in-memory `PendingImage` values so annotate still works.
/// Videos stay file-backed: the provider temp file is copied before the
/// `loadFileRepresentation` callback returns, and the clip is never read
/// into `Data` for pending/upload/draft.
@MainActor
enum PhotoLibraryMediaImporter {
    enum Kind: Equatable, Sendable {
        case image
        case video
    }

    enum ImportError: LocalizedError, Equatable {
        case unsupportedType
        case missingFile
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .unsupportedType:
                return "That item isn't a photo or video Oppi can attach."
            case .missingFile:
                return "Photo Library did not provide a file for that item."
            case .invalidImage:
                return "Couldn't read that photo."
            }
        }
    }

    struct ImportResult: Sendable {
        var attachments: [PendingAttachment]
        var failures: [String]

        var failureMessage: String? {
            guard !failures.isEmpty else { return nil }
            if failures.count == 1 {
                return failures[0]
            }
            return "Couldn't attach \(failures.count) items from Photo Library."
        }
    }

    /// Live Photos keep the still. Movies without an image representation
    /// become file-backed video attachments.
    static func kind(for provider: NSItemProvider) -> Kind? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return .image
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.audiovisualContent.identifier) {
            return .video
        }
        return nil
    }

    static func typeIdentifier(for kind: Kind, provider: NSItemProvider) -> String {
        switch kind {
        case .image:
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return UTType.image.identifier
            }
            return provider.registeredTypeIdentifiers.first ?? UTType.image.identifier
        case .video:
            let preferred: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
            for type in preferred where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                return type.identifier
            }
            return UTType.movie.identifier
        }
    }

    static func displayName(
        for provider: NSItemProvider,
        fallbackURL: URL,
        typeIdentifier: String
    ) -> String {
        if let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            if suggested.contains(".") {
                return suggested
            }
            if let ext = UTType(typeIdentifier)?.preferredFilenameExtension, !ext.isEmpty {
                return "\(suggested).\(ext)"
            }
            return suggested
        }
        return fallbackURL.lastPathComponent
    }

    static func mimeType(for url: URL, typeIdentifier: String) -> String {
        if let mime = UTType(typeIdentifier)?.preferredMIMEType {
            return mime
        }
        return PendingAttachment.mimeType(for: url, contentType: UTType(filenameExtension: url.pathExtension))
    }

    /// Build a pending attachment from an already-owned copy of a picker file.
    static func makePendingAttachment(
        fromCopiedFile url: URL,
        kind: Kind,
        displayName: String,
        mimeType: String
    ) throws -> PendingAttachment {
        switch kind {
        case .image:
            let data = try Data(contentsOf: url)
            PendingComposerFileStore.remove(url)
            guard let image = UIImage(data: data) else {
                throw ImportError.invalidImage
            }
            return PendingImage.from(data: data, mimeType: mimeType, image: image).pendingAttachment
        case .video:
            let sizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return PendingAttachment.localFile(
                name: displayName,
                fileURL: url,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                ownsFile: true
            )
        }
    }

    static func importProviders(_ providers: [NSItemProvider]) async -> ImportResult {
        var attachments: [PendingAttachment] = []
        var failures: [String] = []
        for provider in providers {
            do {
                attachments.append(try await importProvider(provider))
            } catch {
                let name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let name, !name.isEmpty {
                    failures.append("Couldn't attach \(name).")
                } else {
                    failures.append(error.localizedDescription)
                }
            }
        }
        return ImportResult(attachments: attachments, failures: failures)
    }

    static func importProvider(_ provider: NSItemProvider) async throws -> PendingAttachment {
        guard let kind = kind(for: provider) else {
            throw ImportError.unsupportedType
        }
        let typeIdentifier = typeIdentifier(for: kind, provider: provider)
        let ownedURL = try await copyFileRepresentation(
            provider: provider,
            typeIdentifier: typeIdentifier
        )
        let displayName = displayName(
            for: provider,
            fallbackURL: ownedURL,
            typeIdentifier: typeIdentifier
        )
        let mime = mimeType(for: ownedURL, typeIdentifier: typeIdentifier)
        do {
            return try makePendingAttachment(
                fromCopiedFile: ownedURL,
                kind: kind,
                displayName: displayName,
                mimeType: mime
            )
        } catch {
            PendingComposerFileStore.remove(ownedURL)
            throw error
        }
    }

    /// Copies the provider temp file before the callback returns. The returned
    /// URL is in `PendingComposerFileStore` and no longer depends on Photos.
    static func copyFileRepresentation(
        provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let temporaryURL else {
                    continuation.resume(throwing: ImportError.missingFile)
                    return
                }
                let displayName = suggestedName.map { name in
                    name.contains(".") ? name : name + defaultExtension(for: typeIdentifier)
                } ?? temporaryURL.lastPathComponent
                do {
                    let owned = try PendingComposerFileStore.copyFile(
                        from: temporaryURL,
                        displayName: displayName
                    )
                    continuation.resume(returning: owned)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func defaultExtension(for typeIdentifier: String) -> String {
        guard let preferred = UTType(typeIdentifier)?.preferredFilenameExtension, !preferred.isEmpty else {
            return ""
        }
        return ".\(preferred)"
    }
}
