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
            for identifier in provider.registeredTypeIdentifiers {
                guard let type = UTType(identifier),
                      let mime = type.preferredMIMEType?.lowercased(),
                      mime.hasPrefix("video/") else {
                    continue
                }
                return identifier
            }
            let preferred: [UTType] = [.mpeg4Movie, .quickTimeMovie, .video, .movie, .audiovisualContent]
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
        displayName(
            forSuggestedName: provider.suggestedName,
            fallbackURL: fallbackURL,
            typeIdentifier: typeIdentifier
        )
    }

    static func mimeType(for url: URL, typeIdentifier: String) -> String {
        if let mime = UTType(typeIdentifier)?.preferredMIMEType, !mime.isEmpty {
            return mime
        }
        let inferred = PendingAttachment.mimeType(
            for: url,
            contentType: UTType(filenameExtension: url.pathExtension)
        )
        if inferred != "application/octet-stream" {
            return inferred
        }
        if let type = UTType(typeIdentifier), type.conforms(to: .audiovisualContent) {
            return "video/mp4"
        }
        return inferred
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
                let displayName = Self.displayName(
                    forSuggestedName: suggestedName,
                    fallbackURL: temporaryURL,
                    typeIdentifier: typeIdentifier
                )
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

    static func displayName(
        forSuggestedName suggestedName: String?,
        fallbackURL: URL,
        typeIdentifier: String
    ) -> String {
        let trimmed = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if let trimmed, !trimmed.isEmpty {
            raw = trimmed
        } else {
            raw = fallbackURL.lastPathComponent
        }
        if raw.contains(".") {
            return raw
        }
        let ext = filenameExtension(for: typeIdentifier)
        return ext.isEmpty ? raw : "\(raw).\(ext)"
    }

    private static func filenameExtension(for typeIdentifier: String) -> String {
        if let preferred = UTType(typeIdentifier)?.preferredFilenameExtension, !preferred.isEmpty {
            return preferred
        }
        if let type = UTType(typeIdentifier), type.conforms(to: .audiovisualContent) {
            return "mp4"
        }
        return ""
    }
}
