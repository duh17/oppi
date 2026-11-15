import Foundation

// Godot pane v1: projects, releases, players, and logs as the server sends them under `/godot`.
// Mirrors `server/src/types/godot.ts`; contract `protocol/godot.json` (`GodotProtocolContractTests`).
// String vocabularies are open structs, so a value a newer server or player sends decodes instead
// of failing a whole list.

/// An engine name such as `godot`. The app picks its runtime by it.
struct GodotEngine: Codable, Sendable, Hashable {
    var name: String
    /// The version the project targets (`4.7`).
    var version: String?

    static let godotName = "godot"
}

/// `pck` (Godot's PCK, `GDPC` magic) or `zip`.
struct GodotPackFormat: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let pck = Self(rawValue: "pck")
    static let zip = Self(rawValue: "zip")
}

/// One stored pack. `sha256` (lowercase hex) is its id and its HTTP `ETag`.
struct GodotPack: Codable, Sendable, Hashable {
    var sha256: String
    var size: Int
    var format: GodotPackFormat
}

/// Where a game starts; both fields go to the engine as they are.
struct GodotEntry: Codable, Sendable, Hashable {
    /// An engine path (`res://main.tscn`); nil means the project's main scene.
    var scene: String?
    var args: [String]?
}

/// How a release is applied, fastest first. A release carries it as a hint; the player decides
/// by what changed and reports the tier it used.
///
/// - `scripts`: reload changed scripts in the running game; everything is kept.
/// - `scene`: mount the new packs into the running engine and reload the current scene.
/// - `restart`: needs a fresh engine; the player ends the game's engine and starts it again.
struct GodotReloadTier: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let scripts = Self(rawValue: "scripts")
    static let scene = Self(rawValue: "scene")
    static let restart = Self(rawValue: "restart")
}

/// A playable build of one project. Immutable; `seq` is its id within the project.
struct GodotRelease: Codable, Sendable, Hashable {
    var v: Int
    var seq: Int
    /// Unix milliseconds.
    var createdAt: Double
    /// `discovery` (a pack found in a workspace) or `publish`.
    var origin: String
    var engine: GodotEngine
    /// Base first, then patches; mount in this order.
    var packs: [GodotPack]
    var entry: GodotEntry?
    var reload: GodotReloadTier
    var label: String?
}

/// Where a discovered project lives; paths are relative to the checkout.
struct GodotProjectSource: Codable, Sendable, Hashable {
    var workspaceId: String
    /// `main`, or a worktree id.
    var worktreeId: String
    var checkout: String
    /// The project folder; empty for the checkout itself.
    var root: String
    /// The pack discovery watches.
    var pack: String?
}

/// A game the server knows. `release` nil means "No build yet".
struct GodotProject: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var engine: GodotEngine
    /// Nil for a project only a publish created.
    var source: GodotProjectSource?
    var release: GodotRelease?
    /// Attached players, newest first.
    var players: [GodotPlayer]
}

/// `GET /godot`.
struct GodotProjectList: Codable, Sendable, Hashable {
    var projects: [GodotProject]
}

/// `GET /godot/{projectId}`: the project's fields with its kept releases and log cursor.
struct GodotProjectDetail: Codable, Sendable, Hashable {
    var project: GodotProject
    /// Newest first, at most five.
    var releases: [GodotRelease]
    /// `since` for `GET .../logs` to read only what comes next.
    var logNext: Int

    private enum CodingKeys: String, CodingKey { case releases, logNext }

    init(project: GodotProject, releases: [GodotRelease], logNext: Int) {
        self.project = project
        self.releases = releases
        self.logNext = logNext
    }

    init(from decoder: Decoder) throws {
        project = try GodotProject(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        releases = try container.decode([GodotRelease].self, forKey: .releases)
        logNext = try container.decode(Int.self, forKey: .logNext)
    }

    func encode(to encoder: Encoder) throws {
        try project.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(releases, forKey: .releases)
        try container.encode(logNext, forKey: .logNext)
    }
}

// MARK: - Players

/// An engine build a player carries.
struct GodotRuntimeInfo: Codable, Sendable, Hashable {
    var engine: String
    var version: String?
    var formats: [GodotPackFormat]
}

/// The game view in points; `scale` is pixels per point.
struct GodotViewport: Codable, Sendable, Hashable {
    var width: Double
    var height: Double
    var scale: Double?
}

/// `idle`, `loading`, `running`, `paused`, or `error`.
struct GodotPhase: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let idle = Self(rawValue: "idle")
    static let loading = Self(rawValue: "loading")
    static let running = Self(rawValue: "running")
    static let paused = Self(rawValue: "paused")
    static let error = Self(rawValue: "error")
}

struct GodotPlayerState: Codable, Sendable, Hashable {
    var phase: GodotPhase
    /// The release loaded (`seq`).
    var release: Int?
    /// The tier used to apply `release`.
    var tier: GodotReloadTier?
    var fps: Double?
    var viewport: GodotViewport?
    var message: String?
}

/// A player as controllers see it.
struct GodotPlayer: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var device: String?
    var runtimes: [GodotRuntimeInfo]
    var attachedAt: Double
    var state: GodotPlayerState
    var stateAt: Double
}

// MARK: - Logs

struct GodotLogLevel: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let debug = Self(rawValue: "debug")
    static let info = Self(rawValue: "info")
    static let warn = Self(rawValue: "warn")
    static let error = Self(rawValue: "error")
}

/// A place in game code; `file` is an engine path (`res://player.gd`).
struct GodotSourceLocation: Codable, Sendable, Hashable {
    var file: String
    var line: Int?
    var function: String?
}

/// One log line as a player sends it.
struct GodotLogInput: Codable, Sendable, Hashable {
    var level: GodotLogLevel
    var message: String
    var source: GodotSourceLocation?
    /// Innermost first.
    var backtrace: [GodotSourceLocation]?
}

/// One entry of a project's log ring.
struct GodotLogEntry: Codable, Sendable, Hashable {
    var seq: Int
    var at: Double
    /// `player` or `server` (releases, attaches, command timeouts).
    var origin: String
    var playerId: String?
    var level: GodotLogLevel
    var message: String
    var source: GodotSourceLocation?
    var backtrace: [GodotSourceLocation]?
}

/// `GET /godot/{projectId}/logs?since=`.
struct GodotLogPage: Codable, Sendable, Hashable {
    var entries: [GodotLogEntry]
    var next: Int
    /// Entries after `since` the ring no longer holds.
    var dropped: Int
}

// MARK: - Captures

/// `PUT /godot/{projectId}/captures/{captureId}`.
struct GodotCapture: Codable, Sendable, Hashable {
    var id: String
    var mimeType: String
    var size: Int
    var createdAt: Double
}
