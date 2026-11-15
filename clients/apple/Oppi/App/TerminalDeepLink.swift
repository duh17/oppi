import Foundation

/// `oppi://terminal/rex?session=<session id>&block=<block id>`: opens one Rex
/// pane in the SSH terminal. Rex names a pane by its session and block ids
/// (`session:<uuid>`, `block:<uuid>`, as `rex ls --json` and `rex split --json`
/// print them).
///
/// The link only opens. It carries no command, and any parameter beyond the
/// two ids makes it invalid, so nothing a link says is ever typed or run.
struct TerminalDeepLink: Equatable, Sendable {
    let sessionID: String
    let blockID: String
}

enum TerminalDeepLinkError: Error, Equatable, Sendable {
    /// Only Rex panes can be opened by link.
    case unsupportedMultiplexer
    case missing(String)
    case unknownParameter(String)
    case duplicateParameter(String)
    /// A fragment, user-info, or port: nothing a terminal link has.
    case unexpectedComponent(String)
}

/// One terminal link opened from a tap, a scene URL, or a push. `sourceServerID`
/// is the server of the chat the link was tapped in; a scene URL has none.
struct TerminalOpen: Equatable, Sendable {
    var sourceServerID: String?
    var link: Result<TerminalDeepLink, TerminalDeepLinkError>

    /// Nil unless `url` is an `oppi://terminal/...` link, valid or not.
    init?(url: URL, sourceServerID: String? = nil) {
        guard url.scheme?.lowercased() == "oppi" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var parts = (components?.percentEncodedPath ?? url.path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        // `oppi://terminal/rex` has the route as its host; `oppi:///terminal/rex` as its first path part.
        if let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            parts.insert(host, at: 0)
        }
        guard parts.first?.lowercased() == "terminal" else { return nil }
        self.sourceServerID = sourceServerID
        let unexpected = [
            ("fragment", components?.fragment), ("user", components?.user),
            ("password", components?.password), ("port", components?.port.map(String.init)),
        ].first { $0.1 != nil }?.0
        if let unexpected {
            link = .failure(.unexpectedComponent(unexpected))
        } else {
            link = Self.parse(multiplexer: parts.dropFirst().first, extra: parts.dropFirst(2).first, query: components?.queryItems ?? [])
        }
    }

    private static func parse(
        multiplexer: String?, extra: String?, query: [URLQueryItem]
    ) -> Result<TerminalDeepLink, TerminalDeepLinkError> {
        guard multiplexer?.lowercased() == "rex", extra == nil else { return .failure(.unsupportedMultiplexer) }
        var values: [String: String] = [:]
        var seen: Set<String> = []
        for item in query {
            let name = item.name.lowercased()
            guard name == "session" || name == "block" else { return .failure(.unknownParameter(item.name)) }
            let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A repeated name could mean two things; refuse rather than pick one.
            guard values[name] == nil, !seen.contains(name) else { return .failure(.duplicateParameter(name)) }
            seen.insert(name)
            if !value.isEmpty { values[name] = value }
        }
        guard let session = values["session"] else { return .failure(.missing("session")) }
        guard let block = values["block"] else { return .failure(.missing("block")) }
        return .success(TerminalDeepLink(sessionID: session, blockID: block))
    }
}

/// What a terminal link does, decided from the link, the server it belongs to,
/// and the saved SSH hosts. The decision never touches the network.
enum TerminalLinkRoute: Equatable {
    case invalid(TerminalDeepLinkError)
    /// The Rex experiment is off on this device.
    case rexOff
    /// The link's server turned its Rex switch off.
    case rexOffOnServer
    /// No server to take a host from.
    case noServerHost
    /// No saved host serves the server: Add Host, with the server's host filled in.
    case addHost(serverHost: String)
    /// A saved host serves the server, but its Multiplexer is not Rex.
    case hostNotRex(SSHTerminalProfile)
    case openPane(SSHTerminalProfile, TerminalDeepLink)

    static func decide(
        link: Result<TerminalDeepLink, TerminalDeepLinkError>,
        serverHost: String?,
        profiles: [SSHTerminalProfile],
        rexEnabled: Bool,
        serverOffersRex: Bool
    ) -> Self {
        let pane: TerminalDeepLink
        switch link {
        case .failure(let error): return .invalid(error)
        case .success(let value): pane = value
        }
        guard rexEnabled else { return .rexOff }
        guard serverOffersRex else { return .rexOffOnServer }
        let host = serverHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else { return .noServerHost }
        // A Rex host first, so a plain shell entry for the same machine does not hide it.
        if let rexHost = SSHTerminalHostMatch.bestMatch(in: profiles.filter(\.opensRexSessions), serverHost: host) {
            return .openPane(rexHost, pane)
        }
        if let other = SSHTerminalHostMatch.bestMatch(in: profiles, serverHost: host) {
            return .hostNotRex(other)
        }
        return .addHost(serverHost: host)
    }
}
