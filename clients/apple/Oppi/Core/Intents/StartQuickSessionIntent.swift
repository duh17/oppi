import AppIntents
import Foundation
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "StartQuickSessionIntent")

enum QuickSessionIntentPayloadError: LocalizedError, Equatable {
    case unsupportedImage
    case emptyImage
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "The supplied file is not a supported image."
        case .emptyImage:
            return "The supplied image is empty."
        case .imageTooLarge:
            return "The supplied image exceeds Oppi's image upload limit."
        }
    }
}

/// App Intent that opens Oppi and presents the Quick Session sheet.
///
/// Triggered from:
/// - Action Button (via ControlWidget assignment)
/// - Control Center (via ControlWidget)
/// - Lock Screen (via ControlWidget)
/// - Spotlight search
/// - Siri voice command
/// - Shortcuts app
struct StartQuickSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    // periphery:ignore
    static let description: IntentDescription = "Start a new Oppi agent session"
    static var supportedModes: IntentModes { .foreground(.immediate) }
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif

    @Parameter(title: "Text", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String?

    @Parameter(
        title: "Image",
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var image: IntentFile?

    func perform() async throws -> some IntentResult {
        let initialPayload = try await QuickSessionIntentPayloadBuilder.initialPayload(
            text: text,
            image: image
        )
        await QuickSessionTrigger.shared.requestPresentation(initialPayload: initialPayload)
        return .result()
    }
}

private enum QuickSessionIntentPayloadBuilder {
    static func initialPayload(
        text: String?,
        image: IntentFile?
    ) async throws -> QuickSessionInitialPayload? {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        var attachments: [QuickSessionInitialPayload.Attachment] = []

        if let image {
            attachments.append(try await attachment(from: image))
        }

        guard trimmedText?.isEmpty == false || !attachments.isEmpty else {
            return nil
        }

        return QuickSessionInitialPayload(
            text: trimmedText?.isEmpty == false ? trimmedText : nil,
            attachments: attachments
        )
    }

    private static func attachment(
        from file: IntentFile
    ) async throws -> QuickSessionInitialPayload.Attachment {
        guard let contentType = preferredImageType(for: file) else {
            logger.warning("Shortcut supplied a file without an image representation")
            throw QuickSessionIntentPayloadError.unsupportedImage
        }

        let data: Data
        do {
            let representation = try await file.file(contentType: contentType)
            let accessedSecurityScopedResource = representation.fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScopedResource {
                    representation.fileURL.stopAccessingSecurityScopedResource()
                }
            }
            data = try readImageData(at: representation.fileURL)
        } catch {
            logger.error("Failed to load Shortcut image: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard !data.isEmpty else {
            logger.warning("Shortcut supplied an empty image file")
            throw QuickSessionIntentPayloadError.emptyImage
        }

        return QuickSessionInitialPayload.Attachment(
            name: filename(for: file, contentType: contentType),
            data: data,
            mimeType: contentType.preferredMIMEType ?? "application/octet-stream"
        )
    }

    private static func readImageData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        while data.count <= PendingImage.autoResizeMaxDataBytes {
            let remaining = PendingImage.autoResizeMaxDataBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1_024)),
                  !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
        }

        throw QuickSessionIntentPayloadError.imageTooLarge
    }

    private static func preferredImageType(for file: IntentFile) -> UTType? {
        if let type = file.type, type.conforms(to: .image) {
            return type
        }

        let fileExtension = URL(fileURLWithPath: file.filename).pathExtension
        if let filenameType = UTType(filenameExtension: fileExtension),
           filenameType.conforms(to: .image),
           file.availableContentTypes.contains(where: { $0 == filenameType }) {
            return filenameType
        }

        return file.availableContentTypes.first(where: { $0.conforms(to: .image) })
    }

    private static func filename(for file: IntentFile, contentType: UTType) -> String {
        let trimmed = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = trimmed.isEmpty ? "Shortcut Image" : URL(fileURLWithPath: trimmed).lastPathComponent
        let originalExtension = URL(fileURLWithPath: originalName).pathExtension

        if let originalType = UTType(filenameExtension: originalExtension),
           originalType.conforms(to: .image) {
            let matchesContentType = originalType == contentType
                || originalType.conforms(to: contentType)
                || contentType.conforms(to: originalType)
            if matchesContentType {
                return originalName
            }
        }

        let stem = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        guard let pathExtension = contentType.preferredFilenameExtension else {
            return stem
        }
        return "\(stem).\(pathExtension)"
    }
}
