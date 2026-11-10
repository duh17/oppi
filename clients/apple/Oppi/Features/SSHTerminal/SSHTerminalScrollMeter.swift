import QuartzCore
import os

/// Measures one terminal scroll gesture, finger down through coasting, from
/// the grid's display-link ticks, and reports it as one
/// `app.terminal_scroll_gesture` event: frames, hitches, hitch time ratio, the
/// worst frame, and the Rex output kept off those frames. The event carries the
/// terminal's mode and where the scroll went, never what the terminal shows.
@MainActor
final class SSHTerminalScrollMeter {
    private struct Running {
        let mode: TelemetryTag.TerminalMode
        let path: TelemetryTag.ScrollPath
        let heldBytesAtStart: Int
        let interval: OSSignpostIntervalState
    }

    private var counter = FrameHitchCounter()
    private var running: Running?

    /// Feeds one display-link tick. `scrolling` says a gesture is running now;
    /// the tick that finds it over returns the finished gesture. `mode` and
    /// `path` are read once, when a gesture starts.
    func tick(
        timestamp: CFTimeInterval,
        targetTimestamp: CFTimeInterval,
        scrolling: Bool,
        heldBytes: Int,
        mode: @autoclosure () -> TelemetryTag.TerminalMode,
        path: @autoclosure () -> TelemetryTag.ScrollPath
    ) -> AppTerminalScrollGesture? {
        if scrolling {
            if running == nil {
                counter = FrameHitchCounter()
                let signposter = SSHTerminalScrollPerf.signposter
                running = Running(
                    mode: mode(), path: path(), heldBytesAtStart: heldBytes,
                    interval: signposter.beginInterval("scrollGesture")
                )
            }
            counter.tick(timestamp: timestamp, targetTimestamp: targetTimestamp)
            return nil
        }
        guard let finished = running else { return nil }
        running = nil
        SSHTerminalScrollPerf.signposter.endInterval("scrollGesture", finished.interval)
        return AppTerminalScrollGesture(
            durationMs: counter.elapsedMilliseconds,
            frames: counter.frames,
            hitches: counter.hitches,
            hitchRatio: counter.hitchRatio,
            worstFrameMs: counter.worstFrameMilliseconds,
            deferredBytes: max(0, heldBytes - finished.heldBytesAtStart),
            terminalMode: finished.mode,
            scrollPath: finished.path
        )
    }

    /// What the terminal runs: a Rex session, else the multiplexer its startup
    /// command starts, else a plain shell.
    static func mode(isRex: Bool, command: String?) -> TelemetryTag.TerminalMode {
        if isRex { return .rex }
        switch SSHTerminalMultiplexerKind.detected(in: command) {
        case .herdr: return .herdr
        case .tmux: return .tmux
        case nil: return .shell
        }
    }

    static func path(_ action: SSHTerminalScrollAction) -> TelemetryTag.ScrollPath {
        switch action {
        case .history: .history
        case .mouseWheel: .wheel
        case .alternateKeys: .keys
        }
    }
}
