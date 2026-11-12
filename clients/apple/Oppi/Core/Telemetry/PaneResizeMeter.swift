import QuartzCore
import os

/// Measures live divider resizes, finger down until the panes settle: frames
/// and hitches from a display link that runs only meanwhile, the main thread's
/// work per divider frame (signpost `PaneResizeFrame`), and each settle's
/// reflow (signpost `PaneReflow`). A visit's drags are summed into one
/// `app.pane_resize_visit` event (`takeVisit`), so fifty drags are one event.
@MainActor
final class PaneResizeMeter {
    /// One finished drag, through its final settle.
    struct Drag: Equatable {
        let durationMs: Double
        let frames: Int
        let hitches: Int
        let hitchRatio: Double
        let worstFrameMs: Double
        /// Main-thread work per divider frame, the p95 and the worst.
        let workP95Ms: Double
        let workMaxMs: Double
        let reflows: Int
        let reflowMs: Double
        let worstReflowMs: Double
    }

    static let signposter = OSSignposter(subsystem: AppIdentifiers.subsystem, category: "PaneResize")

    #if DEBUG
    /// Where a drag is, for the debug harness's UI runs, which count the
    /// timeline's layout work while the divider moves apart from its settles.
    enum Phase {
        case dragBegan, reflowBegan, reflowEnded, dragEnded(Drag)
    }

    /// Sees every phase of every drag (the event itself only exists per
    /// visit). Absent from release builds.
    nonisolated(unsafe) static var _phaseObserverForTesting: (@MainActor (Phase) -> Void)?
    #endif

    private struct Running {
        var counter = FrameHitchCounter()
        var workMs: [Double] = []
        var reflows = 0
        var reflowMs = 0.0
        var worstReflowMs = 0.0
        let interval: OSSignpostIntervalState
    }

    private struct Totals {
        var drags = 0
        var durationMs = 0.0
        /// Hitch time, so hitch time per second pools over whole drag time.
        var hitchMs = 0.0
        var worstFrameMs = 0.0
        var reflowMs = 0.0
    }

    private var running: Running?
    private var visit = Totals()
    private var link: CADisplayLink?

    isolated deinit {
        link?.invalidate()
    }

    /// A divider started to move. A drag already running keeps its clock: a
    /// grab during a settle continues the same drag.
    func beginDrag() {
        guard running == nil else { return }
        running = Running(interval: Self.signposter.beginInterval("PaneResize"))
        #if DEBUG
        Self._phaseObserverForTesting?(.dragBegan)
        #endif
        let link = CADisplayLink(target: LinkTarget(meter: self), selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Runs one divider frame's work (the new width and the layout it causes)
    /// and records how long the main thread spent on it.
    func measureFrame(_ body: () -> Void) {
        let state = Self.signposter.beginInterval("PaneResizeFrame")
        let start = CACurrentMediaTime()
        body()
        running?.workMs.append((CACurrentMediaTime() - start) * 1_000)
        Self.signposter.endInterval("PaneResizeFrame", state)
    }

    /// Runs one settle's reflow and records how long it took.
    func measureReflow(_ body: () -> Void) {
        #if DEBUG
        Self._phaseObserverForTesting?(.reflowBegan)
        #endif
        let state = Self.signposter.beginInterval("PaneReflow")
        let start = CACurrentMediaTime()
        body()
        let elapsed = (CACurrentMediaTime() - start) * 1_000
        Self.signposter.endInterval("PaneReflow", state)
        #if DEBUG
        Self._phaseObserverForTesting?(.reflowEnded)
        #endif
        guard var drag = running else { return }
        drag.reflows += 1
        drag.reflowMs += elapsed
        drag.worstReflowMs = max(drag.worstReflowMs, elapsed)
        running = drag
    }

    /// The drag is over and its panes have settled: the link stops and the drag
    /// joins the visit's totals.
    @discardableResult
    func endDrag() -> Drag? {
        link?.invalidate()
        link = nil
        guard let finished = running else { return nil }
        running = nil
        Self.signposter.endInterval("PaneResize", finished.interval)
        let counter = finished.counter
        let sorted = finished.workMs.sorted()
        let drag = Drag(
            durationMs: counter.elapsedMilliseconds,
            frames: counter.frames,
            hitches: counter.hitches,
            hitchRatio: counter.hitchRatio,
            worstFrameMs: counter.worstFrameMilliseconds,
            workP95Ms: sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)],
            workMaxMs: sorted.last ?? 0,
            reflows: finished.reflows,
            reflowMs: finished.reflowMs,
            worstReflowMs: finished.worstReflowMs
        )
        visit.drags += 1
        visit.durationMs += drag.durationMs
        visit.hitchMs += drag.hitchRatio * drag.durationMs
        visit.worstFrameMs = max(visit.worstFrameMs, drag.worstFrameMs)
        visit.reflowMs += drag.reflowMs
        #if DEBUG
        Self._phaseObserverForTesting?(.dragEnded(drag))
        #endif
        return drag
    }

    /// The visit's totals so far as one event, and a fresh visit; nil when no
    /// drag finished. A drag still running joins the next visit.
    func takeVisit() -> AppPaneResizeVisit? {
        defer { visit = Totals() }
        guard visit.drags > 0 else { return nil }
        return AppPaneResizeVisit(
            durationMs: visit.durationMs,
            hitchMs: visit.hitchMs,
            worstFrameMs: visit.worstFrameMs,
            reflowMs: visit.reflowMs
        )
    }

    fileprivate func tick(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        running?.counter.tick(timestamp: timestamp, targetTimestamp: targetTimestamp)
    }

    /// The display link holds its target strongly; this holds the meter weakly,
    /// so a meter dropped mid-drag is not kept alive by its link.
    @MainActor
    private final class LinkTarget: NSObject {
        weak var meter: PaneResizeMeter?

        init(meter: PaneResizeMeter) {
            self.meter = meter
        }

        /// The link was added to the main run loop, so it ticks there.
        @objc func tick(_ link: CADisplayLink) {
            meter?.tick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }
    }
}
