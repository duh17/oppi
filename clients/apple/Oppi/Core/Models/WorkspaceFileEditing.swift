import CryptoKit
import Foundation

/// One editable workspace file. Server + workspace + worktree + workspace-relative
/// path. A nil worktree means the workspace's main checkout; a set worktree never
/// falls back to main, and no other origin (host, session) is editable.
struct WorkspaceFileEditIdentity: Hashable, Sendable, Codable {
    let serverId: String
    let workspaceId: String
    let worktreeId: String?
    let path: String

    init(serverId: String, workspaceId: String, worktreeId: String?, path: String) {
        self.serverId = serverId
        self.workspaceId = workspaceId
        let trimmed = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.worktreeId = trimmed.isEmpty ? nil : trimmed
        self.path = path
    }

    /// Stable file-name key for protected draft storage.
    var storageKey: String {
        let raw = ["v1", serverId, workspaceId, worktreeId ?? "", path].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
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
