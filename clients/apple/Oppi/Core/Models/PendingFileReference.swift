import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Pending local upload attachment shown in the composer before send.
struct PendingAttachment: Identifiable, Sendable {
    enum Source: Sendable {
        case image
        case localFile
    }

    let id: String
    let source: Source
    let displayName: String
    let thumbnail: UIImage?
    let imageAttachment: ImageAttachment?
    let localFileData: Data?
    let localMimeType: String?

    static func localFile(
        name: String,
        data: Data,
        mimeType: String,
        thumbnail: UIImage? = nil
    ) -> PendingAttachment {
        PendingAttachment(
            id: "local:\(UUID().uuidString)",
            source: .localFile,
            displayName: name,
            thumbnail: thumbnail,
            imageAttachment: nil,
            localFileData: data,
            localMimeType: mimeType
        )
    }

    static func mimeType(for url: URL, contentType: UTType?) -> String {
        if let contentType {
            return contentType.preferredMIMEType ?? "application/octet-stream"
        }
        if let inferred = UTType(filenameExtension: url.pathExtension) {
            return inferred.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}

enum PendingFileReferenceKind: String, Sendable, Equatable {
    case workspaceFile
    case reviewFile

    var pathPillKind: UserMessagePathPill.Kind {
        switch self {
        case .workspaceFile:
            return .repoFile
        case .reviewFile:
            return .reviewFile
        }
    }
}

struct UserMessageAttachmentBadge: Equatable, Sendable {
    enum Kind: String, Sendable {
        case photos
        case uploadedFiles
    }

    let kind: Kind
    let count: Int

    var label: String {
        switch kind {
        case .photos:
            return count == 1 ? "1 photo" : "\(count) photos"
        case .uploadedFiles:
            return count == 1 ? "1 upload" : "\(count) uploads"
        }
    }

    var symbolName: String {
        switch kind {
        case .photos:
            return "photo"
        case .uploadedFiles:
            return "paperclip"
        }
    }
}

struct UserMessagePathPill: Equatable, Sendable {
    enum Kind: String, Sendable {
        case uploadedFile
        case reviewFile
        case repoFile
    }

    let kind: Kind
    let path: String

    var label: String {
        switch kind {
        case .uploadedFile:
            return displayPath.lastPathComponentForDisplay
        case .reviewFile, .repoFile:
            return displayPath
        }
    }

    var displayPath: String {
        switch kind {
        case .uploadedFile:
            return path.lastPathComponentForDisplay
        case .reviewFile, .repoFile:
            return path
        }
    }

    var prefix: String {
        switch kind {
        case .uploadedFile:
            return "File"
        case .reviewFile:
            return "Review"
        case .repoFile:
            return "Repo"
        }
    }

    var symbolName: String {
        switch kind {
        case .uploadedFile:
            return "paperclip"
        case .reviewFile:
            return "doc.text.magnifyingglass"
        case .repoFile:
            return "arrowshape.turn.up.right.circle"
        }
    }

    var supportsInlinePreview: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "svg" { return true }
        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .image)
        }
        return false
    }
}

enum UserMessageAttachmentPresentation {
    private static let markerPrefix = "[[oppi-attachments:"
    private static let markerSuffix = "]]"
    static let referenceBlockHeader = "Referenced workspace files:"
    static let attachedFilesHeader = "Attached files:"

    static func makeDisplayText(
        text: String,
        pendingAttachments: [PendingAttachment],
        pendingRepoPointers: [PendingFileReference],
        uploadedAttachments: [ChatAttachmentRef] = []
    ) -> String {
        let transportText = appendAttachedFilesBlock(to: text, attachments: uploadedAttachments)
        let trimmed = transportText.trimmingCharacters(in: .whitespacesAndNewlines)
        let badges = badgesForComposerState(pendingAttachments: pendingAttachments)
        let pathPills = pathPillsForComposerState(pendingRepoPointers: pendingRepoPointers)
        guard !badges.isEmpty || !pathPills.isEmpty else {
            return trimmed
        }

        let marker = encodeMarker(badges: badges, pathPills: pathPills)
        guard !trimmed.isEmpty else {
            return marker
        }
        return "\(marker)\n\(trimmed)"
    }

    static func parse(rawText: String) -> (visibleText: String, badges: [UserMessageAttachmentBadge], pathPills: [UserMessagePathPill]) {
        let content = rawText.trimmingCharacters(in: .newlines)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("", [], [])
        }

        let (withoutMarker, markerBadges, markerPathPills) = stripMarker(from: content)
        let (withoutAttachedFiles, attachedFilePills) = stripAttachedFilesBlock(from: withoutMarker)
        let (withoutReferenceBlock, referencePathPills) = stripReferenceBlock(from: withoutAttachedFiles)

        return (
            withoutReferenceBlock.trimmingCharacters(in: .whitespacesAndNewlines),
            markerBadges,
            dedupePathPills(markerPathPills + attachedFilePills + referencePathPills)
        )
    }

    static func comparableText(_ rawText: String) -> String {
        UserMessageTextProjection.comparableText(rawText)
    }

    static func makeTimelineText(
        text: String,
        uploadedAttachments: [ChatAttachmentRef]
    ) -> String {
        if UserMessageTextProjection.splitTrailingAttachedFilesBlock(from: text) != nil {
            return text
        }
        return appendAttachedFilesBlock(to: text, attachments: uploadedAttachments)
    }

    static func appendAttachedFilesBlock(to text: String, attachments: [ChatAttachmentRef]) -> String {
        var seen = Set<String>()
        let fileLines = attachments.compactMap { attachment -> String? in
            let workspacePath = attachment.workspacePath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayPath: String?
            if let workspacePath, !workspacePath.isEmpty {
                displayPath = workspacePath
            } else if !attachment.mimeType.hasPrefix("image/"), !name.isEmpty {
                // Upload refs do not know their eventual `.pi/attachments/...` path
                // until the server materializes the turn. Keep non-image uploads
                // visible by filename in optimistic/queue-start UI instead of
                // falling back to a generic "1 upload" badge.
                displayPath = name
            } else {
                displayPath = nil
            }

            guard let path = displayPath,
                  seen.insert(path).inserted else {
                return nil
            }

            let displayName = name.isEmpty ? path.lastPathComponentForDisplay : name
            return "- \(displayName): \(path)"
        }

        guard !fileLines.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = ([attachedFilesHeader] + fileLines).joined(separator: "\n")
        guard !trimmed.isEmpty else {
            return block
        }
        return "\(trimmed)\n\n\(block)"
    }

    private static func badgesForComposerState(
        pendingAttachments: [PendingAttachment]
    ) -> [UserMessageAttachmentBadge] {
        var badges: [UserMessageAttachmentBadge] = []

        let photoCount = pendingAttachments.filter { $0.source == .image }.count
        if photoCount > 0 {
            badges.append(UserMessageAttachmentBadge(kind: .photos, count: photoCount))
        }

        let uploadCount = pendingAttachments.filter { $0.source == .localFile }.count
        if uploadCount > 0 {
            badges.append(UserMessageAttachmentBadge(kind: .uploadedFiles, count: uploadCount))
        }

        return badges
    }

    private static func dedupePathPills(_ pills: [UserMessagePathPill]) -> [UserMessagePathPill] {
        var seen = Set<String>()
        return pills.filter { pill in
            seen.insert("\(pill.kind.rawValue):\(pill.path)").inserted
        }
    }

    private static func pathPillsForComposerState(
        pendingRepoPointers: [PendingFileReference]
    ) -> [UserMessagePathPill] {
        var seen = Set<String>()
        return pendingRepoPointers.compactMap { file in
            guard !file.isDirectory else { return nil }
            let trimmed = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = "\(file.kind.rawValue):\(trimmed)"
            guard seen.insert(key).inserted else { return nil }
            return UserMessagePathPill(kind: file.kind.pathPillKind, path: trimmed)
        }
    }

    private static func encodeMarker(
        badges: [UserMessageAttachmentBadge],
        pathPills: [UserMessagePathPill]
    ) -> String {
        let badgeParts: [String] = badges.map { "b:\($0.kind.rawValue)=\($0.count)" }
        let pathParts: [String] = pathPills.compactMap { pill in
            guard let encoded = pill.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                return nil
            }
            return "p:\(pill.kind.rawValue)=\(encoded)"
        }
        return markerPrefix + (badgeParts + pathParts).joined(separator: ";") + markerSuffix
    }

    private static func stripMarker(from text: String) -> (String, [UserMessageAttachmentBadge], [UserMessagePathPill]) {
        guard let firstLineEnd = text.firstIndex(of: "\n") else {
            let (badges, pathPills) = parseMarker(line: text)
            return badges.isEmpty && pathPills.isEmpty ? (text, [], []) : ("", badges, pathPills)
        }

        let firstLine = String(text[..<firstLineEnd])
        let (badges, pathPills) = parseMarker(line: firstLine)
        guard !badges.isEmpty || !pathPills.isEmpty else {
            return (text, [], [])
        }

        let remainder = String(text[text.index(after: firstLineEnd)...])
        return (remainder, badges, pathPills)
    }

    private static func parseMarker(line: String) -> ([UserMessageAttachmentBadge], [UserMessagePathPill]) {
        guard line.hasPrefix(markerPrefix), line.hasSuffix(markerSuffix) else {
            return ([], [])
        }

        let payloadStart = line.index(line.startIndex, offsetBy: markerPrefix.count)
        let payloadEnd = line.index(line.endIndex, offsetBy: -markerSuffix.count)
        let payload = line[payloadStart..<payloadEnd]

        var badges: [UserMessageAttachmentBadge] = []
        var pathPills: [UserMessagePathPill] = []
        for pair in payload.split(separator: ";") {
            if pair.hasPrefix("b:") {
                let body = pair.dropFirst(2)
                let pieces = body.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2,
                      let kind = UserMessageAttachmentBadge.Kind(rawValue: String(pieces[0])),
                      let count = Int(pieces[1]),
                      count > 0 else {
                    continue
                }
                badges.append(UserMessageAttachmentBadge(kind: kind, count: count))
            } else if pair.hasPrefix("p:") {
                let body = pair.dropFirst(2)
                let pieces = body.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2,
                      let kind = UserMessagePathPill.Kind(rawValue: String(pieces[0])),
                      let decoded = String(pieces[1]).removingPercentEncoding,
                      !decoded.isEmpty else {
                    continue
                }
                pathPills.append(UserMessagePathPill(kind: kind, path: decoded))
            }
        }

        return (badges, pathPills)
    }

    private static func stripAttachedFilesBlock(from text: String) -> (String, [UserMessagePathPill]) {
        guard let block = UserMessageTextProjection.splitTrailingAttachedFilesBlock(from: text) else {
            return (text, [])
        }

        let pathPills = block.bodyLines.compactMap { line -> UserMessagePathPill? in
            guard let path = UserMessageTextProjection.attachedFilePath(from: line) else {
                return nil
            }
            return UserMessagePathPill(kind: .uploadedFile, path: path)
        }
        return (block.visibleText, pathPills)
    }

    private static func stripReferenceBlock(from text: String) -> (String, [UserMessagePathPill]) {
        guard let block = UserMessageTextProjection.splitTrailingReferenceBlock(from: text) else {
            return (text, [])
        }

        let pathPills = block.bodyLines.map { line in
            UserMessagePathPill(
                kind: .repoFile,
                path: String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (block.visibleText, pathPills)
    }
}

/// A repo file pointer queued for sending alongside a message.
///
/// Created when the user selects a workspace file from `@` autocomplete or
/// launches a review/code flow. These are not uploads and not attachments.
/// They stay as in-repo path pointers and are appended to the prompt as
/// workspace path strings.
struct PendingFileReference: Identifiable, Sendable, Equatable {
    let path: String
    let isDirectory: Bool
    let kind: PendingFileReferenceKind
    let displayPrefix: String?

    init(
        path: String,
        isDirectory: Bool,
        kind: PendingFileReferenceKind = .workspaceFile,
        displayPrefix: String? = nil
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.kind = kind
        let trimmedPrefix = displayPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayPrefix = trimmedPrefix?.isEmpty == false ? trimmedPrefix : nil
    }

    var id: String { path }

    var displayName: String {
        let normalized = isDirectory && path.hasSuffix("/") ? String(path.dropLast()) : path
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    static func appendReferenceBlock(to text: String, files: [PendingFileReference]) -> String {
        var seen = Set<String>()
        let uniquePaths = files.compactMap { file -> String? in
            let trimmed = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        guard !uniquePaths.isEmpty else { return text }

        let block = ([UserMessageAttachmentPresentation.referenceBlockHeader] + uniquePaths.map { "- \($0)" })
            .joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return block
        }
        return "\(trimmed)\n\n\(block)"
    }
}
