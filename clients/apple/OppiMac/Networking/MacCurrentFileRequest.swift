import Foundation

/// One owner current-file read over the Unix socket.
///
/// OppiMac always uses `/files/current?origin=…`. There is no other Mac
/// client, so it does not keep the iOS legacy-route fallback. Origin selects
/// path resolution only; pairing/auth stays the host-file gate. A sandbox
/// session path uses `origin=session` and never `/files/raw`.
struct MacCurrentFileRequest: Sendable, Hashable {
    enum Origin: Sendable, Hashable {
        /// Absolute or `~/` owner-host path.
        case host
        /// Selected checkout. `main` and blank worktree IDs mean the default checkout.
        case workspace(workspaceID: String, worktreeId: String?)
        /// Session cwd (worktree or sandbox mount). `workspaceID` is unused on
        /// `/files/current` (the session names its workspace; a conflicting
        /// `workspaceId` query is 400).
        case session(workspaceID: String, sessionID: String)
    }

    let origin: Origin
    let path: String

    /// `nil` for an empty path; the server rejects it anyway.
    init?(origin: Origin, path: String) {
        guard !path.isEmpty else { return nil }
        self.origin = origin
        self.path = path
    }

    func requestTarget() -> String? {
        var query: [(String, String)]
        switch origin {
        case .host:
            query = [("origin", "host")]
        case .workspace(let workspaceID, let worktreeId):
            query = [("origin", "workspace"), ("workspaceId", workspaceID)]
            if let worktreeId = FileViewerPlan.normalizedWorktreeId(worktreeId) {
                query.append(("worktreeId", worktreeId))
            }
        case .session(_, let sessionID):
            query = [("origin", "session"), ("sessionId", sessionID)]
        }
        query.append(("path", path))
        return Self.target(segments: ["files", "current"], query: query)
    }

    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%+?#&")
        return allowed
    }()

    /// ASCII unreserved only: `+`, `&`, `=`, `/`, spaces, and non-ASCII are escaped.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func target(segments: [String], query: [(String, String)]) -> String? {
        var encodedSegments: [String] = []
        for segment in segments {
            guard !segment.isEmpty,
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed)
            else { return nil }
            encodedSegments.append(encoded)
        }
        var encodedQuery: [String] = []
        for (name, value) in query {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else {
                return nil
            }
            encodedQuery.append("\(name)=\(encoded)")
        }
        let path = "/" + encodedSegments.joined(separator: "/")
        return encodedQuery.isEmpty ? path : "\(path)?\(encodedQuery.joined(separator: "&"))"
    }
}
