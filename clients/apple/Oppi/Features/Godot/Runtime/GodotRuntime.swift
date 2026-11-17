#if canImport(OppiGodot)
internal import OppiGodot
import QuartzCore
import UIKit

/// `GodotEngineRuntime` over Oppi's Godot build (`engine/godot`, C API in
/// `OppiGodot.h`). One engine at a time: `stop` ends it, and `start` makes
/// the next one, on any game (patch 0005 lets Godot start again in a process).
@MainActor
final class GodotRuntime: GodotEngineRuntime {
    var onLog: ((GodotEngineLog) -> Void)? {
        didSet { GodotLogRelay.shared.onLog = onLog }
    }

    init() {
        oppigodot_set_log_callback(godotLogCallback, nil)
    }

    func attach(to layer: CALayer) {
        oppigodot_set_layer(Unmanaged.passUnretained(layer).toOpaque())
    }

    func resize(to size: CGSize, scale: CGFloat) {
        oppigodot_resize(size.width, size.height, scale)
    }

    func start(_ config: GodotStartConfig) -> Bool {
        guard let base = config.packs.first else { return false }
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ string: String) -> UnsafePointer<CChar>? {
            guard let pointer = strdup(string) else { return nil }
            owned.append(pointer)
            return UnsafePointer(pointer)
        }
        let arguments = config.arguments.map(c)
        let readable = config.readableFolders.map { c($0.path) }
        let started = arguments.withUnsafeBufferPointer { argumentBuffer in
            readable.withUnsafeBufferPointer { readableBuffer in
                var start = OppiGodotConfig()
                start.pack_path = c(base.path)
                start.user_dir = c(config.userFolder.path)
                start.cache_dir = c(config.cacheFolder.path)
                start.extra_args = argumentBuffer.baseAddress
                start.extra_arg_count = Int32(arguments.count)
                start.readable_dirs = readableBuffer.baseAddress
                start.readable_dir_count = Int32(readable.count)
                start.allow_network = false
                return oppigodot_start(&start)
            }
        }
        guard started else { return false }
        for patch in config.packs.dropFirst() where !mount(patch) {
            return false
        }
        return true
    }

    func stop() { oppigodot_stop() }
    func iterate() -> Bool { oppigodot_iterate() }
    func redraw() { oppigodot_redraw() }
    func pause() { oppigodot_pause() }
    func resume() { oppigodot_resume() }
    func focus(_ focused: Bool) { oppigodot_focus(focused) }
    func setMuted(_ muted: Bool) { oppigodot_set_muted(muted) }
    func mount(_ pack: URL) -> Bool { oppigodot_mount_pack(pack.path, true) }

    func reloadScripts(_ resources: [String]) -> Int {
        let owned = resources.compactMap { strdup($0) }
        defer { owned.forEach { free($0) } }
        let paths: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        return paths.withUnsafeBufferPointer { buffer in
            Int(oppigodot_reload_scripts(buffer.baseAddress, Int32(buffer.count)))
        }
    }

    func swap(to pack: URL, scene: String?) -> Bool {
        oppigodot_swap_pack(pack.path, scene)
    }

    func reloadScene() -> Bool { oppigodot_reload_scene() }

    func touch(index: Int, phase: GodotTouchPhase, at point: CGPoint, from previous: CGPoint, pressure: Float, doubleTap: Bool) {
        let godotPhase: OppiGodotTouchPhase = switch phase {
        case .began: OPPIGODOT_TOUCH_BEGAN
        case .moved: OPPIGODOT_TOUCH_MOVED
        case .ended: OPPIGODOT_TOUCH_ENDED
        case .cancelled: OPPIGODOT_TOUCH_CANCELLED
        }
        oppigodot_touch(Int32(index), godotPhase, point.x, point.y, previous.x, previous.y, pressure, doubleTap)
    }

    func key(_ key: UIKey, pressed: Bool) {
        oppigodot_key(
            Int64(key.keyCode.rawValue), key.characters, key.charactersIgnoringModifiers,
            Int64(key.modifierFlags.rawValue), pressed
        )
    }

    func key(named name: String, pressed: Bool) -> Bool {
        oppigodot_key_named(name, pressed)
    }

    func action(_ name: String, pressed: Bool, strength: Float) -> Bool {
        oppigodot_action(name, pressed, strength)
    }

    func capturePNG() -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        let count = oppigodot_capture_png(&bytes)
        guard let bytes, count > 0 else { return nil }
        // The PNG outlives this call and may be released on any thread (it is
        // written to disk off the main actor): `oppigodot_free` is `free`, so
        // the deallocator must not inherit this type's main-actor isolation.
        return Data(bytesNoCopy: bytes, count: count, deallocator: .custom { @Sendable pointer, _ in oppigodot_free(pointer) })
    }

    func currentScene() -> String? {
        guard let path = oppigodot_current_scene() else { return nil }
        defer { oppigodot_free(path) }
        return String(cString: path)
    }

    func perf() -> GodotPerf {
        var perf = OppiGodotPerf()
        oppigodot_perf(&perf)
        return GodotPerf(
            fps: perf.fps, processMilliseconds: perf.process_ms,
            drawCalls: Int(perf.draw_calls), nodes: Int(perf.nodes), framesDrawn: perf.frames_drawn
        )
    }
}

/// Carries log lines from whichever engine thread logged to the main actor.
@MainActor
private final class GodotLogRelay {
    static let shared = GodotLogRelay()
    var onLog: ((GodotEngineLog) -> Void)?
}

private let godotLogCallback: OppiGodotLogCallback = { entry, _ in
    guard let entry else { return }
    let raw = entry.pointee
    func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
    let kind: GodotEngineLog.Kind = switch raw.kind {
    case OPPIGODOT_LOG_ERROR: .error
    case OPPIGODOT_LOG_WARNING: .warning
    case OPPIGODOT_LOG_SCRIPT: .script
    case OPPIGODOT_LOG_SHADER: .shader
    default: .print
    }
    let line = GodotEngineLog(
        kind: kind, message: text(raw.message), file: text(raw.file), line: Int(raw.line),
        function: text(raw.function), scriptFile: text(raw.script_file), scriptLine: Int(raw.script_line),
        backtrace: text(raw.backtrace)
    )
    if Thread.isMainThread {
        MainActor.assumeIsolated { GodotLogRelay.shared.onLog?(line) }
    } else {
        Task { @MainActor in GodotLogRelay.shared.onLog?(line) }
    }
}
#endif
