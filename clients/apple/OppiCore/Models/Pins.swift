import Foundation

// Pins: saved pane routes, one list per server (`GET /pins`,
// `protocol/pins-http.json`). A pin's target is any route a pane can show
// that has a link (`PaneRoute`, in the `protocol/links.json` route shape);
// opening one goes through the same path, routes, and locks as that link.

/// What the server found at a pin's target when it listed it, where it
/// checks (sessions, folders and files, workspaces, games). A status this
/// build does not know reads as `unknown`.
enum PinStatus: String, Hashable, Sendable, Decodable {
    case ok, missing, unreadable, workspaceMissing, unknown

    init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

struct Pin: Hashable, Sendable, Decodable, Identifiable {
    let id: String
    let target: PaneRoute
    /// The name the person gave it; nil shows the target's own name.
    let label: String?
    let createdAt: Int64
    let status: PinStatus
    /// A game pin's game name as the server read it; nil for other pins and
    /// a game that is gone.
    let name: String?
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
