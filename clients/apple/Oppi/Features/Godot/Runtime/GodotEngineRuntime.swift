import QuartzCore
import UIKit

/// What the engine needs to start a game: its packs on disk (base first),
/// the game's own folder for `user://`, and the engine's cache.
struct GodotStartConfig {
    var packs: [URL]
    var userFolder: URL
    var cacheFolder: URL
    /// Folders the game may read but never write (system fonts).
    var readableFolders: [URL]
    /// Engine arguments after the pack (a scene, `--` and the game's own).
    var arguments: [String]
}

/// The frame numbers an engine reports, for the perf strip and frame waits.
struct GodotPerf: Hashable, Sendable {
    var fps: Double = 0
    var processMilliseconds: Double = 0
    var drawCalls = 0
    var nodes = 0
    var framesDrawn: Int64 = 0
}

/// A touch phase as the engine takes it.
enum GodotTouchPhase: Sendable {
    case began, moved, ended, cancelled
}

/// The engine-neutral surface the host drives (design §5): one engine at a
/// time, on the main thread; `stop` ends it, and `start` may follow on
/// another game. `GodotRuntime` is the one implementation;
/// an app built without the engine has none (`GodotRuntimes.make`).
@MainActor
protocol GodotEngineRuntime: AnyObject {
    /// Log lines from any thread, delivered on the main actor.
    var onLog: ((GodotEngineLog) -> Void)? { get set }
    /// The layer the engine draws its own sublayer into; set before `start`.
    func attach(to layer: CALayer)
    /// The container's size in points and its scale.
    func resize(to size: CGSize, scale: CGFloat)
    func start(_ config: GodotStartConfig) -> Bool
    /// Ends the running engine and takes its view off the layer.
    func stop()
    /// One frame; false once the game asked to quit.
    func iterate() -> Bool
    /// Draws the current scene again without running the game: a paused
    /// game at a new size. Only while the app may draw.
    func redraw()
    func pause()
    func resume()
    func focus(_ focused: Bool)
    func setMuted(_ muted: Bool)
    /// Mounts a pack over the running game.
    func mount(_ pack: URL) -> Bool
    /// Reloads scripts in place, keeping state; the count reloaded, or -1
    /// when the engine cannot.
    func reloadScripts(_ resources: [String]) -> Int
    /// Mounts `pack` and reloads the scene (`scene`, else the main scene).
    func swap(to pack: URL, scene: String?) -> Bool
    func reloadScene() -> Bool
    /// `index` names one finger from began to ended; points in the container.
    func touch(index: Int, phase: GodotTouchPhase, at point: CGPoint, from previous: CGPoint, pressure: Float, doubleTap: Bool)
    func key(_ key: UIKey, pressed: Bool)
    /// A key by Godot's name (`Space`, `Left`, `A`); false for an unknown name.
    func key(named name: String, pressed: Bool) -> Bool
    /// A project input action; false when the project has none by that name.
    func action(_ name: String, pressed: Bool, strength: Float) -> Bool
    /// The current frame as PNG; nil while nothing is drawn.
    func capturePNG() -> Data?
    func perf() -> GodotPerf
    /// The current scene's file (`res://…`); nil while none is loaded from one.
    func currentScene() -> String?
}

/// Whether this device offers the Godot pane now: its experiment is on, in a
/// build with the engine (`PlatformCapabilities.godotPane`).
enum GodotPaneAvailability {
    static var isOn: Bool {
        AppPreferenceStore.Experiments.godotPaneEnabled && PlatformCapabilities.godotPane
    }
}

@MainActor
enum GodotRuntimes {
    /// This build's engine, or nil when the app was built without one
    /// (`scripts/install-oppi-godot.sh` found no engine build).
    static func make() -> (any GodotEngineRuntime)? {
        #if canImport(OppiGodot)
        GodotRuntime()
        #else
        nil
        #endif
    }
}
