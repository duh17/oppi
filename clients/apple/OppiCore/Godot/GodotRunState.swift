import Foundation

/// What the server says of a Godot pane's project.
enum GodotProjectStatus: Hashable, Sendable {
    /// Not heard from the server yet.
    case connecting
    /// The server has no project by this id.
    case missing
    /// Discovered, with no exported pack yet.
    case noBuild
    /// A release is current.
    case build
}

/// What a pane is waiting for while it loads.
enum GodotLoadStep: Hashable, Sendable {
    case fetching
    case starting
}

/// What a Godot pane shows (design §9). The engine is app-wide and runs one
/// game per launch; a pane shows its own project's place in that.
enum GodotPanePhase: Hashable, Sendable {
    case connecting
    case missing
    case noBuild
    case loading(GodotLoadStep)
    /// Not started yet (a pane a relaunch restored): Play starts it.
    case ready
    case running
    case paused
    /// Another pane shows this game: Play Here moves it.
    case elsewhere
    case needsRelaunch(GodotRelaunchReason)
    case refused(GodotPackRefusal)
    /// Fetching or starting failed; the message says why.
    case failed(String)

    /// The phase of a pane showing `slot`. Pure: the pane passes what it
    /// knows. `plan` is how its current release would apply, nil until its
    /// packs are read; `holdsSurface` whether this pane has the game's view.
    static func resolve(
        slot: GodotSlot,
        project: GodotProjectStatus,
        plan: GodotApplyPlan?,
        engine: GodotEngineState,
        holdsSurface: Bool,
        loading: GodotLoadStep?,
        paused: Bool,
        failure: String?
    ) -> Self {
        if case .refuse(let refusal)? = plan { return .refused(refusal) }
        switch engine {
        case .starting(let starting) where starting == slot:
            return holdsSurface ? .loading(.starting) : .elsewhere
        case .starting:
            return .needsRelaunch(.otherGame)
        case .running(let running) where running == slot:
            // The game keeps playing whatever its project now says; a build
            // it cannot take shows as a notice (`relaunchNotice`).
            guard holdsSurface else { return .elsewhere }
            if let loading { return .loading(loading) }
            if let failure { return .failed(failure) }
            return paused ? .paused : .running
        case .running:
            return .needsRelaunch(.otherGame)
        case .stopped:
            // The pane that started it says why; the engine cannot start again.
            if holdsSurface, let failure { return .failed(failure) }
            return .needsRelaunch(.engineStopped)
        case .idle:
            if let failure { return .failed(failure) }
            switch project {
            case .connecting: return .connecting
            case .missing: return .missing
            case .noBuild: return .noBuild
            case .build: return loading.map(Self.loading) ?? .ready
            }
        }
    }

    /// The relaunch a running game's newer build waits for, if any: the game
    /// plays on with the build it has.
    static func relaunchNotice(plan: GodotApplyPlan?, engine: GodotEngineState, slot: GodotSlot) -> GodotRelaunchReason? {
        guard case .running(let running) = engine, running == slot,
              case .relaunch(let reason)? = plan else { return nil }
        return reason
    }
}

/// One line of the engine's log, as the pane and the log ring keep it.
struct GodotEngineLog: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case print, error, warning, script, shader
    }

    let kind: Kind
    let message: String
    /// Where the engine raised it (its own C++ source for `push_error`).
    let file: String
    let line: Int
    let function: String
    /// The first script frame, when the error carried a script backtrace.
    let scriptFile: String
    let scriptLine: Int
    let backtrace: String

    /// The game's own location for this entry: the script frame, else the
    /// raised-at location when it is the game's file.
    var location: (file: String, line: Int)? {
        if !scriptFile.isEmpty { return (scriptFile, scriptLine) }
        if file.hasPrefix("res://") { return (file, line) }
        return nil
    }

    /// The line as a player sends it on the Godot link: the game's own
    /// location as its source, and the script backtrace's frames.
    var linkEntry: GodotLogInput {
        let level: GodotLogLevel = switch kind {
        case .print: .info
        case .warning: .warn
        case .error, .script, .shader: .error
        }
        let source = location.map { GodotSourceLocation(file: $0.file, line: $0.line, function: function.isEmpty ? nil : function) }
        let frames = Self.frames(in: backtrace)
        return GodotLogInput(level: level, message: message, source: source, backtrace: frames.isEmpty ? nil : frames)
    }

    /// Godot formats a script backtrace one frame a line, innermost first:
    /// `[0] _ready (res://main.gd:12)`.
    static func frames(in backtrace: String) -> [GodotSourceLocation] {
        backtrace.split(separator: "\n").compactMap { line in
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return nil }
            let place = line[line.index(after: open)..<close]
            guard let colon = place.lastIndex(of: ":"), let number = Int(place[place.index(after: colon)...]) else { return nil }
            let head = line[..<open].trimmingCharacters(in: .whitespaces)
            let function = head.split(separator: " ").last.map(String.init)
            return GodotSourceLocation(file: String(place[..<colon]), line: number, function: function)
        }
    }

    /// An error the pane shows over the game: one the game's own code
    /// raised. The engine's notes about itself go to the log only.
    var isGameError: Bool {
        switch kind {
        case .print, .warning: false
        case .error, .script, .shader: location != nil
        }
    }
}
