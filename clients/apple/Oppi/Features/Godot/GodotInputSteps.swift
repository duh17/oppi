import Foundation
import UIKit

/// Input a controller sends (`GodotCommand.input`), played into the running
/// game in order, each step after the last ends. Points are fractions of the
/// game view; they become the engine's points from the view's size. Taps and
/// drags use a finger number of their own, so they never end a real finger's
/// touch.
@MainActor
enum GodotInputSteps {
    /// The finger number synthetic touches use: above any real hand's.
    static let fingerIndex = 9
    static let defaultHold: Duration = .milliseconds(50)
    static let defaultDrag: Duration = .milliseconds(250)
    /// One drag sample per display frame at 60 Hz.
    static let dragStep: Duration = .milliseconds(16)

    /// The number of steps run, or the first step's failure.
    static func run(_ steps: [GodotInputStep], on runtime: any GodotEngineRuntime, size: CGSize) async -> Result<Int, GodotError> {
        func point(_ point: GodotPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1) * size.width, y: min(max(point.y, 0), 1) * size.height)
        }
        for step in steps {
            guard !Task.isCancelled else { return .failure(GodotError(code: .failed, message: "Cancelled.")) }
            switch step {
            case .tap(let at, let holdMs):
                let p = point(at)
                runtime.touch(index: fingerIndex, phase: .began, at: p, from: p, pressure: 1, doubleTap: false)
                try? await Task.sleep(for: duration(holdMs, otherwise: defaultHold))
                runtime.touch(index: fingerIndex, phase: .ended, at: p, from: p, pressure: 0, doubleTap: false)
            case .drag(let from, let to, let durationMs):
                let start = point(from), end = point(to)
                runtime.touch(index: fingerIndex, phase: .began, at: start, from: start, pressure: 1, doubleTap: false)
                let total = duration(durationMs, otherwise: defaultDrag)
                let count = max(1, Int((total / dragStep).rounded(.up)))
                var previous = start
                for sample in 1...count {
                    try? await Task.sleep(for: dragStep)
                    let t = CGFloat(sample) / CGFloat(count)
                    let next = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    runtime.touch(index: fingerIndex, phase: .moved, at: next, from: previous, pressure: 1, doubleTap: false)
                    previous = next
                }
                runtime.touch(index: fingerIndex, phase: .ended, at: end, from: end, pressure: 0, doubleTap: false)
            case .key(let name, let holdMs):
                guard runtime.key(named: name, pressed: true) else {
                    return .failure(GodotError(code: .invalid, message: "Godot has no key named \(name)."))
                }
                try? await Task.sleep(for: duration(holdMs, otherwise: defaultHold))
                _ = runtime.key(named: name, pressed: false)
            case .action(let name, let holdMs, let strength):
                guard runtime.action(name, pressed: true, strength: Float(strength ?? 1)) else {
                    return .failure(GodotError(code: .invalid, message: "The project has no input action \(name)."))
                }
                try? await Task.sleep(for: duration(holdMs, otherwise: defaultHold))
                _ = runtime.action(name, pressed: false, strength: 0)
            case .wait(let ms):
                try? await Task.sleep(for: .milliseconds(max(0, ms)))
            case .unsupported(let kind):
                return .failure(GodotError(code: .unsupported, message: "This player does not do \(kind) steps."))
            }
        }
        return .success(steps.count)
    }

    private static func duration(_ milliseconds: Double?, otherwise fallback: Duration) -> Duration {
        milliseconds.map { .milliseconds(max(0, $0)) } ?? fallback
    }
}
