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
    }

    let path: String
    let isDirectory: Bool
    let kind: Kind
    let displayPrefix: String?
}

struct ComposerDraftPayload: Codable, Equatable, Sendable {
    var text: String
    var repoPointers: [ComposerDraftRepoPointer]

    static let empty = Self(text: "", repoPointers: [])

    var isEmpty: Bool {
        text.isEmpty && repoPointers.isEmpty
    }
}

struct ComposerDraftRecord: Codable, Equatable, Sendable {
    let key: ComposerDraftKey
    var payload: ComposerDraftPayload
    var revision: UInt64
    var updatedAt: Date
}
