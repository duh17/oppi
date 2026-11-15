import Foundation

/// The rules for a web page a link or a layout names (build plan §1.10): an
/// `oppi://browser?url=` link and a layout's `web` leaf. The server checks a
/// layout file's `web` field by the same rules (`server/src/layout-validation.ts`),
/// and both pass the web vectors of `protocol/layouts/vectors.json`.
///
/// A page the person opens directly (a link tapped in a chat, an address
/// typed into a pane, see `PaneTypedAddress`) only has to be http or https: it
/// loads on the device where it was tapped. Loopback is refused here because a link or a layout
/// travels: `localhost` is the Mac on the Mac and the iPad on the iPad.
enum PaneWebAddress {
    /// The most UTF-8 bytes an address may take.
    static let maximumBytes = 2048

    enum Problem: Error, Hashable, Sendable {
        /// Not a URL with a host.
        case malformed
        /// Not http or https.
        case scheme
        /// A user name or password in the URL.
        case userInfo
        /// Over `maximumBytes`.
        case tooLong
        /// `localhost`, `*.localhost`, 127.0.0.0/8 or ::1, in any spelling.
        case loopback
    }

    /// `string` as the URL a browser leaf opens, or the first rule it breaks.
    static func check(_ string: String) -> Result<URL, Problem> {
        guard string.utf8.count <= maximumBytes else { return .failure(.tooLong) }
        guard let url = URL(string: string), let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .failure(.malformed) }
        guard isHTTP(url) else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty else { return .failure(.malformed) }
        if components.user?.isEmpty == false || components.password?.isEmpty == false { return .failure(.userInfo) }
        if isLoopback(host: host) { return .failure(.loopback) }
        return .success(url)
    }

    /// Whether `url` is http or https, the only pages a browser leaf loads.
    static func isHTTP(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Whether `host` names this device's loopback. The server reads hosts as
    /// a browser does, so `127.1`, `0x7f.0.0.1` and `[::ffff:127.0.0.1]` are
    /// loopback there; this parses them the same way rather than matching text.
    static func isLoopback(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            let isLocal = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isMappedLoopback = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
                && bytes[12] == 127
            return isLocal || isMappedLoopback
        }
        // inet_aton reads the shorthand and hex forms a browser accepts.
        var v4 = in_addr()
        guard name.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }), inet_aton(name, &v4) == 1 else { return false }
        return UInt32(bigEndian: v4.s_addr) >> 24 == 127
    }

    /// Whether a browser leaf refuses to load `url` with `method`: any page at
    /// the origin of one of `servers` (host and port), where it would run
    /// beside Oppi's own API. Either scheme counts; a URL without a port uses
    /// its scheme's. The one exception is a GET of a Godot web build's signed
    /// play link (`isGodotPlayLink`): that link carries its own capability for
    /// one build and the page never gets Oppi's credentials.
    static func refusesServerPage(_ url: URL, method: String, servers: [(host: String, port: Int)]) -> Bool {
        guard let host = url.host(percentEncoded: false).map(normalisedHost) else { return false }
        let port = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        guard servers.contains(where: { normalisedHost($0.host) == host && $0.port == port }) else { return false }
        return !(method.uppercased() == "GET" && isGodotPlayLink(url))
    }

    /// Whether `url`'s path is a file of a Godot web build's play link,
    /// `/godot/<game>/play/<grant>[/<file>…]`, as the server's
    /// `GodotWebExports` signs it. Read from the encoded path, so a `..`, `.`,
    /// or encoded slash or dot never passes for one: the server sees the path
    /// this check saw.
    static func isGodotPlayLink(_ url: URL) -> Bool {
        let segments = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 5, segments[0].isEmpty, segments[1] == "godot", segments[3] == "play",
              segments[2].wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil,
              segments[4].wholeMatch(of: /[0-9a-f]{16}\.[0-9]{1,12}\.[A-Za-z0-9_-]{43}/) != nil
        else { return false }
        return segments.dropFirst(5).allSatisfy { segment in
            segment != "." && segment != ".." && !segment.contains("%")
        }
    }

    private static func normalisedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }
}
