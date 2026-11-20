import UIKit

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

/// The folder the terminal calls the shell's. OSC 7 is the shell's own report,
/// but Herdr does not pass its panes' reports through: in a terminal Oppi
/// started in Herdr, the host's Herdr knows the real folder (its focused pane's).
enum SSHTerminalShellFolder {
    /// - `reported`: the engine's OSC 7 folder, empty when none.
    /// - `reportedFromOtherHost`: the latest report named another machine (a
    ///   nested ssh), so the folder is unknown.
    /// - `herdrInFront`: Oppi started this terminal in Herdr and its alternate
    ///   screen is up. Nothing else counts, so a `herdr` typed in a shell, tmux,
    ///   or vim never takes the folder.
    /// - `herdr`: what the host's Herdr last reported.
    ///
    /// In front, the shell's own report is never used: Herdr passes no panes'
    /// reports through, and one made before it started is stale. A report from
    /// another machine leaves the folder unknown rather than the host's Herdr's
    /// folder; otherwise the focused pane's folder; otherwise unknown.
    static func resolve(
        reported: String,
        reportedFromOtherHost: Bool,
        herdrInFront: Bool,
        herdr: HerdrLocalFolder
    ) -> String {
        guard herdrInFront else { return reported }
        guard !reportedFromOtherHost, case .folder(let folder) = herdr else { return "" }
        return folder
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
    /// A path on the SSH host. Absolute, or `~/…` which the file route
    /// expands. A file opens at `line` when the link named one.
    case path(String, line: SourceLineAnchor? = nil)

    var hostLabel: String? {
        if case .web(_, let hostLabel) = self { return hostLabel }
        return nil
    }

    var path: String? {
        if case .path(let path, _) = self { return path }
        return nil
    }
}

/// Turns the word (or OSC 8 link) under a held cell into something openable.
/// The double tap's word rules already make `https://example.com/a/b?x=1` and
/// `/usr/local/bin/thing` one word, so this only has to decide what it is.
enum SSHTerminalOpenResolution {
    /// An OSC 8 link wins over the word it covers: that is where the program
    /// said the text points. A link with a scheme other than http, https or
    /// file is not opened at all (no fallback to the word), which keeps
    /// `vscode://…` a Copy.
    ///
    /// - `shellHost`: the machine the shell's first OSC 7 report named.
    /// - `sshHost`: the host this terminal connected to. A `file://` link
    ///   naming either (or no machine, or `localhost`) is a path here; one
    ///   naming another machine is not.
    static func target(
        text: String?,
        hyperlink: String?,
        folder: String?,
        shellHost: String? = nil,
        sshHost: String = ""
    ) -> SSHTerminalOpenTarget? {
        if let hyperlink, !hyperlink.isEmpty {
            return linkTarget(hyperlink, folder: folder, shellHost: shellHost, sshHost: sshHost)
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Whole first: `http://localhost:3000` is a URL with a port, not a
        // path with a line number.
        if let web = webTarget(text) { return web }
        // A word split by a space is not one path; an OSC 8 address may be.
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }
        let (value, line) = splittingLineColumn(text)
        guard let path = pathTarget(value, folder: folder) else { return nil }
        return .path(path, line: line)
    }

    /// An OSC 8 address: a web page, a `file://` URI on this host, or a
    /// path (absolute, `~/…`, or relative to the shell's folder) with an
    /// optional `#L12`, `#L12-L20`, `:12` or `:12:5` line. Pi prints
    /// `[label](src/x.ts#L194)` as a link to `src/x.ts#L194`.
    static func linkTarget(
        _ link: String,
        folder: String?,
        shellHost: String?,
        sshHost: String
    ) -> SSHTerminalOpenTarget? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let web = webTarget(link) { return web }
        let (address, fragment) = splittingFragment(link)
        let fragmentLine = fragment.flatMap { SourceLineAnchor.parse("#" + $0) }
        if address.lowercased().hasPrefix("file:") {
            guard let report = SSHTerminalWorkingDirectory.report(from: address),
                  report.isLocal || isThisHost(report.host, shellHost: shellHost, sshHost: sshHost) else { return nil }
            return .path(report.path, line: fragmentLine)
        }
        let decoded = address.removingPercentEncoding ?? address
        let (value, suffixLine) = splittingLineColumn(decoded)
        // `README.md:42` parses with a scheme, so the line is stripped first.
        guard !hasScheme(value) else { return nil }
        guard let path = pathTarget(value, folder: folder, anyName: true) else { return nil }
        return .path(path, line: fragmentLine ?? suffixLine)
    }

    /// Whether a `file://` URI's machine is the one this terminal reaches:
    /// the shell's own OSC 7 machine, or the SSH host by the same name rules
    /// as the paired-server match (a tailnet name and its short name).
    static func isThisHost(_ host: String, shellHost: String?, sshHost: String) -> Bool {
        let host = SSHTerminalServerMatch.normalize(host)
        guard !host.isEmpty else { return false }
        if let shellHost, !shellHost.isEmpty, SSHTerminalServerMatch.normalize(shellHost) == host { return true }
        return SSHTerminalServerMatch.serverId(forHost: host, paired: [(id: "ssh", host: sshHost)]) != nil
    }

    /// Split one `:line` or `:line:column` suffix, which editors print after
    /// a path. Copy keeps it; Open would otherwise look for a file named
    /// `x:42`, and the file opens at that line. Only paths reach this: a
    /// URL's `:port` must survive.
    static func splittingLineColumn(_ text: String) -> (path: String, line: SourceLineAnchor?) {
        guard let range = text.range(of: ":[0-9]+(:[0-9]+)?$", options: .regularExpression) else { return (text, nil) }
        let line = text[range].dropFirst().split(separator: ":").first.flatMap { Int($0) }
        return (String(text[..<range.lowerBound]), line.flatMap { SourceLineAnchor(startLine: $0, endLine: $0) })
    }

    private static func splittingFragment(_ link: String) -> (String, String?) {
        guard let hash = link.firstIndex(of: "#") else { return (link, nil) }
        return (String(link[..<hash]), String(link[link.index(after: hash)...]))
    }

    private static func hasScheme(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
    }

    static func webTarget(_ text: String) -> SSHTerminalOpenTarget? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return .web(url: url, hostLabel: host)
    }

    /// Absolute paths, and relative ones against the shell's folder. A
    /// relative path with no known folder is not openable: guessing a base
    /// would open the wrong file. `anyName` takes a bare relative name
    /// (`Makefile`): an OSC 8 link says it is a path, a word does not.
    static func pathTarget(_ text: String, folder: String?, anyName: Bool = false) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096 else { return nil }
        if value.hasPrefix("~/") {
            let rest = String(value.dropFirst(2))
            guard !rest.isEmpty,
                  let relative = SSHTerminalPathResolution.normalizingRelative(rest) else { return nil }
            return "~/" + relative
        }
        if value.hasPrefix("/") {
            return SSHTerminalWorkingDirectory.normalize(value)
        }
        guard let folder, folder.hasPrefix("/"), anyName || value.contains("/") || looksLikeFileName(value) else { return nil }
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
    /// Whether the hold menu and a tap offer Open for `target`. A web page
    /// always; a path only on a paired server, and not outside its home once
    /// the home is known (until then the server's answer decides on Open).
    static func offers(_ target: SSHTerminalOpenTarget, isPairedServer: Bool, home: String?) -> Bool {
        guard let path = target.path else { return true }
        guard isPairedServer else { return false }
        guard let home, let absolute = absolute(path, home: home) else { return true }
        return isInside(home: home, path: absolute)
    }

    /// `~/…` against the server's home; an absolute path is already resolved.
    static func absolute(_ path: String, home: String?) -> String? {
        guard path.hasPrefix("~/") else { return path.hasPrefix("/") ? path : nil }
        guard let home else { return nil }
        return SSHTerminalPathResolution.absolute(String(path.dropFirst(2)), relativeTo: home)
    }

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

    /// The screen's name: the title the shell set, else the host. The host
    /// label of a folder terminal ends with the folder it was asked to open;
    /// once the shell reports its own folder (OSC 7) that one is shown after
    /// the name, so the requested one is dropped instead of appearing twice.
    static func name(shellTitle: String, hostLabel: String, hostName: String?, shellFolder: String) -> String {
        let shell = shellTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shell.isEmpty { return shell }
        let reportsFolder = !shellFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let host = reportsFolder ? (hostName ?? hostLabel) : hostLabel
        return host.isEmpty ? "Terminal" : host
    }

    static func text(title: String, folder: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "Terminal" : title
        guard !folder.isEmpty else { return name }
        let room = maximumLength - name.count - 3
        guard room > 8 else { return name }
        let shown = folder.count <= room ? folder : "…" + String(folder.suffix(room - 1))
        return "\(name) — \(shown)"
    }
}

/// Where the terminal shows a file or folder it resolved: the pane owner's
/// `openBeside`, from the terminal's own pane, as the chat bar's Terminal and
/// a Rex link do. On a wide window it opens in a pane
/// beside the terminal (on the New Panes side for files), and a terminal is
/// never replaced. Elsewhere (a compact window, a full window
/// of panes) it is pushed over the terminal in the terminal's own navigation,
/// never onto the Workspaces stack a chat link falls back to: the terminal may
/// sit on the Terminal tab.
@MainActor
enum SSHTerminalOpenRoute {
    static func open(
        _ content: PaneOpenContent, kind: PaneContentKind, from screen: UIViewController, makeScreen: () -> UIViewController
    ) {
        if let host = PaneHostController.containing(screen), let cell = host.cell(holding: screen),
           host.openBeside(content, kind: kind, from: cell) { return }
        push(from: screen, makeScreen: makeScreen)
    }

    /// Over the terminal, unless something already covers it (Back before
    /// the lookup finished, another screen pushed meanwhile).
    static func push(from screen: UIViewController, makeScreen: () -> UIViewController) {
        guard screen.navigationController?.topViewController === screen else { return }
        Router.push(makeScreen(), from: screen)
    }
}
