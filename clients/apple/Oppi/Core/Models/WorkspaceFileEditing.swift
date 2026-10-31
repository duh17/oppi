import CryptoKit
import Foundation

/// One editable document: server + owner + owner-relative path. A workspace file
/// names its checkout (a nil worktree means main; a set worktree never falls
/// back to main). A Skill file is one of an editable Skill's own files. Pi's own
/// agent files (`SYSTEM.md`, `prompts/`) are the host home's one writable spot.
/// An Agent prompt and a Schedule prompt are records the editor writes through
/// their own endpoints, tagged by the record's version. No other origin (host,
/// session) is editable.
struct WorkspaceFileEditIdentity: Hashable, Sendable {
    /// What reads and writes the document.
    enum Owner: Hashable, Sendable {
        /// `origin=workspace` on `/files/current`.
        case workspace(id: String, worktreeId: String?)
        /// `origin=skill` on `/files/current`.
        case skill(id: String)
        /// `origin=pi` on `/files/current`: Pi's own agent files, allowlisted by
        /// the server, never the rest of the host home.
        case pi
        /// An Agent's `instructions.text`, read and written with `GET`/`PATCH /agents/:id`.
        case agent(id: String)
        /// A Schedule's `action.prompt`, read and written with `GET`/`PATCH /schedules/:id`.
        case schedule(id: String)

        /// A document served by `/files/current`, which the server advertises
        /// editing for. A record's prompt is edited through its own route.
        var isFile: Bool {
            switch self {
            case .workspace, .skill, .pi: true
            case .agent, .schedule: false
            }
        }
    }

    let serverId: String
    let owner: Owner
    /// Workspace-, Skill-, or Pi-agent-relative path; the document's name for a
    /// record's prompt.
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

    /// Pi's own agent file, by Pi-agent-relative path (`SYSTEM.md`, `prompts/x.md`).
    init(serverId: String, piPath: String) {
        self.serverId = serverId
        self.owner = .pi
        self.path = piPath
    }

    init(serverId: String, agentId: String) {
        self.serverId = serverId
        self.owner = .agent(id: agentId)
        // A name for the diff, the grammar, and the conflict sheet.
        self.path = "Instructions.md"
    }

    init(serverId: String, scheduleId: String) {
        self.serverId = serverId
        self.owner = .schedule(id: scheduleId)
        self.path = "Prompt.md"
    }

    /// Stable file-name key for protected draft storage.
    var storageKey: String {
        let parts: [String] = switch owner {
        // The workspace key predates Skill files; changing it would strand drafts.
        case .workspace(let workspaceId, let worktreeId): ["v1", serverId, workspaceId, worktreeId ?? "", path]
        case .skill(let skillId): ["skill-v1", serverId, skillId, path]
        case .pi: ["pi-v1", serverId, path]
        case .agent(let agentId): ["agent-v1", serverId, agentId]
        case .schedule(let scheduleId): ["schedule-v1", serverId, scheduleId]
        }
        let raw = parts.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Flat keys, so drafts stored before Skill files decode as workspace files.
extension WorkspaceFileEditIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case serverId, workspaceId, worktreeId, skillId, agentId, scheduleId, pi, path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serverId = try container.decode(String.self, forKey: .serverId)
        let path = try container.decode(String.self, forKey: .path)
        if let agentId = try container.decodeIfPresent(String.self, forKey: .agentId) {
            self.init(serverId: serverId, agentId: agentId)
        } else if let scheduleId = try container.decodeIfPresent(String.self, forKey: .scheduleId) {
            self.init(serverId: serverId, scheduleId: scheduleId)
        } else if let skillId = try container.decodeIfPresent(String.self, forKey: .skillId) {
            self.init(serverId: serverId, skillId: skillId, path: path)
        } else if try container.decodeIfPresent(Bool.self, forKey: .pi) == true {
            self.init(serverId: serverId, piPath: path)
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
        case .agent(let agentId):
            try container.encode(agentId, forKey: .agentId)
        case .schedule(let scheduleId):
            try container.encode(scheduleId, forKey: .scheduleId)
        case .pi:
            try container.encode(true, forKey: .pi)
        }
    }
}

/// Bytes of one `GET /files/current?origin=workspace` and the strong ETag from the
/// same response. A nil tag means the server did not offer the file for editing;
/// `creatable` means it offered to create a file that is not there.
struct WorkspaceFileDiskSnapshot: Sendable, Equatable {
    let bytes: Data
    let etag: String?
    /// The read answered "missing, creatable": no version, and the save that
    /// follows is conditioned on the file still being absent. The bytes are the
    /// seed text the reader supplied (empty when there is none) — what an editor
    /// starts from, not what the server holds. Only Pi's own allowlisted files
    /// answer this (`X-Oppi-Creatable`).
    let creatable: Bool

    init(bytes: Data, etag: String?, creatable: Bool = false) {
        self.bytes = bytes
        self.etag = etag
        self.creatable = creatable
    }

    /// What a save from these bytes is conditioned on, or nil when the server did
    /// not offer the file for editing at all.
    var writeCondition: WorkspaceFileWriteCondition? {
        if let etag { return .version(etag) }
        return creatable ? .absent : nil
    }
}

/// What one save is conditioned on: the disk version it overwrites (`If-Match`),
/// or the fact that the file must still not exist (`If-None-Match: *`), which is
/// how the editor creates a file it read as absent.
enum WorkspaceFileWriteCondition: Sendable, Equatable {
    case version(String)
    case absent

    /// The tag a draft keeps between launches. `*` is the absence precondition,
    /// the same token the request sends, so a draft of a file that was never
    /// created still knows its own base.
    var storedTag: String {
        switch self {
        case .version(let tag): tag
        case .absent: "*"
        }
    }

    init(storedTag: String) {
        self = storedTag == "*" ? .absent : .version(storedTag)
    }
}

enum WorkspaceFileReadOutcome: Sendable, Equatable {
    case snapshot(WorkspaceFileDiskSnapshot)
    /// The file does not exist, and the server offered to create it: an empty
    /// base whose first save writes it.
    case creatable
    /// 404: deleted, unknown worktree, or no longer an eligible file.
    case missing
    /// Transport or unexpected server failure. Nothing is known about disk.
    case failed
}

/// Typed result of `PUT /files/current?origin=workspace`.
enum WorkspaceFileWriteOutcome: Sendable, Equatable {
    case saved(etag: String)
    /// 412: the disk tag no longer matches `If-Match`, or the file this save
    /// would have created is there now. Disk was not changed.
    case stale
    /// 404: deleted or no longer eligible. A workspace or Skill file is never
    /// created by a save.
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
