import UIKit

// How a pin reads in a list, from its route: the Pinned screen's group and
// icon, the row's title and second line, and its identifier. One place for
// every list that shows pins (the Pinned screen, the File Browser's Pinned
// section, the pane launcher).

/// What kind of place a pin opens: the Pinned screen's groups, in order.
enum PinKind: Int, Hashable, Sendable, CaseIterable {
    case sessions, games, git, web, panels, folders, files

    /// Nil for a route with no link, which a pin never names.
    init?(_ route: PaneRoute) {
        switch route {
        case .session, .thread, .sessions: self = .sessions
        case .godot: self = .games
        case .git, .commit: self = .git
        case .browser: self = .web
        case .panel: self = .panels
        case .files, .hostFiles: self = .folders
        case .file: self = .files
        case .local, .unsupported: return nil
        }
    }

    var title: String {
        switch self {
        case .sessions: String(localized: "Sessions")
        case .games: String(localized: "Games")
        case .git: String(localized: "Git")
        case .web: String(localized: "Web Pages")
        case .panels: String(localized: "Panels")
        case .folders: String(localized: "Folders")
        case .files: String(localized: "Files")
        }
    }

    /// The row's symbol; a file shows its own file icon instead.
    var symbol: String {
        switch self {
        case .sessions: "bubble.left.and.text.bubble.right"
        case .games: "gamecontroller.fill"
        case .git: "arrow.triangle.branch"
        case .web: "globe"
        case .panels: "rectangle.righthalf.inset.filled"
        case .folders: "folder.fill"
        case .files: "doc"
        }
    }
}

extension PaneRoute {
    /// Whether a pin may name this route: it has a link (a web page only
    /// under the link rules).
    var isPinnable: Bool {
        PaneLinkCodec.encode(PaneLink(server: nil, route: self)) != nil
    }

    /// A folder or file in the home folder or a workspace's main checkout:
    /// what the File Browser's Pinned section and the launcher list.
    var isBrowserPlace: Bool {
        switch self {
        case .files, .hostFiles, .file(.host, _, _), .file(.workspace(_, .none), _, _): true
        default: false
        }
    }

    /// The workspace the route lives in, if it names one.
    var workspaceId: String? {
        switch self {
        case .files(let id, _), .file(.workspace(let id, _), _, _), .git(let id, _), .commit(let id, _): id
        case .sessions(let id): id
        default: nil
        }
    }

    /// The session the route belongs to, if it names one.
    var sessionId: String? {
        switch self {
        case .session(let id), .thread(let id), .panel(let id, _), .file(.session(let id), _, _): id
        default: nil
        }
    }

    /// A pin row's identifier suffix: a Home path (`~/notebook`), a
    /// workspace place (`<workspace>:<path>`), else `<kind>:<what>`
    /// (`session:<id>`, `game:<project>`, `git:<workspace>`, `browser:<url>`).
    var pinKey: String {
        switch self {
        case .hostFiles(let path): path ?? "~"
        case .file(.host, let path, _): path
        case .files(let id, let path): "\(id):\(path ?? "")"
        case .file(.workspace(let id, nil), let path, _): "\(id):\(path)"
        case .file(.workspace(let id, let worktree?), let path, _): "\(id)@\(worktree):\(path)"
        case .file(.session(let id), let path, _): "session:\(id):\(path)"
        case .session(let id): "session:\(id)"
        case .thread(let id): "thread:\(id)"
        case .sessions(let id): "sessions:\(id ?? "all")"
        case .git(let id, let worktree): "git:\(id)" + (worktree.map { "@\($0)" } ?? "")
        case .commit(let id, let sha): "commit:\(id):\(sha)"
        case .panel(let session, let id): "panel:\(session):\(id)"
        case .browser(let url): "browser:\(url.absoluteString)"
        case .godot(let project): "game:\(project)"
        case .local(let token): "local:\(token.raw)"
        case .unsupported(let kind, _): "unsupported:\(kind)"
        }
    }
}

/// Names a list resolves for a pin's row: its workspace's and its session's.
struct PinNames {
    var workspace: String?
    var session: String?

    static let none = Self()
}

extension Pin {
    var kind: PinKind? { PinKind(target) }

    /// Whether the server says the target is gone (or its workspace is).
    var isGone: Bool { status == .missing || status == .workspaceMissing }

    /// The label, else the target's own name.
    func displayName(_ names: PinNames = .none) -> String {
        if let label, !label.isEmpty { return label }
        return ownName(names)
    }

    /// The target's own name: a file or folder's name (Home, or a
    /// workspace root's workspace), a session's title, a game's name as the
    /// server read it, a web page's host, a commit's short sha.
    func ownName(_ names: PinNames = .none) -> String {
        func last(_ path: String) -> String { (path as NSString).lastPathComponent }
        switch target {
        case .hostFiles(nil): return String(localized: "Home")
        case .hostFiles(let path?): return last(path)
        case .files(_, nil): return names.workspace ?? String(localized: "Workspace")
        case .files(_, let path?): return last(path)
        case .file(_, let path, _): return last(path)
        case .session: return names.session ?? String(localized: "Session")
        case .thread: return names.session ?? String(localized: "Thread")
        case .sessions(nil): return String(localized: "All Sessions")
        case .sessions: return names.workspace ?? String(localized: "Sessions")
        case .git: return names.workspace ?? String(localized: "Git")
        case .commit(_, let sha): return String(sha.prefix(7))
        case .panel(_, let id): return id
        case .browser(let url): return url.host() ?? url.absoluteString
        case .godot: return name ?? String(localized: "Game")
        case .local, .unsupported: return ""
        }
    }

    /// The second line, the same in every list: why it cannot open, else
    /// where it lives ("Home › Books", a workspace and its folders, a
    /// worktree, a page's path). Nil where the title already says where.
    func subtitle(_ names: PinNames = .none) -> String? {
        switch status {
        case .missing: return String(localized: "Not found")
        case .workspaceMissing: return String(localized: "Workspace removed")
        case .unreadable where kind == .folders: return String(localized: "Oppi can\u{2019}t read this folder")
        case .unreadable: return String(localized: "Oppi can\u{2019}t read this file")
        case .ok, .unknown: break
        }
        func folders(_ path: String) -> [String] {
            (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        }
        func crumbs(_ parts: [String]) -> String { parts.joined(separator: " \u{203A} ") }
        let workspace = names.workspace ?? String(localized: "Workspace")
        switch target {
        case .hostFiles(let path?), .file(.host, let path, _):
            return crumbs([String(localized: "Home")] + folders(path).dropFirst())
        case .files(_, let path?):
            return crumbs([workspace] + folders(path))
        case .file(.workspace(_, let worktree), let path, _):
            return crumbs([worktree.map { "\(workspace) (\($0))" } ?? workspace] + folders(path))
        case .file(.session, let path, _):
            return crumbs([names.session ?? String(localized: "Session")] + folders(path))
        case .git(_, let worktree?):
            return worktree
        case .commit:
            return workspace
        case .panel:
            return names.session
        case .browser(let url):
            let path = url.path()
            return path.isEmpty || path == "/" ? nil : path
        default:
            return nil
        }
    }

    /// The pane entry this pin opens as: its route on its server.
    func paneEntry(serverId: String) -> PaneStackEntry {
        PaneStackEntry(serverId: serverId, route: target)
    }
}
