import Foundation

// Plugin screens: sidebar entries a server's built-in plugins add, each drawn by the app's one
// generic list screen from a page the server watches for it (`WS /screens/stream`).
// Mirrors `server/src/types/screens.ts`; contract `protocol/screens.json`
// (`PluginScreenProtocolTests`). The vocabulary is closed: seven row kinds and a page around
// them, versioned as one integer.

enum PluginScreens {
    /// The vocabulary this app draws (`capabilities.screens.v`).
    static let version = 1
}

/// A sidebar entry as `/server/info` lists it.
struct PluginScreenSidebarEntry: Codable, Sendable, Equatable, Hashable {
    let id: String
    let title: String
    /// An SF Symbol from the server's surface icon allow-list.
    let icon: String
    let order: Double
    /// `server`: a sidebar row. `workspace`: the same screen for one host workspace
    /// (`workspace:<id>`), opened from Workspace Settings by `feature`.
    let scopes: [String]
    /// The server switch (`ServerFeature` raw value) the entry belongs to.
    var feature: String?
}

/// One page of a plugin screen.
struct PluginScreenPage: Decodable, Sendable, Equatable {
    struct State: Decodable, Sendable, Equatable {
        /// `loading`, `empty`, or `failed` (with Retry).
        let kind: String
        var title: String?
        var message: String?
    }

    struct BarItem: Decodable, Sendable, Equatable {
        let id: String
        let title: String
        var symbol: String?
        var action: String?
        var push: String?
        var present: String?
        var disabled: Bool?
    }

    struct Section: Decodable, Sendable, Equatable {
        struct When: Decodable, Sendable, Equatable {
            let field: String
            let `is`: String
        }

        let id: String
        var header: String?
        /// The app adds its own name for the server to the header.
        var namesHost: Bool?
        var footer: String?
        let rows: [PluginScreenRow]
        var when: When?
    }

    struct Submit: Decodable, Sendable, Equatable {
        let title: String
        let action: String
        /// Fields that must be filled, among the shown sections, before Submit turns on.
        var requires: [String]?
    }

    let title: String
    var state: State?
    var bar: [BarItem]?
    let sections: [Section]
    var submit: Submit?
}

/// One row. A flat shape for all seven kinds (`item`, `value`, `text`, `toggle`, `choice`,
/// `button`, `field`); each kind reads its own fields. A kind this app does not know decodes
/// and draws as a notice to update the app.
struct PluginScreenRow: Decodable, Sendable, Equatable, Hashable {
    struct Status: Decodable, Sendable, Equatable, Hashable {
        let text: String
        var symbol: String?
        var tone: String?
    }

    struct Option: Decodable, Sendable, Equatable, Hashable {
        let value: String
        let title: String
        /// Leads the section's footer while this option is chosen.
        var footer: String?
    }

    struct Confirm: Decodable, Sendable, Equatable, Hashable {
        let title: String
        var message: String?
        let button: String
    }

    let kind: String
    let id: String
    var title: String?
    var subtitle: String?
    var status: Status?
    var push: String?
    var url: String?
    var label: String?
    /// A string for `value`, `choice` and `field`; a bool for `toggle`.
    var value: JSONValue?
    var mono: Bool?
    var text: String?
    var style: String?
    var tone: String?
    var selectable: Bool?
    var action: String?
    var disabled: Bool?
    var options: [Option]?
    var role: String?
    var confirm: Confirm?
    var placeholder: String?
    var input: String?

    var stringValue: String? {
        if case .string(let text) = value { return text }
        return nil
    }

    var boolValue: Bool {
        if case .bool(let flag) = value { return flag }
        return false
    }
}

/// What an action asks the app to do next: pop this page, push another, or present one.
struct PluginScreenNav: Codable, Sendable, Equatable {
    let kind: String
    var page: String?
}

/// A draft value or a toggle's new state, by row id.
struct PluginScreenValue: Codable, Sendable, Equatable {
    let field: String
    let value: JSONValue
}

enum PluginScreenClientMessage: Encodable, Equatable {
    case watch(watch: String, entry: String, scope: String, page: String)
    case unwatch(watch: String)
    case act(watch: String, call: String, action: String, row: String?, values: [PluginScreenValue]?)

    private enum Keys: String, CodingKey { case type, watch, entry, scope, page, v, call, action, row, values }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .watch(watch, entry, scope, page):
            try container.encode("watch", forKey: .type)
            try container.encode(watch, forKey: .watch)
            try container.encode(entry, forKey: .entry)
            try container.encode(scope, forKey: .scope)
            try container.encode(page, forKey: .page)
            try container.encode(PluginScreens.version, forKey: .v)
        case let .unwatch(watch):
            try container.encode("unwatch", forKey: .type)
            try container.encode(watch, forKey: .watch)
        case let .act(watch, call, action, row, values):
            try container.encode("act", forKey: .type)
            try container.encode(watch, forKey: .watch)
            try container.encode(call, forKey: .call)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(row, forKey: .row)
            try container.encodeIfPresent(values, forKey: .values)
        }
    }
}

enum PluginScreenServerMessage: Decodable {
    case value(watch: String, value: JSONValue)
    case ops(watch: String, ops: [ConversationDocOp])
    /// The page's new value was refused; the app keeps the last one.
    case failed(watch: String, message: String)
    /// `gone`, `off`, or `unsupported`.
    case ended(watch: String, reason: String)
    case result(call: String, ok: Bool, message: String?, nav: PluginScreenNav?)
    case authRenewResult(StreamAuthRenewResult)
    case unknown

    private enum Keys: String, CodingKey { case type, watch, value, ops, message, reason, call, ok, nav }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let watch = { try container.decode(String.self, forKey: .watch) }
        switch try container.decode(String.self, forKey: .type) {
        case "value": self = .value(watch: try watch(), value: try container.decode(JSONValue.self, forKey: .value))
        case "ops": self = .ops(watch: try watch(), ops: try container.decode([ConversationDocOp].self, forKey: .ops))
        case "failed": self = .failed(watch: try watch(), message: try container.decode(String.self, forKey: .message))
        case "ended": self = .ended(watch: try watch(), reason: try container.decode(String.self, forKey: .reason))
        case "result":
            self = .result(
                call: try container.decode(String.self, forKey: .call),
                ok: try container.decode(Bool.self, forKey: .ok),
                message: try container.decodeIfPresent(String.self, forKey: .message),
                nav: try container.decodeIfPresent(PluginScreenNav.self, forKey: .nav)
            )
        case "auth_renew_result": self = .authRenewResult(try StreamAuthRenewResult(from: decoder))
        default: self = .unknown
        }
    }
}

/// The app's copy of one watched page: the first value, then each ops frame applied to it in
/// order (`ChordDelta`, as the conversation replica does). A frame that does not apply leaves the
/// copy unfaithful: watch again for a fresh value.
struct PluginScreenReplica: Equatable {
    private(set) var document: JSONValue?

    /// Applies a `value` or `ops` frame and returns the page it leaves.
    mutating func apply(_ message: PluginScreenServerMessage) throws -> PluginScreenPage? {
        switch message {
        case .value(_, let value):
            document = value
        case .ops(_, let ops):
            try ChordDelta.apply(ops, to: &document)
        default:
            return nil
        }
        guard let document else { return nil }
        return try JSONDecoder().decode(PluginScreenPage.self, from: JSONEncoder().encode(document))
    }
}
