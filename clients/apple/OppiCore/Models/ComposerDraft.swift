import Foundation

struct ComposerDraftKey: Codable, Hashable, Sendable {
    let serverID: String
    let workspaceID: String
    let sessionID: String

    init?(serverID: String, workspaceID: String, sessionID: String) {
        let normalizedServerID = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerID.isEmpty,
              !normalizedWorkspaceID.isEmpty,
              !normalizedSessionID.isEmpty else {
            return nil
        }

        self.serverID = normalizedServerID
        self.workspaceID = normalizedWorkspaceID
        self.sessionID = normalizedSessionID
    }
}

struct ComposerDraftRepoPointer: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case workspaceFile
        case reviewFile
        case gitCommit
    }

    let path: String
    let isDirectory: Bool
    let kind: Kind
    let displayPrefix: String?
    let commitMessage: String?

    init(
        path: String,
        isDirectory: Bool,
        kind: Kind,
        displayPrefix: String?,
        commitMessage: String? = nil
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.kind = kind
        self.displayPrefix = displayPrefix
        let trimmedMessage = commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.commitMessage = trimmedMessage?.isEmpty == false ? trimmedMessage : nil
    }
}

extension ComposerDraftRepoPointer {
    private enum CodingKeys: String, CodingKey {
        case path, isDirectory, kind, displayPrefix, commitMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let displayPrefix = try container.decodeIfPresent(String.self, forKey: .displayPrefix)
        let commitMessage = try container.decodeIfPresent(String.self, forKey: .commitMessage)
        self.init(
            path: path,
            isDirectory: isDirectory,
            kind: kind,
            displayPrefix: displayPrefix,
            commitMessage: commitMessage
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(displayPrefix, forKey: .displayPrefix)
        try container.encodeIfPresent(commitMessage, forKey: .commitMessage)
    }
}

struct ComposerDraftAttachment: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case image
        case localFile
        case uploaded
    }

    let id: String
    let displayName: String
    let mimeType: String
    let source: Source
    var relativePath: String?
    let sizeBytes: Int
    let uploadedReference: ChatAttachmentRef?

    init(
        id: String,
        displayName: String,
        mimeType: String,
        source: Source,
        relativePath: String? = nil,
        sizeBytes: Int,
        uploadedReference: ChatAttachmentRef? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.mimeType = mimeType
        self.source = source
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.uploadedReference = uploadedReference
    }
}

struct ComposerDraftPayload: Codable, Equatable, Sendable {
    var text: String
    var repoPointers: [ComposerDraftRepoPointer]
    var attachments: [ComposerDraftAttachment]

    static let empty = Self(text: "", repoPointers: [], attachments: [])

    init(
        text: String,
        repoPointers: [ComposerDraftRepoPointer],
        attachments: [ComposerDraftAttachment] = []
    ) {
        self.text = text
        self.repoPointers = repoPointers
        self.attachments = attachments
    }

    var isEmpty: Bool {
        text.isEmpty && repoPointers.isEmpty && attachments.isEmpty
    }
}

extension ComposerDraftPayload {
    private enum CodingKeys: String, CodingKey {
        case text, repoPointers, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        repoPointers = try container.decode([ComposerDraftRepoPointer].self, forKey: .repoPointers)
        attachments = try container.decodeIfPresent([ComposerDraftAttachment].self, forKey: .attachments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(repoPointers, forKey: .repoPointers)
        try container.encode(attachments, forKey: .attachments)
    }
}

struct ComposerDraftRecord: Codable, Equatable, Sendable {
    let key: ComposerDraftKey
    var payload: ComposerDraftPayload
    var revision: UInt64
    var updatedAt: Date
}
