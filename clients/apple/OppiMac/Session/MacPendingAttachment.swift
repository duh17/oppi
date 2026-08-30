import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MacPendingAttachment: Identifiable, Sendable, Equatable {
    let id: String
    let url: URL
    let displayName: String
    let mimeType: String
    let sizeBytes: Int
    /// True when this file was written to `oppi-mac-pasted-attachments` and
    /// must be deleted on remove, successful send, or composer teardown.
    let ownsTemporaryFile: Bool

    var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    init(
        id: String = "local:\(UUID().uuidString)",
        url: URL,
        displayName: String? = nil,
        mimeType: String? = nil,
        sizeBytes: Int? = nil,
        ownsTemporaryFile: Bool = false
    ) throws {
        guard url.isFileURL else { throw MacPendingAttachmentError.notFileURL }
        self.id = id
        self.url = url
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmedName.isEmpty ? url.lastPathComponent : trimmedName
        self.mimeType = mimeType ?? Self.mimeType(for: url)
        self.sizeBytes = try sizeBytes ?? Self.fileSize(url: url)
        self.ownsTemporaryFile = ownsTemporaryFile
    }

    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    private static func fileSize(url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MacPendingAttachmentError.notRegularFile }
        guard let size = values.fileSize else { throw MacPendingAttachmentError.missingFileSize }
        return size
    }
}

enum MacPendingAttachmentError: LocalizedError, Equatable {
    case notFileURL
    case notRegularFile
    case missingFileSize

    var errorDescription: String? {
        switch self {
        case .notFileURL:
            return "Attachment must be a local file."
        case .notRegularFile:
            return "Attachment must be a regular file."
        case .missingFileSize:
            return "Could not read attachment size."
        }
    }
}

struct MacPendingAttachmentAddResult: Equatable {
    let attachments: [MacPendingAttachment]
    let rejectedMessages: [String]
}

enum MacPendingAttachmentCollector {
    static func adding(
        urls: [URL],
        to existing: [MacPendingAttachment],
        ownsTemporaryFile: Bool = false
    ) -> MacPendingAttachmentAddResult {
        var attachments = existing
        var seenKeys = Set(existing.map { key(for: $0.url) })
        var rejectedMessages: [String] = []

        for url in urls {
            let key = key(for: url)
            guard !seenKeys.contains(key) else { continue }

            do {
                attachments.append(try MacPendingAttachment(url: url, ownsTemporaryFile: ownsTemporaryFile))
                seenKeys.insert(key)
            } catch {
                rejectedMessages.append("\(displayName(for: url)): \(error.localizedDescription)")
            }
        }

        return MacPendingAttachmentAddResult(attachments: attachments, rejectedMessages: rejectedMessages)
    }

    private static func key(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private static func displayName(for url: URL) -> String {
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty { return lastPathComponent }
        return url.absoluteString
    }
}

enum MacPendingAttachmentPreview: Equatable {
    case image
    case document

    static func forAttachment(_ attachment: MacPendingAttachment) -> Self {
        attachment.isImage ? .image : .document
    }

    var systemImageFallback: String {
        switch self {
        case .image: "photo"
        case .document: "doc"
        }
    }
}

enum MacPendingAttachmentThumbnail {
    static func image(for attachment: MacPendingAttachment, maxPixelSize: CGFloat = 96) -> NSImage? {
        guard attachment.isImage else { return nil }
        return image(at: attachment.url, maxPixelSize: maxPixelSize)
    }

    static func image(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct MacComposerPasteboardImage: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let suggestedName: String
}

struct MacComposerPasteboardPayload: Equatable, Sendable {
    var fileURLs: [URL]
    var images: [MacComposerPasteboardImage]

    var hasAttachments: Bool {
        !fileURLs.isEmpty || !images.isEmpty
    }
}

enum MacComposerPasteboardParser {
    static func payload(fileURLs: [URL], images: [MacComposerPasteboardImage]) -> MacComposerPasteboardPayload {
        if !fileURLs.isEmpty {
            return MacComposerPasteboardPayload(fileURLs: fileURLs, images: [])
        }
        return MacComposerPasteboardPayload(fileURLs: [], images: images)
    }

    static func payload(from pasteboard: NSPasteboard) -> MacComposerPasteboardPayload {
        payload(fileURLs: fileURLs(from: pasteboard), images: images(from: pasteboard))
    }

    static func adding(
        _ payload: MacComposerPasteboardPayload,
        to existing: [MacPendingAttachment],
        imageWriter: (MacComposerPasteboardImage) throws -> URL = MacPastedAttachmentFileStore.writeImageFile
    ) -> MacPendingAttachmentAddResult {
        var result = MacPendingAttachmentCollector.adding(urls: payload.fileURLs, to: existing)
        var rejectedMessages = result.rejectedMessages

        for image in payload.images {
            do {
                let url = try imageWriter(image)
                let imageResult = MacPendingAttachmentCollector.adding(
                    urls: [url],
                    to: result.attachments,
                    ownsTemporaryFile: true
                )
                if imageResult.attachments.count == result.attachments.count {
                    MacPastedAttachmentFileStore.removeTemporaryFile(at: url)
                }
                result = MacPendingAttachmentAddResult(
                    attachments: imageResult.attachments,
                    rejectedMessages: rejectedMessages + imageResult.rejectedMessages
                )
                rejectedMessages = result.rejectedMessages
            } catch {
                rejectedMessages.append(
                    "\(MacPastedAttachmentFileStore.sanitizedFileName(image.suggestedName)): \(error.localizedDescription)"
                )
                result = MacPendingAttachmentAddResult(
                    attachments: result.attachments,
                    rejectedMessages: rejectedMessages
                )
            }
        }

        return result
    }

    static func string(from pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let string = item.string(forType: .string), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            let fileURLs = urls.filter(\.isFileURL)
            if !fileURLs.isEmpty { return fileURLs }
        }

        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let string = item.string(forType: .fileURL) else { return nil }
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }.filter(\.isFileURL)
    }

    private static func images(from pasteboard: NSPasteboard) -> [MacComposerPasteboardImage] {
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return [MacComposerPasteboardImage(data: png, mimeType: "image/png", suggestedName: "Pasted Image.png")]
        }
        if let tiff = pasteboard.data(forType: .tiff), let png = pngData(fromTIFF: tiff) {
            return [MacComposerPasteboardImage(data: png, mimeType: "image/png", suggestedName: "Pasted Image.png")]
        }
        if let jpeg = pasteboard.data(forType: .init("public.jpeg")), !jpeg.isEmpty {
            return [MacComposerPasteboardImage(data: jpeg, mimeType: "image/jpeg", suggestedName: "Pasted Image.jpg")]
        }
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] else {
            return []
        }
        return images.enumerated().compactMap { index, image in
            guard let data = pngData(from: image) else { return nil }
            let name = index == 0 ? "Pasted Image.png" : "Pasted Image \(index + 1).png"
            return MacComposerPasteboardImage(data: data, mimeType: "image/png", suggestedName: name)
        }
    }

    private static func pngData(fromTIFF tiff: Data) -> Data? {
        guard let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return pngData(fromTIFF: tiff)
    }
}

enum MacComposerPasteAction: Equatable, Sendable {
    case pasteTextOnly
    case stageAttachmentsOnly
    case stageAttachmentsAndPasteText

    static func resolve(hasAttachments: Bool, hasStrings: Bool) -> Self {
        switch (hasAttachments, hasStrings) {
        case (true, true): return .stageAttachmentsAndPasteText
        case (true, false): return .stageAttachmentsOnly
        case (false, _): return .pasteTextOnly
        }
    }

    var shouldStageAttachments: Bool { self != .pasteTextOnly }
    var shouldPasteText: Bool { self != .stageAttachmentsOnly }
}

struct MacComposerPastePlan: Equatable, Sendable {
    var action: MacComposerPasteAction
    var payload: MacComposerPasteboardPayload
    var textToInsert: String?
}

enum MacComposerPasteCommand {
    static func plan(from pasteboard: NSPasteboard) -> MacComposerPastePlan {
        plan(
            payload: MacComposerPasteboardParser.payload(from: pasteboard),
            string: MacComposerPasteboardParser.string(from: pasteboard)
        )
    }

    static func plan(payload: MacComposerPasteboardPayload, string: String?) -> MacComposerPastePlan {
        let hasStrings = string.map { !$0.isEmpty } ?? false
        let action = MacComposerPasteAction.resolve(
            hasAttachments: payload.hasAttachments,
            hasStrings: hasStrings
        )
        return MacComposerPastePlan(
            action: action,
            payload: payload,
            textToInsert: action.shouldPasteText ? string : nil
        )
    }
}

enum MacPastedAttachmentFileStore {
    static let directoryName = "oppi-mac-pasted-attachments"

    static func rootDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func writeImageFile(_ image: MacComposerPasteboardImage) throws -> URL {
        guard !image.data.isEmpty else {
            throw MacPendingAttachmentError.missingFileSize
        }
        let directory = rootDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(sanitizedFileName(image.suggestedName))
        try image.data.write(to: url, options: .atomic)
        return url
    }

    static func clearAll(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil
    ) {
        try? fileManager.removeItem(at: rootDirectory ?? Self.rootDirectory(fileManager: fileManager))
    }

    static func diskSize(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil
    ) -> Int64 {
        let root = rootDirectory ?? Self.rootDirectory(fileManager: fileManager)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    static func formattedDiskSize(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil
    ) -> String {
        ByteCountFormatter.string(
            fromByteCount: diskSize(fileManager: fileManager, rootDirectory: rootDirectory),
            countStyle: .file
        )
    }

    static func removeIfOwned(_ attachment: MacPendingAttachment) {
        guard attachment.ownsTemporaryFile else { return }
        removeTemporaryFile(at: attachment.url)
    }

    static func removeIfOwned(_ attachments: [MacPendingAttachment]) {
        for attachment in attachments {
            removeIfOwned(attachment)
        }
    }

    static func removeOwned(in previous: [MacPendingAttachment], notIn next: [MacPendingAttachment]) {
        let nextIDs = Set(next.map(\.id))
        removeIfOwned(previous.filter { !nextIDs.contains($0.id) })
    }

    static func removeTemporaryFile(at url: URL) {
        let directory = url.deletingLastPathComponent()
        if directory.deletingLastPathComponent().lastPathComponent == directoryName {
            try? FileManager.default.removeItem(at: directory)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func sanitizedFileName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Pasted Image.png" : name
    }
}

/// Deletes leftover pasted image files when the composer identity is released.
final class MacPastedAttachmentLifetime: @unchecked Sendable {
    var attachments: [MacPendingAttachment] = []

    func replace(with attachments: [MacPendingAttachment]) {
        self.attachments = attachments
    }

    deinit {
        MacPastedAttachmentFileStore.removeIfOwned(attachments)
    }
}

enum MacAttachmentDisplayFormatter {
    static let attachedFilesHeader = "Attached files:"

    static func appendAttachedFilesBlock(to text: String, attachments: [ChatAttachmentRef]) -> String {
        var seen = Set<String>()
        let fileLines = attachments.compactMap { attachment -> String? in
            let workspacePath = attachment.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayPath: String?
            if let workspacePath, !workspacePath.isEmpty {
                displayPath = workspacePath
            } else if !name.isEmpty {
                displayPath = name
            } else {
                displayPath = nil
            }

            guard let path = displayPath, seen.insert(path).inserted else { return nil }
            let displayName = name.isEmpty ? (path as NSString).lastPathComponent : name
            return "- \(displayName): \(path)"
        }

        guard !fileLines.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = ([attachedFilesHeader] + fileLines).joined(separator: "\n")
        guard !trimmed.isEmpty else { return block }
        return "\(trimmed)\n\n\(block)"
    }
}
