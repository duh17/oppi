import Foundation

/// The shell's working directory, from OSC 7. libghostty stores the bytes the
/// shell emitted without parsing them, so only a local `file:` URL becomes a
/// path. `file://host/path` names the machine the shell runs on: a terminal
/// connected to one host must not resolve paths reported from another (a
/// nested `ssh` or a `tmux` session on a different machine), so the host is
/// kept and compared per connection.
enum SSHTerminalWorkingDirectory {
    static let maximumBytes = 4096

    struct Report: Equatable {
        /// The machine in the URL, lowercased without a trailing dot; empty
        /// for a URL that names none.
        var host: String
        var path: String

        /// A host that says nothing about which machine this is.
        var isLocal: Bool { host.isEmpty || host == "localhost" }

        /// The folder this connection may use, given the host first seen on
        /// it. A different machine leaves the folder unknown.
        func folder(firstHost: String?) -> String? {
            guard !isLocal else { return path }
            guard let firstHost, !firstHost.isEmpty else { return path }
            return firstHost == host ? path : nil
        }
    }

    /// A local path, or nil when the shell reported nothing usable.
    static func path(from raw: String) -> String? {
        report(from: raw)?.path
    }

    static func report(from raw: String) -> Report? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        guard trimmed.lowercased().hasPrefix("file:") else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "file" else {
            return nil
        }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        guard let path = normalize(url.path) else { return nil }
        var host = (url.host ?? "").lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return Report(host: host, path: path)
    }

    /// A lexical path: absolute, no control characters, no `..` left, and no
    /// trailing slash except at the root.
    static func normalize(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.utf8.count <= maximumBytes else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        let components = SSHTerminalPathResolution.absoluteComponents(trimmed)
        return components.isEmpty ? "/" : components.joined()
    }
}

/// What a held cell offers: the word the double tap would copy, and the OSC 8
/// link the cell carries, if any.
struct SSHTerminalHeldCell: Equatable {
    var text: String
    var spans: [SSHTerminalSelectionSpan]
    var hyperlink: String?
}

/// What a held cell can open. Copy always works; Open needs one of these.
enum SSHTerminalOpenTarget: Equatable {
    /// A web page, opened in the system browser. `hostLabel` names the site in
    /// the menu so the destination is visible before the tap.
    case web(url: URL, hostLabel: String)
    /// A path on the SSH host. Absolute, or `~/…` which the file route expands.
    case path(String)

    var hostLabel: String? {
        if case .web(_, let hostLabel) = self { return hostLabel }
        return nil
    }

    var path: String? {
        if case .path(let path) = self { return path }
        return nil
    }
}

/// Turns the word (or OSC 8 link) under a held cell into something openable.
/// The double tap's word rules already make `https://example.com/a/b?x=1` and
/// `/usr/local/bin/thing` one word, so this only has to decide what it is.
enum SSHTerminalOpenResolution {
    /// An OSC 8 link wins over the word it covers: that is where the program
    /// said the text points. A link with another scheme is not opened at all
    /// (no fallback to the word), which keeps `vscode://…` a Copy.
    static func target(
        text: String?,
        hyperlink: String?,
        folder: String?
    ) -> SSHTerminalOpenTarget? {
        if let hyperlink, !hyperlink.isEmpty {
            return webTarget(hyperlink)
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Whole first: `http://localhost:3000` is a URL with a port, not a
        // path with a line number.
        if let web = webTarget(text) { return web }
        guard let path = pathTarget(strippingLineColumn(text), folder: folder) else { return nil }
        return .path(path)
    }

    /// Drop one `:line` or `:line:column` suffix, which editors print after a
    /// path. Copy keeps it; Open would otherwise look for a file named `x:42`.
    /// Only paths reach this: a URL's `:port` must survive.
    static func strippingLineColumn(_ text: String) -> String {
        var value = text
        if let range = value.range(of: ":[0-9]+(:[0-9]+)?$", options: .regularExpression) {
            value.removeSubrange(range)
        }
        return value
    }

    static func webTarget(_ text: String) -> SSHTerminalOpenTarget? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return .web(url: url, hostLabel: host)
    }

    /// Absolute paths, and relative ones against the shell's folder. A
    /// relative path with no known folder is not openable: guessing a base
    /// would open the wrong file.
    static func pathTarget(_ text: String, folder: String?) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { return nil }
        guard !value.contains(where: { $0.isWhitespace }) else { return nil }
        if value.hasPrefix("~/") {
            let rest = String(value.dropFirst(2))
            guard !rest.isEmpty,
                  let relative = SSHTerminalPathResolution.normalizingRelative(rest) else { return nil }
            return "~/" + relative
        }
        if value.hasPrefix("/") {
            return SSHTerminalWorkingDirectory.normalize(value)
        }
        guard let folder, folder.hasPrefix("/"), value.contains("/") || looksLikeFileName(value) else { return nil }
        guard let resolved = SSHTerminalPathResolution.absolute(value, relativeTo: folder) else { return nil }
        return resolved
    }

    /// A bare word such as `README.md` is a candidate only with a folder to
    /// resolve it against, and only when it names a file rather than prose.
    private static func looksLikeFileName(_ value: String) -> Bool {
        guard let dot = value.lastIndex(of: "."), dot != value.startIndex else { return false }
        let suffix = value[value.index(after: dot)...]
        guard (1...8).contains(suffix.count) else { return false }
        return suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

/// Lexical path joining, independent of the file system: the host may be a
/// machine whose paths this device cannot see.
enum SSHTerminalPathResolution {
    /// Absolute path for `path` resolved against the absolute `folder`.
    static func absolute(_ path: String, relativeTo folder: String) -> String? {
        guard folder.hasPrefix("/") else { return nil }
        let joined = path.hasPrefix("/") ? path : folder + "/" + path
        return SSHTerminalWorkingDirectory.normalize(joined)
    }

    /// Components of an absolute path, without `..` or empty segments, each
    /// with its leading slash so joining them rebuilds the path.
    static func absoluteComponents(_ path: String) -> [String] {
        var stack = [String]()
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(component))
            }
        }
        return stack.map { "/" + $0 }
    }

    /// Collapse `.` and `..` in a relative path, keeping it relative. A `..`
    /// that climbs above the start is not a path: `~/../x` is not `~/x`.
    static func normalizingRelative(_ path: String) -> String? {
        var stack = [String]()
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default:
                stack.append(String(component))
            }
        }
        return stack.isEmpty ? nil : stack.joined(separator: "/")
    }
}

/// Whether an SSH host is also a paired Oppi server, so the terminal can open
/// a file on it through that server's own file routes.
enum SSHTerminalServerMatch {
    /// The id of the paired server for `host`, if one names the same machine.
    /// A tailnet FQDN and its short name are the same machine: `mac-studio`
    /// and `mac-studio.tail1234.ts.net` both reach the server.
    static func serverId(forHost host: String, paired: [(id: String, host: String)]) -> String? {
        let target = normalize(host)
        guard !target.isEmpty else { return nil }
        func matches(_ server: (id: String, host: String)) -> Bool {
            let candidate = normalize(server.host)
            if candidate == target { return true }
            if isTailnetName(candidate), shortName(candidate) == target { return true }
            if isTailnetName(target), shortName(target) == candidate { return true }
            return false
        }
        // An exact name wins outright; anything else must be unambiguous, or
        // the terminal would open a file on the wrong server.
        if let exact = paired.first(where: { normalize($0.host) == target }) { return exact.id }
        let loose = paired.filter(matches)
        return loose.count == 1 ? loose[0].id : nil
    }

    /// Case-insensitive, without a trailing root dot.
    static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }

    static func isTailnetName(_ host: String) -> Bool {
        host.hasSuffix(".ts.net") || host.hasSuffix(".beta.tailscale.net")
    }

    private static func shortName(_ host: String) -> String {
        host.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
    }
}

/// What the terminal can do with a path on a paired server. Owner-host files
/// are rooted at the user's home there, so a path outside it is not offered:
/// the Files browser cannot show it and the viewer is home-relative.
enum SSHTerminalHostPathPlan: Equatable {
    case file(String)
    case folder(String)
    case refused(String)
}

enum SSHTerminalHostPathPolicy {
    static func isInside(home: String, path: String) -> Bool {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !home.isEmpty, home.hasPrefix("/") else { return false }
        return path == home || path.hasPrefix(home + "/")
    }

    /// A file opens in the viewer, a folder in the Files browser, and anything
    /// else is refused with the reason the screen shows.
    static func plan(status: HostPathStatus, home: String) -> SSHTerminalHostPathPlan {
        let path = status.resolvedPath
        guard status.exists else { return .refused("That path is not on the host.") }
        guard isInside(home: home, path: path) else {
            return .refused("Files open inside the server's home folder.")
        }
        if status.isDirectory { return .folder(path) }
        if status.isFile { return .file(path) }
        return .refused("That path is not a file or a folder.")
    }
}

/// Why a path on a paired server could not be opened before any file was read.
enum SSHTerminalHostFilesError: Error {
    /// The server did not report a home folder, so nothing is rooted anywhere.
    case homePathInvalid
}

/// The … menu's header: the screen's name, then the shell's folder when the
/// shell reported one. The folder keeps its tail when it has to be shortened,
/// since that is the part that says where you are.
enum SSHTerminalMenuHeader {
    static let maximumLength = 80

    static func text(title: String, folder: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "SSH Terminal" : title
        guard !folder.isEmpty else { return name }
        let room = maximumLength - name.count - 3
        guard room > 8 else { return name }
        let shown = folder.count <= room ? folder : "…" + String(folder.suffix(room - 1))
        return "\(name) — \(shown)"
    }
}
