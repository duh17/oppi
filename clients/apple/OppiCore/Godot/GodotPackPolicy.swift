import Foundation

/// The game the app's one engine runs: a project on a server.
struct GodotSlot: Hashable, Sendable {
    let serverId: String
    let project: String
}


/// Why a build cannot run until the app relaunches. Godot 4.7 starts once per
/// process and cannot start again (its class registration is static), so the
/// engine keeps the first game's project settings and autoloads for life.
enum GodotRelaunchReason: Hashable, Sendable {
    /// The engine runs another game this launch.
    case otherGame
    /// The build changed project settings, autoloads or global classes.
    case projectSettings
    /// The game quit, or failed to start; the engine cannot start again.
    case engineStopped
}

/// A pack the player will not hand the engine.
enum GodotPackRefusal: Hashable, Sendable {
    /// Native code, a .NET assembly or a GDExtension: Oppi runs GDScript only.
    case nativeCode(path: String)
    /// Exported by a newer Godot than the app's engine.
    case newerEngine(GodotEngineVersion)
}

/// How a release reaches the engine.
enum GodotApplyPlan: Hashable, Sendable {
    /// The first game this launch: start the engine on it.
    case start
    /// Same files as the engine has.
    case unchanged
    /// Only existing scripts changed: reload them in place, keeping state.
    /// `res://` paths.
    case scripts([String])
    /// Mount the packs over the running game and reload its scene.
    case scene
    case relaunch(GodotRelaunchReason)
    case refuse(GodotPackRefusal)

    /// The tier a player reports for this plan (`protocol/godot.json`): a
    /// relaunch is the restart tier; a first start, no change and a refusal
    /// report none.
    var tier: GodotReloadTier? {
        switch self {
        case .scripts: .scripts
        case .scene: .scene
        case .relaunch: .restart
        case .start, .unchanged, .refuse: nil
        }
    }
}

/// What the engine has mounted, as the player last applied it.
struct GodotLoadedBuild: Hashable, Sendable {
    let slot: GodotSlot
    /// Every file the mounted packs give the game, later packs over earlier.
    var files: [String: Data]
}

/// Decides how a new release of a game reaches the one engine (design §7,
/// with the spike's finding that the engine starts once per launch). Pure.
enum GodotPackPolicy {
    /// The engine the app links; a pack from a newer Godot is refused.
    static let engineVersion = GodotEngineVersion(major: 4, minor: 7)

    /// Files whose change needs a fresh engine: project settings (autoloads
    /// live there) and the global class list.
    static let settingsFiles: Set<String> = ["project.binary", "project.godot", ".godot/global_script_class_cache.cfg"]

    /// The files `packs` give the game, base first: a later pack replaces a
    /// file, and a patch's removal drops it.
    static func merged(_ packs: [GodotPackIndex]) -> [String: Data] {
        var files: [String: Data] = [:]
        for pack in packs {
            for (path, digest) in pack.files {
                files[path] = digest
            }
        }
        return files
    }

    static func plan(
        slot: GodotSlot,
        packs: [GodotPackIndex],
        hint: GodotReloadTier,
        loaded: GodotLoadedBuild?,
        engine: GodotEngineState
    ) -> GodotApplyPlan {
        for pack in packs {
            if let path = pack.refusedFile { return .refuse(.nativeCode(path: path)) }
            if let version = pack.engineVersion, version > engineVersion { return .refuse(.newerEngine(version)) }
        }
        switch engine {
        case .idle:
            return .start
        case .starting(let starting):
            // The engine is coming up on a build of this game: the next build
            // waits for it, and another game for a relaunch.
            return starting == slot ? .unchanged : .relaunch(.otherGame)
        case .stopped:
            return .relaunch(.engineStopped)
        case .running(let running):
            guard running == slot, let loaded, loaded.slot == slot else { return .relaunch(.otherGame) }
            let files = merged(packs)
            let changed = Set(files.keys).union(loaded.files.keys).filter { files[$0] != loaded.files[$0] }
            if changed.isEmpty { return .unchanged }
            if !changed.isDisjoint(with: settingsFiles) { return .relaunch(.projectSettings) }
            let existingScriptsOnly = changed.allSatisfy { path in
                isScript(path) && loaded.files[path] != nil && files[path] != nil
            }
            if hint != .restart, existingScriptsOnly {
                return .scripts(Set(changed.map(scriptResource)).sorted())
            }
            return .scene
        }
    }

    /// GDScript source or its exported binary tokens.
    static func isScript(_ path: String) -> Bool {
        path.hasSuffix(".gd") || path.hasSuffix(".gdc")
    }

    /// The script resource a file belongs to: an exported `.gdc` loads as its `.gd`.
    private static func scriptResource(_ path: String) -> String {
        let source = path.hasSuffix(".gdc") ? String(path.dropLast()) : path
        return "res://" + source
    }
}

/// The app's one engine over a launch: never started, starting or running one
/// game, or stopped for good (Godot 4.7 cannot start a second time in a process).
enum GodotEngineState: Hashable, Sendable {
    case idle
    case starting(GodotSlot)
    case running(GodotSlot)
    case stopped
}
