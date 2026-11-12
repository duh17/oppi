#if DEBUG
import UIKit

/// What a UI run reads of a live divider resize (`PaneResizeSmoothnessUITests`):
/// the latest drag in a near-invisible label, `paneResize.drag`, as
/// `key=value` words after a running count (`none` before the first): the
/// meter's frames, hitches and main-thread work per divider frame, and the
/// timeline's layout work while the divider moved (`moving_*`) apart from its
/// settles (`settle_*`). `moving_rebuilds` counts the rebuilds geometry caused;
/// `moving_content_rebuilds` the ones a data change asked for meanwhile (this
/// harness keeps re-seeding the chat's state). A second label,
/// `paneResize.timeline`, carries the timeline's running totals
/// (`measured=`, `rebuilds=`), for a rotation's deltas.
@MainActor
final class PaneResizeReadout {
    private let dragLabel = UILabel()
    private let timelineLabel = UILabel()
    private var timelineTimer: Timer?
    private var drags = 0
    private var phaseStart = Counters()
    private var reflowStart: CFTimeInterval = 0
    private var moving = Counters()
    private var settle = (measured: 0, maxMeasured: 0, maxMs: 0.0)

    private struct Counters {
        var rebuilds = 0
        var contentRebuilds = 0
        var measured = 0

        @MainActor static var now: Self {
            Self(
                rebuilds: ChatTimelinePerf.layoutRebuildCount,
                contentRebuilds: ChatTimelinePerf.contentRebuildCount,
                measured: ChatTimelinePerf.rowMeasureCount
            )
        }

        static func += (lhs: inout Self, rhs: Self) {
            lhs.rebuilds += rhs.rebuilds
            lhs.contentRebuilds += rhs.contentRebuilds
            lhs.measured += rhs.measured
        }

        static func - (lhs: Self, rhs: Self) -> Self {
            Self(
                rebuilds: lhs.rebuilds - rhs.rebuilds,
                contentRebuilds: lhs.contentRebuilds - rhs.contentRebuilds,
                measured: lhs.measured - rhs.measured
            )
        }
    }

    func install(in view: UIView) {
        for (label, identifier) in [(dragLabel, "paneResize.drag"), (timelineLabel, "paneResize.timeline")] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 1)
            label.alpha = 0.02
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = identifier
            // Not empty: an element with no text is not in the accessibility tree.
            label.text = "none"
            label.accessibilityLabel = "none"
            view.addSubview(label)
        }
        NSLayoutConstraint.activate([
            dragLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 6),
            dragLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 6),
            dragLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dragLabel.topAnchor.constraint(equalTo: view.topAnchor),
            timelineLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 6),
            timelineLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 6),
            timelineLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            timelineLabel.topAnchor.constraint(equalTo: dragLabel.bottomAnchor),
        ])
        PaneResizeMeter._phaseObserverForTesting = { [weak self] phase in self?.observe(phase) }
        timelineTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTimelineTotals() }
        }
    }

    isolated deinit {
        PaneResizeMeter._phaseObserverForTesting = nil
        timelineTimer?.invalidate()
    }

    private func showTimelineTotals() {
        let now = Counters.now
        let text = "measured=\(now.measured) rebuilds=\(now.rebuilds)"
        guard timelineLabel.text != text else { return }
        timelineLabel.text = text
        timelineLabel.accessibilityLabel = text
    }

    private func observe(_ phase: PaneResizeMeter.Phase) {
        let now = Counters.now
        switch phase {
        case .dragBegan:
            moving = Counters()
            settle = (0, 0, 0)
            phaseStart = now
        case .reflowBegan:
            moving += now - phaseStart
            phaseStart = now
            reflowStart = CACurrentMediaTime()
        case .reflowEnded:
            let measured = now.measured - phaseStart.measured
            settle.measured += measured
            settle.maxMeasured = max(settle.maxMeasured, measured)
            settle.maxMs = max(settle.maxMs, (CACurrentMediaTime() - reflowStart) * 1_000)
            phaseStart = now
        case .dragEnded(let drag):
            moving += now - phaseStart
            drags += 1
            let words = [
                "drag=\(drags)", "frames=\(drag.frames)", "hitches=\(drag.hitches)",
                "hitch_ratio=\(String(format: "%.4g", drag.hitchRatio))",
                "worst_frame_ms=\(String(format: "%.4g", drag.worstFrameMs))",
                "work_p95_ms=\(String(format: "%.4g", drag.workP95Ms))",
                "work_max_ms=\(String(format: "%.4g", drag.workMaxMs))",
                "reflows=\(drag.reflows)", "reflow_max_ms=\(String(format: "%.4g", drag.worstReflowMs))",
                "moving_rebuilds=\(moving.rebuilds - moving.contentRebuilds)",
                "moving_content_rebuilds=\(moving.contentRebuilds)",
                "moving_measured=\(moving.measured)",
                "settle_measured=\(settle.measured)", "settle_max_measured=\(settle.maxMeasured)",
            ]
            dragLabel.text = words.joined(separator: " ")
            dragLabel.accessibilityLabel = dragLabel.text
        }
    }
}
#endif
