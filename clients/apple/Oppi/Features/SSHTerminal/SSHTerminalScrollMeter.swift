import QuartzCore
import os

/// Measures terminal scroll gestures, finger down through coasting, from the
/// grid's display-link ticks. Each finished gesture is added to its terminal
/// visit's totals; `takeVisits` hands those over as `app.terminal_scroll_visit`
/// events (one per mode and scroll path), so a visit with fifty flings is one
/// event, not fifty. They carry the terminal's mode and where the scroll went,
/// never what the terminal shows.
@MainActor
final class SSHTerminalScrollMeter {
    /// One finished gesture.
    struct Gesture: Equatable {
        let durationMs: Double
        let frames: Int
        let hitches: Int
        let hitchRatio: Double
        let worstFrameMs: Double
        let deferredBytes: Int
        let mode: TelemetryTag.TerminalMode
        let path: TelemetryTag.ScrollPath
    }

    #if DEBUG
    /// Sees every finished gesture, for the debug harness's UI runs (the event
    /// itself only exists per visit). Absent from release builds.
    nonisolated(unsafe) static var _gestureObserverForTesting: (@MainActor (Gesture) -> Void)?
    #endif

    private struct Running {
        let mode: TelemetryTag.TerminalMode
        let path: TelemetryTag.ScrollPath
        let heldBytesAtStart: Int
        let interval: OSSignpostIntervalState
    }

    private struct Key: Hashable {
        let mode: TelemetryTag.TerminalMode
        let path: TelemetryTag.ScrollPath
    }

    private struct Totals {
        var gestures = 0
        var durationMs = 0.0
        var frames = 0
        var hitches = 0
        /// Hitch time, so the visit's ratio is over its whole scroll time.
        var hitchMs = 0.0
        var worstFrameMs = 0.0
        var deferredBytes = 0
    }

    private var counter = FrameHitchCounter()
    private var running: Running?
    private var visit: [Key: Totals] = [:]

    /// Feeds one display-link tick. `scrolling` says a gesture is running now;
    /// the tick that finds it over returns the finished gesture. `mode` and
    /// `path` are read once, when a gesture starts.
    @discardableResult
    func tick(
        timestamp: CFTimeInterval,
        targetTimestamp: CFTimeInterval,
        scrolling: Bool,
        heldBytes: Int,
        mode: @autoclosure () -> TelemetryTag.TerminalMode,
        path: @autoclosure () -> TelemetryTag.ScrollPath
    ) -> Gesture? {
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
        let gesture = Gesture(
            durationMs: counter.elapsedMilliseconds,
            frames: counter.frames,
            hitches: counter.hitches,
            hitchRatio: counter.hitchRatio,
            worstFrameMs: counter.worstFrameMilliseconds,
            deferredBytes: max(0, heldBytes - finished.heldBytesAtStart),
            mode: finished.mode,
            path: finished.path
        )
        var totals = visit[Key(mode: gesture.mode, path: gesture.path), default: Totals()]
        totals.gestures += 1
        totals.durationMs += gesture.durationMs
        totals.frames += gesture.frames
        totals.hitches += gesture.hitches
        totals.hitchMs += gesture.hitchRatio * gesture.durationMs
        totals.worstFrameMs = max(totals.worstFrameMs, gesture.worstFrameMs)
        totals.deferredBytes += gesture.deferredBytes
        visit[Key(mode: gesture.mode, path: gesture.path)] = totals
        #if DEBUG
        Self._gestureObserverForTesting?(gesture)
        #endif
        return gesture
    }

    /// The display link was off and starts again: the next tick starts the
    /// clock, so a gesture that was paused (the app inactive) does not count the
    /// pause as one long frame.
    func linkRestarted() {
        counter.forgetLastFrame()
    }

    /// The visit's totals so far, one event per mode and scroll path, and a fresh
    /// visit. A gesture still running stays in its own clock and joins the next visit.
    func takeVisits() -> [AppTerminalScrollVisit] {
        defer { visit = [:] }
        return visit.map { key, totals in
            AppTerminalScrollVisit(
                gestures: totals.gestures,
                durationMs: totals.durationMs,
                frames: totals.frames,
                hitches: totals.hitches,
                hitchRatio: totals.durationMs > 0 ? totals.hitchMs / totals.durationMs : 0,
                worstFrameMs: totals.worstFrameMs,
                deferredBytes: totals.deferredBytes,
                terminalMode: key.mode,
                scrollPath: key.path
            )
        }
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
