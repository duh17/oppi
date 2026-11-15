import Foundation

/// A route with the server it lives on, as a link names it. `server` is an
/// identity fingerprint (`sha256:<hash>` or `<hash>`, as `PairedServer.id`);
/// nil means the server the link came from, else the window's active server.
struct PaneLink: Hashable, Sendable {
    var server: String?
    var route: PaneRoute
}

enum PaneLinkError: Error, Hashable, Sendable {
    case missing(String)
    case unknownParameter(String)
    case duplicateParameter(String)
    case invalidValue(String)
    /// A path the route does not take (an extra segment, a missing id).
    case unexpectedPath
    /// A fragment where none is allowed, user-info, or a port.
    case unexpectedComponent(String)
    /// A file link naming more than one of `workspace`, `host` and `session`,
    /// or a files link naming both `workspace` and `host`.
    case conflictingOrigin
}

/// Encodes and decodes the `oppi://` links of every linkable `PaneRoute`
/// (`protocol/links.json` v1). Pairing (`connect`), `workspace` and
/// `terminal` links are not pane links and decode to nil.
///
/// Every pane link only opens and takes an optional `server=`. On the pane
/// links new in v1 (sessions, file, files, git, panel, browser, godot) an unknown or repeated
/// parameter, user-info or a port makes the link invalid; only a file link
/// takes a fragment, `#L<line>`. Session and thread links keep their older
/// rule and ignore everything but `server` (a `?workspaceId=` most of all: a
/// URL never chooses a session's workspace). Route and parameter names are
/// case-insensitive; encoding writes them lowercase. A browser link's `url`
/// follows `PaneWebAddress`: http or https, no user-info, at most 2 KiB, not
/// loopback; a page that breaks them has no link.
enum PaneLinkCodec {
    static func decode(_ url: URL) -> Result<PaneLink, PaneLinkError>? {
        guard url.scheme?.lowercased() == "oppi",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        // `oppi://file?...` has the route as its host; `oppi:///file?...` as its first path part.
        if let host = components.percentEncodedHost, !host.isEmpty {
            parts.insert(host.removingPercentEncoding ?? host, at: 0)
        }
        guard let name = parts.first?.lowercased() else { return nil }
        let path = Array(parts.dropFirst())
        let query = components.queryItems ?? []
        switch name {
        case "session", "thread":
            return decodeSession(name: name, path: path, query: query)
        case "sessions", "file", "files", "git", "panel", "browser", "godot":
            if let component = [
                ("user", components.user), ("password", components.password),
                ("port", components.port.map(String.init)),
            ].first(where: { $0.1 != nil })?.0 {
                return .failure(.unexpectedComponent(component))
            }
            return decodeStrict(name: name, path: path, query: query, fragment: components.fragment)
        default:
            return nil
        }
    }

    /// The canonical link for `link`; nil for `.local` and `.unsupported`.
    static func encode(_ link: PaneLink) -> URL? {
        var path: String
        var query: [(String, String)] = []
        var fragment: String?
        switch link.route {
        case .sessions(let workspace):
            path = "sessions"
            if let workspace { query.append(("workspace", workspace)) }
        case .session(let id):
            path = "session/" + escape(id, allowingSlash: false)
        case .thread(let id):
            path = "thread/" + escape(id, allowingSlash: false)
        case .file(let origin, let filePath, let line):
            path = "file"
            switch origin {
            case .workspace(let id, let worktree):
                query.append(("workspace", id))
                query.append(("path", filePath))
                if let worktree { query.append(("worktree", worktree)) }
            case .host:
                query.append(("host", "1"))
                query.append(("path", filePath))
            case .session(let id):
                query.append(("session", id))
                query.append(("path", filePath))
            }
            fragment = line.map { "L\($0)" }
        case .files(let workspace, let filePath):
            path = "files"
            query.append(("workspace", workspace))
            if let filePath { query.append(("path", filePath)) }
        case .hostFiles(let filePath):
            path = "files"
            query.append(("host", "1"))
            if let filePath { query.append(("path", filePath)) }
        case .git(let workspace, let worktree):
            path = "git"
            query.append(("workspace", workspace))
            if let worktree { query.append(("worktree", worktree)) }
        case .commit(let workspace, let sha):
            path = "git/commit/" + escape(sha, allowingSlash: false)
            query.append(("workspace", workspace))
        case .panel(let session, let id):
            path = "panel"
            query.append(("session", session))
            query.append(("id", id))
        case .browser(let url):
            guard case .success = PaneWebAddress.check(url.absoluteString) else { return nil }
            path = "browser"
            query.append(("url", url.absoluteString))
        case .godot(let project):
            path = "godot"
            query.append(("project", project))
        case .local, .unsupported:
            return nil
        }
        if let server = link.server { query.append(("server", server)) }
        var string = "oppi://" + path
        if !query.isEmpty {
            string += "?" + query.map { "\($0.0)=\(escape($0.1, allowingSlash: true))" }.joined(separator: "&")
        }
        if let fragment { string += "#" + fragment }
        return URL(string: string)
    }

    // MARK: Decoding

    private static func decodeSession(name: String, path: [String], query: [URLQueryItem]) -> Result<PaneLink, PaneLinkError> {
        guard path.count == 1 else { return .failure(.unexpectedPath) }
        let id = path[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .failure(.unexpectedPath) }
        var server: String?
        for item in query where item.name.lowercased() == "server" {
            guard server == nil else { return .failure(.duplicateParameter("server")) }
            server = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let route: PaneRoute = name == "session" ? .session(id) : .thread(id)
        return .success(PaneLink(server: server.flatMap { $0.isEmpty ? nil : $0 }, route: route))
    }

    private static func decodeStrict(
        name: String, path: [String], query: [URLQueryItem], fragment: String?
    ) -> Result<PaneLink, PaneLinkError> {
        let allowed: Set<String> = switch name {
        case "sessions": ["workspace"]
        case "file": ["workspace", "worktree", "host", "session", "path"]
        case "files": ["workspace", "host", "path"]
        case "git": path.isEmpty ? ["workspace", "worktree"] : ["workspace"]
        case "browser": ["url"]
        case "godot": ["project"]
        default: ["session", "id"]
        }
        var values: [String: String] = [:]
        var seen: Set<String> = []
        for item in query {
            let key = item.name.lowercased()
            guard key == "server" || allowed.contains(key) else { return .failure(.unknownParameter(item.name)) }
            // A repeated name could mean two things; refuse rather than pick one.
            guard seen.insert(key).inserted else { return .failure(.duplicateParameter(key)) }
            let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { values[key] = value }
        }
        func required(_ key: String) -> Result<String, PaneLinkError> {
            values[key].map(Result.success) ?? .failure(.missing(key))
        }
        if fragment != nil, name != "file" { return .failure(.unexpectedComponent("fragment")) }

        let route: Result<PaneRoute, PaneLinkError>
        switch name {
        case "sessions":
            guard path.isEmpty else { return .failure(.unexpectedPath) }
            route = .success(.sessions(workspace: values["workspace"]))
        case "file":
            guard path.isEmpty else { return .failure(.unexpectedPath) }
            route = decodeFile(values: values, fragment: fragment)
        case "files":
            guard path.isEmpty else { return .failure(.unexpectedPath) }
            route = decodeFiles(values: values)
        case "git":
            switch path.count {
            case 0:
                route = required("workspace").map { .git(workspace: $0, worktree: values["worktree"]) }
            case 2 where path[0].lowercased() == "commit":
                let sha = path[1].lowercased()
                guard (4...64).contains(sha.count), sha.allSatisfy(\.isHexDigit) else {
                    return .failure(.invalidValue("sha"))
                }
                route = required("workspace").map { .commit(workspace: $0, sha: sha) }
            default:
                return .failure(.unexpectedPath)
            }
        case "browser":
            guard path.isEmpty else { return .failure(.unexpectedPath) }
            route = required("url").flatMap { value in
                PaneWebAddress.check(value).map(PaneRoute.browser).mapError { _ in .invalidValue("url") }
            }
        case "godot":
            guard path.isEmpty else { return .failure(.unexpectedPath) }
            route = required("project").map { .godot(project: $0) }
        default:
            guard path.isEmpty else { return .failure(.unexpectedPath) }
            route = required("session").flatMap { session in
                required("id").map { .panel(session: session, id: $0) }
            }
        }
        return route.map { PaneLink(server: values["server"], route: $0) }
    }

    /// A folder in a workspace, or with `host=1` in the server's home folder
    /// (`~` or `~/…`, as a host file link names its file).
    private static func decodeFiles(values: [String: String]) -> Result<PaneRoute, PaneLinkError> {
        guard values["host"] != nil else {
            return required("workspace", in: values).map { .files(workspace: $0, path: values["path"]) }
        }
        guard values["workspace"] == nil else { return .failure(.conflictingOrigin) }
        guard values["host"] == "1" else { return .failure(.invalidValue("host")) }
        guard let path = values["path"] else { return .success(.hostFiles(path: nil)) }
        guard path == "~" || path.hasPrefix("~/") else { return .failure(.invalidValue("path")) }
        return .success(.hostFiles(path: path == "~" ? nil : path))
    }

    private static func required(_ key: String, in values: [String: String]) -> Result<String, PaneLinkError> {
        values[key].map(Result.success) ?? .failure(.missing(key))
    }

    private static func decodeFile(values: [String: String], fragment: String?) -> Result<PaneRoute, PaneLinkError> {
        var line: Int?
        if let fragment {
            let digits = fragment.dropFirst()
            guard fragment.first == "L", !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                  let value = Int(digits), value >= 1 else { return .failure(.invalidValue("line")) }
            line = value
        }
        let named = ["workspace", "host", "session"].filter { values[$0] != nil }
        guard named.count <= 1 else { return .failure(.conflictingOrigin) }
        guard let originName = named.first else { return .failure(.missing("workspace")) }
        if originName != "workspace", values["worktree"] != nil { return .failure(.unknownParameter("worktree")) }
        guard let path = values["path"] else { return .failure(.missing("path")) }
        let origin: PaneFileOrigin
        switch originName {
        case "workspace":
            origin = .workspace(id: values["workspace"] ?? "", worktree: values["worktree"])
        case "host":
            guard values["host"] == "1" else { return .failure(.invalidValue("host")) }
            origin = .host
        default:
            origin = .session(values["session"] ?? "")
        }
        return .success(.file(origin, path: path, line: line))
    }

    // MARK: Encoding

    /// Percent-encodes all but unreserved characters and `:` (and `/` in
    /// query values, so paths stay readable).
    private static func escape(_ value: String, allowingSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:")
        if allowingSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
