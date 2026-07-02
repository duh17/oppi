import Foundation
import UniformTypeIdentifiers

struct MacPendingAttachment: Identifiable, Sendable, Equatable {
    let id: String
    let url: URL
    let displayName: String
    let mimeType: String
    let sizeBytes: Int

    init(
        id: String = "local:\(UUID().uuidString)",
        url: URL,
        displayName: String? = nil,
        mimeType: String? = nil,
        sizeBytes: Int? = nil
    ) throws {
        guard url.isFileURL else { throw MacPendingAttachmentError.notFileURL }
        self.id = id
        self.url = url
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmedName.isEmpty ? url.lastPathComponent : trimmedName
        self.mimeType = mimeType ?? Self.mimeType(for: url)
        self.sizeBytes = try sizeBytes ?? Self.fileSize(url: url)
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
    static func adding(urls: [URL], to existing: [MacPendingAttachment]) -> MacPendingAttachmentAddResult {
        var attachments = existing
        var seenKeys = Set(existing.map { key(for: $0.url) })
        var rejectedMessages: [String] = []

        for url in urls {
            let key = key(for: url)
            guard !seenKeys.contains(key) else { continue }

            do {
                attachments.append(try MacPendingAttachment(url: url))
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
