import UIKit

/// Finger numbers for the engine: each touch keeps the number it began with
/// until it ends, and a new touch takes the lowest free one, as Godot's own
/// iOS view numbers them, so `InputEventScreenTouch.index` 0 is always the
/// first finger down.
struct GodotTouchSlots {
    private var slots: [ObjectIdentifier: Int] = [:]

    /// The number for a touch that began.
    mutating func begin(_ touch: ObjectIdentifier) -> Int {
        if let index = slots[touch] { return index }
        let used = Set(slots.values)
        let index = (0...).first { !used.contains($0) } ?? 0
        slots[touch] = index
        return index
    }

    /// The number of a touch that moves; nil for one the engine never saw.
    func index(of touch: ObjectIdentifier) -> Int? {
        slots[touch]
    }

    /// Frees the number of a touch that ended or was cancelled.
    mutating func end(_ touch: ObjectIdentifier) -> Int? {
        slots.removeValue(forKey: touch)
    }

    /// Every touch still down, for cancelling them all.
    mutating func removeAll() -> [Int] {
        defer { slots.removeAll() }
        return slots.values.sorted()
    }
}

/// Turns the surface's touches and hardware keys into engine input
/// (design §9). Touches go to the engine as they arrive, before the display
/// link's next `iterate`, with every coalesced sample of a move and the
/// precise (Pencil) location; positions are in the engine's points, which
/// differ from the view's only while a divider drag holds the engine's size
/// (`engineScale`). Keys without ⌘ go to the game; ⌘ chords stay the app's.
@MainActor
final class GodotInputForwarder {
    private var slots = GodotTouchSlots()
    /// The engine, while it runs; input is dropped otherwise.
    weak var host: GodotEngineHost?

    /// Where new input goes: nil while the game is paused or not running.
    private var runtime: (any GodotEngineRuntime)? {
        host?.inputRuntime
    }

    /// Where the ends of input go: any running game, paused or not, so a
    /// finger lifted or a key released during a pause never stays held.
    private var endRuntime: (any GodotEngineRuntime)? {
        host?.liveRuntime
    }

    func touchesBegan(_ touches: Set<UITouch>, in view: GodotSurfaceView) {
        for touch in touches {
            began(
                ObjectIdentifier(touch), at: view.enginePoint(touch.preciseLocation(in: view)),
                pressure: Self.pressure(touch), doubleTap: touch.tapCount == 2
            )
        }
    }

    /// One finger down; it keeps its number until it ends.
    func began(_ touch: ObjectIdentifier, at point: CGPoint, pressure: Float, doubleTap: Bool) {
        guard let runtime else { return }
        let index = slots.begin(touch)
        runtime.touch(index: index, phase: .began, at: point, from: point, pressure: pressure, doubleTap: doubleTap)
    }

    func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?, in view: GodotSurfaceView) {
        guard let runtime else { return }
        for touch in touches {
            guard let index = slots.index(of: ObjectIdentifier(touch)) else { continue }
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                runtime.touch(
                    index: index, phase: .moved,
                    at: view.enginePoint(sample.preciseLocation(in: view)),
                    from: view.enginePoint(sample.precisePreviousLocation(in: view)),
                    pressure: Self.pressure(sample), doubleTap: false
                )
            }
        }
    }

    func touchesEnded(_ touches: Set<UITouch>, cancelled: Bool, in view: GodotSurfaceView) {
        for touch in touches {
            ended(ObjectIdentifier(touch), at: view.enginePoint(touch.preciseLocation(in: view)), cancelled: cancelled)
        }
    }

    /// One finger up, paused or not: its number is free again.
    func ended(_ touch: ObjectIdentifier, at point: CGPoint, cancelled: Bool) {
        guard let index = slots.end(touch), let endRuntime else { return }
        endRuntime.touch(index: index, phase: cancelled ? .cancelled : .ended, at: point, from: point, pressure: 0, doubleTap: false)
    }

    /// Lifts every finger the engine holds: the surface moved to another
    /// pane or left the window mid-touch, and UIKit sends no end for those.
    func cancelAll() {
        let indices = slots.removeAll()
        guard let endRuntime else { return }
        for index in indices {
            endRuntime.touch(index: index, phase: .cancelled, at: .zero, from: .zero, pressure: 0, doubleTap: false)
        }
    }

    /// Whether the presses went to the game; the rest go up the responder chain.
    func presses(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        guard let runtime = pressed ? runtime : endRuntime else { return false }
        var forwarded = false
        for press in presses {
            guard let key = press.key, !key.modifierFlags.contains(.command) else { continue }
            runtime.key(key, pressed: pressed)
            forwarded = true
        }
        return forwarded
    }

    /// Force as Godot's 0–1 pressure: a Pencil's, or a finger's on a device
    /// that measures it; 0 where nothing does.
    private static func pressure(_ touch: UITouch) -> Float {
        guard touch.maximumPossibleForce > 0 else { return 0 }
        return Float(min(1, touch.force / touch.maximumPossibleForce))
    }
}
