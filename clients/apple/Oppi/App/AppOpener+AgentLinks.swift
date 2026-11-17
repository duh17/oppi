import Foundation

extension AppOpenRequest {
    /// The request an agent's internal URL (`AgentInternalURL`) makes, or nil for any other URL.
    /// `history://<id>` and `agent://<id>` name a session; a bare scheme, a
    /// sub-path, or anything after the id has no place in the app. Any other
    /// one tapped in a session (`sourceSessionID`) opens in that session's
    /// viewer when its server shows the scheme (`PaneRoute.read`), else says
    /// it cannot open.
    static func agentInternalURL(
        _ url: URL,
        origin: SessionNavigationSource,
        sourceServerID: String?,
        sourceSessionID: String?
    ) -> AppOpenRequest? {
        guard let scheme = url.scheme?.lowercased(), AgentInternalURL.schemes.contains(scheme) else { return nil }
        guard scheme == "history" || scheme == "agent" else {
            guard let sourceSessionID else { return .unsupportedLink(url) }
            let link = PaneLink(server: nil, route: .read(session: sourceSessionID, url: url.absoluteString))
            return .pane(link, sourceServerID: sourceServerID)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.percentEncodedHost?.removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              components.user == nil, components.port == nil else { return .unsupportedLink(url) }
        return .sessionPrefix(SessionOpen(serverId: sourceServerID, sessionId: id, origin: origin))
    }

    /// What a tap on an `.unsupportedLink` says.
    static func unsupportedLinkMessage(_ url: URL) -> String {
        switch url.scheme?.lowercased() {
        case let scheme? where scheme == "proc" || scheme == "mcp" || scheme == "ssh":
            String(localized: "Oppi can\u{2019}t open \(scheme):// links here")
        default:
            String(localized: "Oppi can\u{2019}t open this link")
        }
    }
}

// The internal URLs an agent writes in chat (`history://`, `agent://`, `proc://`, `mcp://`, `ssh://`).
extension AppOpener {
    /// `history://<id>` or `agent://<id>`: the id as the server matches it
    /// (`pickId` in `server/src/internal-urls.ts`), an exact id, else the one
    /// id it begins, among the sessions loaded from the link's server (every
    /// server's for a link with none). A match opens as a session link; no
    /// match opens the id as written, which asks the server for it.
    func performSessionPrefix(_ open: SessionOpen, generation: UInt64) async -> AppOpenOutcome {
        let known = coordinator.connections
            .filter { open.serverId == nil || $0.key == open.serverId }
            .flatMap { serverId, connection in
                connection.sessionStore.sessions.map { (serverId: serverId, sessionId: $0.id) }
            }
        let exact = known.filter { $0.sessionId == open.sessionId }
        let matches = exact.isEmpty ? known.filter { $0.sessionId.hasPrefix(open.sessionId) } : exact
        guard matches.count <= 1 else {
            toast(String(localized: "More than one session starts with \(open.sessionId)"))
            return .finished
        }
        var resolved = open
        if let match = matches.first {
            resolved.serverId = match.serverId
            resolved.sessionId = match.sessionId
        }
        return await performSession(resolved, generation: generation)
    }
}
