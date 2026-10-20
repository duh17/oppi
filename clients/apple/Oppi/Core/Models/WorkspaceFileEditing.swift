import CryptoKit
import Foundation

/// One editable file: server + owner + owner-relative path. A workspace file
/// names its checkout (a nil worktree means main; a set worktree never falls
/// back to main). A Skill file is one of an editable Skill's own files. No other
/// origin (host, session) is editable.
struct WorkspaceFileEditIdentity: Hashable, Sendable {
    /// The `/files/current` origin that reads and writes the file.
    enum Owner: Hashable, Sendable {
        /// `origin=workspace`.
        case workspace(id: String, worktreeId: String?)
        /// `origin=skill`.
        case skill(id: String)
    }

    let serverId: String
    let owner: Owner
    /// Workspace- or Skill-relative path.
    let path: String

    init(serverId: String, workspaceId: String, worktreeId: String?, path: String) {
        self.serverId = serverId
        let trimmed = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.owner = .workspace(id: workspaceId, worktreeId: trimmed.isEmpty ? nil : trimmed)
        self.path = path
    }

    init(serverId: String, skillId: String, path: String) {
        self.serverId = serverId
        self.owner = .skill(id: skillId)
        self.path = path
    }

    /// Stable file-name key for protected draft storage.
    var storageKey: String {
        let parts: [String] = switch owner {
        // The workspace key predates Skill files; changing it would strand drafts.
        case .workspace(let workspaceId, let worktreeId): ["v1", serverId, workspaceId, worktreeId ?? "", path]
        case .skill(let skillId): ["skill-v1", serverId, skillId, path]
        }
        let raw = parts.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Flat keys, so drafts stored before Skill files decode as workspace files.
extension WorkspaceFileEditIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case serverId, workspaceId, worktreeId, skillId, path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serverId = try container.decode(String.self, forKey: .serverId)
        let path = try container.decode(String.self, forKey: .path)
        if let skillId = try container.decodeIfPresent(String.self, forKey: .skillId) {
            self.init(serverId: serverId, skillId: skillId, path: path)
        } else {
            self.init(
                serverId: serverId,
                workspaceId: try container.decode(String.self, forKey: .workspaceId),
                worktreeId: try container.decodeIfPresent(String.self, forKey: .worktreeId),
                path: path
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(path, forKey: .path)
        switch owner {
        case .workspace(let workspaceId, let worktreeId):
            try container.encode(workspaceId, forKey: .workspaceId)
            try container.encodeIfPresent(worktreeId, forKey: .worktreeId)
        case .skill(let skillId):
            try container.encode(skillId, forKey: .skillId)
        }
    }
}

/// Bytes of one `GET /files/current?origin=workspace` and the strong ETag from the
/// same response. A nil tag means the server did not offer the file for editing.
struct WorkspaceFileDiskSnapshot: Sendable, Equatable {
    let bytes: Data
    let etag: String?
}

enum WorkspaceFileReadOutcome: Sendable, Equatable {
    case snapshot(WorkspaceFileDiskSnapshot)
    /// 404: deleted, unknown worktree, or no longer an eligible file.
    case missing
    /// Transport or unexpected server failure. Nothing is known about disk.
    case failed
}

/// Typed result of `PUT /files/current?origin=workspace`.
enum WorkspaceFileWriteOutcome: Sendable, Equatable {
    case saved(etag: String)
    /// 412: the disk tag no longer matches `If-Match`. Disk was not changed.
    case stale
    /// 404: deleted or no longer eligible. The server never creates the file.
    case missing
    /// Other refusal (403, 413, 415, 428, 5xx). Disk was not changed by this request.
    case rejected(status: Int, message: String)
    /// Transport failed before the request could reach the server. Retrying with
    /// the same tag is safe.
    case notSent
    /// Transport failed after the body may have been sent. The write may or may
    /// not have landed; re-read before any retry.
    case unknown
}

/// Exact UTF-8 text codec for the editor. No BOM stripping, line-ending,
/// Unicode, or trailing-newline normalization.
enum WorkspaceFileTextCodec {
    static func decode(_ bytes: Data) -> String? {
        guard let text = String(validating: bytes, as: UTF8.self),
              !text.utf8.contains(0) else { return nil }
        return text
    }

    /// Drafts are the editor's own bytes: any valid UTF-8, including NUL a
    /// server refused. Only disk reads need the stricter `decode`.
    static func decodeDraft(_ bytes: Data) -> String? {
        String(validating: bytes, as: UTF8.self)
    }

    static func encode(_ text: String) -> Data {
        Data(text.utf8)
    }
}

/// Transport failures that prove the request never reached the server.
enum WorkspaceFileWriteFailureClassifier {
    static func outcome(for error: Error) -> WorkspaceFileWriteOutcome {
        guard let urlError = error as? URLError else {
            // Thrown before URLSession ran (auth refresh, URL build).
            return .notSent
        }
        switch urlError.code {
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
             .callIsActive, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection,
             .badURL, .unsupportedURL:
            return .notSent
        default:
            return .unknown
        }
    }
}
