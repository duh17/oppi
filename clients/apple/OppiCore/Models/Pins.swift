import Foundation

// Pins: saved places, one list per server (`GET /pins`,
// `protocol/pins-http.json`): File Browser folders and files, and sessions.
// A pin names a place the app can already open; opening one goes through the
// same routes and locks.

/// Where a pin points: a path in a workspace's main checkout (`""` is its
/// root), in the server's home folder written `~` or `~/…`, or a session.
enum PinTarget: Hashable, Sendable, Codable {
    case workspace(id: String, path: String)
    case host(path: String)
    case session(id: String)

    private enum CodingKeys: String, CodingKey { case origin, workspaceId, path, sessionId }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .origin) {
        case "workspace":
            self = .workspace(id: try c.decode(String.self, forKey: .workspaceId), path: try c.decode(String.self, forKey: .path))
        case "host": self = .host(path: try c.decode(String.self, forKey: .path))
        case "session": self = .session(id: try c.decode(String.self, forKey: .sessionId))
        case let origin:
            throw DecodingError.dataCorruptedError(forKey: .origin, in: c, debugDescription: "unknown pin origin \(origin)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspace(let id, let path):
            try c.encode("workspace", forKey: .origin)
            try c.encode(id, forKey: .workspaceId)
            try c.encode(path, forKey: .path)
        case .host(let path):
            try c.encode("host", forKey: .origin)
            try c.encode(path, forKey: .path)
        case .session(let id):
            try c.encode("session", forKey: .origin)
            try c.encode(id, forKey: .sessionId)
        }
    }

    /// A folder or file's path; empty for a session, which has none.
    var path: String {
        switch self {
        case .workspace(_, let path), .host(let path): path
        case .session: ""
        }
    }

    var sessionId: String? {
        if case .session(let id) = self { return id }
        return nil
    }

    var workspaceId: String? {
        if case .workspace(let id, _) = self { return id }
        return nil
    }

    /// The last path component: the folder or file name, or "Home" for `~`;
    /// empty for a workspace root and a session, whose names live elsewhere.
    var name: String {
        let last = (path as NSString).lastPathComponent
        switch self {
        case .host where path == "~": return String(localized: "Home")
        case .workspace where path.isEmpty, .session: return ""
        default: return last
        }
    }
}

/// What the server found at a pin's target when it listed it. A status this
/// build does not know reads as `unknown`.
enum PinStatus: String, Hashable, Sendable, Decodable {
    case ok, missing, unreadable, workspaceMissing, unknown

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

struct Pin: Hashable, Sendable, Decodable, Identifiable {
    enum Kind: String, Hashable, Sendable, Decodable {
        case directory, file, session
    }

    let id: String
    let target: PinTarget
    let kind: Kind
    /// The name the person gave it; nil shows the target's own name.
    let label: String?
    let createdAt: Int64
    let status: PinStatus
}

/// `GET /pins` and `PUT /pins`; also the current list a 409 carries.
struct PinsList: Hashable, Sendable, Decodable {
    let revision: Int
    let pins: [Pin]
}

/// `POST /pins`: the list after the add and the added (or already saved) pin.
struct PinAddResult: Hashable, Sendable, Decodable {
    let revision: Int
    let pins: [Pin]
    let pinId: String
}

/// One entry of a `PUT /pins`: the pin, in its new place, with its label.
struct PinOrderEntry: Hashable, Sendable, Encodable {
    let id: String
    let label: String?
}

/// A `PUT /pins` whose `baseRevision` was stale: nothing changed, and this
/// is the server's list now.
struct PinsRevisionConflict: Error, Sendable {
    let current: PinsList
}
