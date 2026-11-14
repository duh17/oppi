import Foundation

// The Godot pane link, `WS /godot/{projectId}/link?role=player|follower`, and the command bodies of
// `POST /godot/{projectId}/commands`. Mirrors `server/src/types/godot.ts`; contract
// `protocol/godot.json` (`GodotProtocolContractTests`).

/// A point in the game view as fractions of its size, from the top-left; (0.5, 0.5) is the middle.
struct GodotPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
}

/// One input step; a player runs them in order, each after the last ends. `key` is a key name
/// (`Space`, `Enter`, `Left`, `A`, `F1`); `action` is an input action the project defines.
enum GodotInputStep: Codable, Sendable, Hashable {
    case tap(at: GodotPoint, holdMs: Double?)
    case drag(from: GodotPoint, to: GodotPoint, durationMs: Double?)
    case key(String, holdMs: Double?)
    case action(String, holdMs: Double?, strength: Double?)
    case wait(ms: Double)
    /// A step this build does not know; the player answers `unsupported`.
    case unsupported(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind, at, holdMs, from, to, durationMs, key, action, strength, ms
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "tap":
            self = .tap(at: try c.decode(GodotPoint.self, forKey: .at), holdMs: try c.decodeIfPresent(Double.self, forKey: .holdMs))
        case "drag":
            self = .drag(
                from: try c.decode(GodotPoint.self, forKey: .from),
                to: try c.decode(GodotPoint.self, forKey: .to),
                durationMs: try c.decodeIfPresent(Double.self, forKey: .durationMs)
            )
        case "key":
            self = .key(try c.decode(String.self, forKey: .key), holdMs: try c.decodeIfPresent(Double.self, forKey: .holdMs))
        case "action":
            self = .action(
                try c.decode(String.self, forKey: .action),
                holdMs: try c.decodeIfPresent(Double.self, forKey: .holdMs),
                strength: try c.decodeIfPresent(Double.self, forKey: .strength)
            )
        case "wait":
            self = .wait(ms: try c.decode(Double.self, forKey: .ms))
        default:
            self = .unsupported(kind: kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tap(let at, let holdMs):
            try c.encode("tap", forKey: .kind)
            try c.encode(at, forKey: .at)
            try c.encodeIfPresent(holdMs, forKey: .holdMs)
        case .drag(let from, let to, let durationMs):
            try c.encode("drag", forKey: .kind)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
        case .key(let key, let holdMs):
            try c.encode("key", forKey: .kind)
            try c.encode(key, forKey: .key)
            try c.encodeIfPresent(holdMs, forKey: .holdMs)
        case .action(let action, let holdMs, let strength):
            try c.encode("action", forKey: .kind)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(holdMs, forKey: .holdMs)
            try c.encodeIfPresent(strength, forKey: .strength)
        case .wait(let ms):
            try c.encode("wait", forKey: .kind)
            try c.encode(ms, forKey: .ms)
        case .unsupported(let kind):
            try c.encode(kind, forKey: .kind)
        }
    }
}

/// A command for a player. On the link it is the server's (a capture carries `captureId`); in
/// `GodotCommandRequest` a controller's (a capture leaves `captureId` out).
enum GodotCommand: Codable, Sendable, Hashable {
    /// Apply the current release again; `tier` asks for one.
    case reload(tier: GodotReloadTier?)
    /// Load and run a release (the current one when nil).
    case run(release: Int?)
    case stop
    case pause
    case resume
    case step(frames: Int?)
    /// Take a PNG of the game view, `PUT` it to `.../captures/{captureId}`, then answer.
    case capture(captureId: String?, maxSize: Int?)
    case input(steps: [GodotInputStep])
    /// The node drawn at a point.
    case pick(at: GodotPoint)
    case tree(path: String?, depth: Int?)
    case node(path: String)
    case perf
    /// A command this build does not know; the player answers `unsupported`.
    case unsupported(name: String)

    private enum CodingKeys: String, CodingKey {
        case name, tier, release, frames, captureId, maxSize, steps, at, path, depth
    }

    var name: String {
        switch self {
        case .reload: "reload"
        case .run: "run"
        case .stop: "stop"
        case .pause: "pause"
        case .resume: "resume"
        case .step: "step"
        case .capture: "capture"
        case .input: "input"
        case .pick: "pick"
        case .tree: "tree"
        case .node: "node"
        case .perf: "perf"
        case .unsupported(let name): name
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        switch name {
        case "reload": self = .reload(tier: try c.decodeIfPresent(GodotReloadTier.self, forKey: .tier))
        case "run": self = .run(release: try c.decodeIfPresent(Int.self, forKey: .release))
        case "stop": self = .stop
        case "pause": self = .pause
        case "resume": self = .resume
        case "step": self = .step(frames: try c.decodeIfPresent(Int.self, forKey: .frames))
        case "capture":
            self = .capture(
                captureId: try c.decodeIfPresent(String.self, forKey: .captureId),
                maxSize: try c.decodeIfPresent(Int.self, forKey: .maxSize)
            )
        case "input": self = .input(steps: try c.decode([GodotInputStep].self, forKey: .steps))
        case "pick": self = .pick(at: try c.decode(GodotPoint.self, forKey: .at))
        case "tree":
            self = .tree(path: try c.decodeIfPresent(String.self, forKey: .path), depth: try c.decodeIfPresent(Int.self, forKey: .depth))
        case "node": self = .node(path: try c.decode(String.self, forKey: .path))
        case "perf": self = .perf
        default: self = .unsupported(name: name)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        switch self {
        case .reload(let tier): try c.encodeIfPresent(tier, forKey: .tier)
        case .run(let release): try c.encodeIfPresent(release, forKey: .release)
        case .step(let frames): try c.encodeIfPresent(frames, forKey: .frames)
        case .capture(let captureId, let maxSize):
            try c.encodeIfPresent(captureId, forKey: .captureId)
            try c.encodeIfPresent(maxSize, forKey: .maxSize)
        case .input(let steps): try c.encode(steps, forKey: .steps)
        case .pick(let at): try c.encode(at, forKey: .at)
        case .tree(let path, let depth):
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(depth, forKey: .depth)
        case .node(let path): try c.encode(path, forKey: .path)
        case .stop, .pause, .resume, .perf, .unsupported: break
        }
    }
}

/// `no_player`, `timeout`, `player_left`, `unsupported`, `failed`, `invalid`, or `not_found`.
struct GodotErrorCode: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let noPlayer = Self(rawValue: "no_player")
    static let timeout = Self(rawValue: "timeout")
    static let playerLeft = Self(rawValue: "player_left")
    static let unsupported = Self(rawValue: "unsupported")
    static let failed = Self(rawValue: "failed")
    static let invalid = Self(rawValue: "invalid")
    static let notFound = Self(rawValue: "not_found")
}

struct GodotError: Codable, Sendable, Hashable, Error {
    var code: GodotErrorCode
    var message: String
}

/// `POST /godot/{projectId}/commands`.
struct GodotCommandRequest: Codable, Sendable, Hashable {
    var command: GodotCommand
    /// A player id; nil means the player that reported most recently.
    var player: String?
    var timeoutMs: Int?
}

/// A command's answer as a controller receives it. `output`'s shape follows `name`: decode it
/// as the matching `Godot…Output`.
struct GodotCommandResult: Codable, Sendable, Hashable {
    var id: String
    var name: String
    var playerId: String?
    var ok: Bool
    var output: JSONValue?
    var error: GodotError?
    var ms: Double
}

// MARK: - Command answers, by command

/// `reload`.
struct GodotReloadOutput: Codable, Sendable, Hashable {
    var release: Int
    var tier: GodotReloadTier
    var ms: Double?
}

/// `run`, `stop`, `pause`, `resume`.
struct GodotStateOutput: Codable, Sendable, Hashable {
    var state: GodotPlayerState
}

/// `step`.
struct GodotStepOutput: Codable, Sendable, Hashable {
    var frames: Int
}

/// `capture`.
struct GodotCaptureOutput: Codable, Sendable, Hashable {
    var captureId: String
    var mimeType: String
    var width: Int
    var height: Int
}

/// `input`.
struct GodotInputOutput: Codable, Sendable, Hashable {
    var steps: Int
    var ms: Double
}

/// A node in the running game.
struct GodotNode: Codable, Sendable, Hashable {
    /// Its scene tree path (`/root/Main/Player`).
    var path: String
    /// Its engine class.
    var type: String
    var name: String?
    var script: String?
    /// The scene file it was instanced from.
    var scene: String?
    /// Where code created it or last moved it.
    var source: GodotSourceLocation?
    var children: [GodotNode]?
}

/// `pick`.
struct GodotPickOutput: Codable, Sendable, Hashable {
    var node: GodotNode?
}

/// `tree`.
struct GodotTreeOutput: Codable, Sendable, Hashable {
    var root: GodotNode
}

/// `node`.
struct GodotNodeOutput: Codable, Sendable, Hashable {
    var node: GodotNode
    var properties: [String: JSONValue]?
}

/// `perf`.
struct GodotPerfOutput: Codable, Sendable, Hashable {
    var fps: Double
    var frameMs: Double?
    var processMs: Double?
    var physicsMs: Double?
    var drawCalls: Int?
    var nodes: Int?
    var memoryMB: Double?
}

// MARK: - Link messages

/// What a player sends. `attach` comes first and names `ClientCapability.godotPane`.
enum GodotLinkPlayerMessage: Codable, Sendable, Hashable {
    struct Attach: Codable, Sendable, Hashable {
        var capabilities: [String]
        var device: String?
        var runtimes: [GodotRuntimeInfo]
        var state: GodotPlayerState?
    }

    /// The answer to a `command`; `output` follows the command (see `GodotCommandResult`).
    struct Result: Codable, Sendable, Hashable {
        var id: String
        var ok: Bool
        var output: JSONValue?
        var error: GodotError?
    }

    case attach(Attach)
    case state(GodotPlayerState)
    case log([GodotLogInput])
    case result(Result)

    private enum CodingKeys: String, CodingKey { case type, state, entries }
    private enum Kind: String, Codable { case attach, state, log, result }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .attach: self = .attach(try Attach(from: decoder))
        case .state: self = .state(try c.decode(GodotPlayerState.self, forKey: .state))
        case .log: self = .log(try c.decode([GodotLogInput].self, forKey: .entries))
        case .result: self = .result(try Result(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attach(let attach):
            try c.encode(Kind.attach, forKey: .type)
            try attach.encode(to: encoder)
        case .state(let state):
            try c.encode(Kind.state, forKey: .type)
            try c.encode(state, forKey: .state)
        case .log(let entries):
            try c.encode(Kind.log, forKey: .type)
            try c.encode(entries, forKey: .entries)
        case .result(let result):
            try c.encode(Kind.result, forKey: .type)
            try result.encode(to: encoder)
        }
    }
}

/// What the server sends on a link. A player gets `attached`, `release`, `command`, and
/// `cancel`; a follower gets `attached`, `release`, `players`, and `log`. `error` precedes a close.
/// Either gets `auth_renew_result` after it sends `auth_renew` (`StreamAuthRenewal.requestFrame`):
/// a link opened with an expiring device token closes with `4001 auth_expired` 30 s after that
/// token expires unless it renews first.
enum GodotLinkServerMessage: Decodable, Sendable, Equatable {
    struct Attached: Decodable, Sendable, Hashable {
        /// `player` or `follower`.
        var role: String
        var playerId: String?
        var project: GodotProject
    }

    struct Command: Decodable, Sendable, Hashable {
        var id: String
        var command: GodotCommand
        var timeoutMs: Double
    }

    case attached(Attached)
    case release(GodotRelease)
    case command(Command)
    /// The command timed out on the server; stop working on it.
    case cancel(id: String)
    case players([GodotPlayer])
    case log([GodotLogEntry])
    case error(GodotError)
    /// The answer to this link's `auth_renew`.
    case authRenewResult(StreamAuthRenewResult)
    /// A message this build does not know; ignore it.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type, release, id, players, entries, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "attached": self = .attached(try Attached(from: decoder))
        case "release": self = .release(try c.decode(GodotRelease.self, forKey: .release))
        case "command": self = .command(try Command(from: decoder))
        case "cancel": self = .cancel(id: try c.decode(String.self, forKey: .id))
        case "players": self = .players(try c.decode([GodotPlayer].self, forKey: .players))
        case "log": self = .log(try c.decode([GodotLogEntry].self, forKey: .entries))
        case "error": self = .error(try c.decode(GodotError.self, forKey: .error))
        case "auth_renew_result": self = .authRenewResult(try StreamAuthRenewResult(from: decoder))
        default: self = .unknown(type: type)
        }
    }
}
