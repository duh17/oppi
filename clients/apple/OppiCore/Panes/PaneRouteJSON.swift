import Foundation

/// A linkable route as a JSON object, the shape `protocol/links.json` decodes
/// `oppi://` links to and a pin stores (`protocol/pins-http.json`):
/// `{ "kind": "git", "workspace": "ws-1", "worktree": null }`. Every field
/// of a kind is written, `null` where the link leaves it out. A `.local` or
/// `.unsupported` route has no link and does not encode.
extension PaneRoute: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, workspace, worktree, origin, session, path, line, sha, url, project
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) throws -> String { try c.decode(String.self, forKey: key) }
        func optional(_ key: CodingKeys) throws -> String? { try c.decodeIfPresent(String.self, forKey: key) }
        switch try string(.kind) {
        case "sessions": self = .sessions(workspace: try optional(.workspace))
        case "session": self = .session(try string(.id))
        case "thread": self = .thread(try string(.id))
        case "file":
            let origin: PaneFileOrigin = switch try string(.origin) {
            case "workspace": .workspace(id: try string(.workspace), worktree: try optional(.worktree))
            case "host": .host
            case "session": .session(try string(.session))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .origin, in: c, debugDescription: "unknown file origin \(other)")
            }
            self = .file(origin, path: try string(.path), line: try c.decodeIfPresent(Int.self, forKey: .line))
        case "files" where try optional(.origin) == "host": self = .hostFiles(path: try optional(.path))
        case "files": self = .files(workspace: try string(.workspace), path: try optional(.path))
        case "git": self = .git(workspace: try string(.workspace), worktree: try optional(.worktree))
        case "commit": self = .commit(workspace: try string(.workspace), sha: try string(.sha))
        case "panel": self = .panel(session: try string(.session), id: try string(.id))
        case "read": self = .read(session: try string(.session), url: try string(.url))
        case "browser":
            guard let url = URL(string: try string(.url)) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not a URL")
            }
            self = .browser(url)
        case "godot": self = .godot(project: try string(.project))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown route kind \(kind)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func nullable(_ value: String?, _ key: CodingKeys) throws {
            if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
        }
        switch self {
        case .sessions(let workspace):
            try c.encode("sessions", forKey: .kind)
            try nullable(workspace, .workspace)
        case .session(let id), .thread(let id):
            try c.encode(isThread ? "thread" : "session", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .file(let origin, let path, let line):
            try c.encode("file", forKey: .kind)
            switch origin {
            case .workspace(let id, let worktree):
                try c.encode("workspace", forKey: .origin)
                try c.encode(id, forKey: .workspace)
                try nullable(worktree, .worktree)
            case .host:
                try c.encode("host", forKey: .origin)
            case .session(let session):
                try c.encode("session", forKey: .origin)
                try c.encode(session, forKey: .session)
            }
            try c.encode(path, forKey: .path)
            if let line { try c.encode(line, forKey: .line) } else { try c.encodeNil(forKey: .line) }
        case .files(let workspace, let path):
            try c.encode("files", forKey: .kind)
            try c.encode(workspace, forKey: .workspace)
            try nullable(path, .path)
        case .hostFiles(let path):
            try c.encode("files", forKey: .kind)
            try c.encode("host", forKey: .origin)
            try nullable(path, .path)
        case .git(let workspace, let worktree):
            try c.encode("git", forKey: .kind)
            try c.encode(workspace, forKey: .workspace)
            try nullable(worktree, .worktree)
        case .commit(let workspace, let sha):
            try c.encode("commit", forKey: .kind)
            try c.encode(workspace, forKey: .workspace)
            try c.encode(sha, forKey: .sha)
        case .panel(let session, let id):
            try c.encode("panel", forKey: .kind)
            try c.encode(session, forKey: .session)
            try c.encode(id, forKey: .id)
        case .read(let session, let url):
            try c.encode("read", forKey: .kind)
            try c.encode(session, forKey: .session)
            try c.encode(url, forKey: .url)
        case .browser(let url):
            try c.encode("browser", forKey: .kind)
            try c.encode(url.absoluteString, forKey: .url)
        case .godot(let project):
            try c.encode("godot", forKey: .kind)
            try c.encode(project, forKey: .project)
        case .local, .unsupported:
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "a route with no link"))
        }
    }

    private var isThread: Bool {
        if case .thread = self { return true }
        return false
    }
}
