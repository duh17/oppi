import os
import UIKit

// MARK: - Top scroll edge effect guard

/// What the top scroll edge effect measured after a thread folded open or closed, and what the list
/// expected it to be. The fields are the ones a breadcrumb needs to tell a real band from a bar whose
/// height the list misread.
struct SessionListEdgeEffectReport: Equatable {
    /// The effect's height as drawn, over the rows.
    let band: CGFloat
    /// The height the bar itself gives it: `adjustedContentInset.top`.
    let expected: CGFloat
    let adjustedContentInset: UIEdgeInsets
    /// The pinned section header the effect sits over, in the collection view's coordinates.
    let pinnedHeader: CGRect?
    /// `headerMode` per visible section, as the list set it (`supplementary` or `none`).
    let headerModes: [String]
    /// Whether the snapshot that changed the rows animated (a fold from a tap does; the first apply and
    /// a host reset do not).
    let wasAnimated: Bool
    /// One line an operator can act on.
    var summary: String {
        let header = pinnedHeader.map { "\($0.minY)…\($0.maxY)" } ?? "none"
        return "top scroll edge effect \(band.rounded()) pt over \(expected.rounded()) pt expected"
            + " · inset \(adjustedContentInset.top.rounded())"
            + " · pinned header \(header)"
            + " · header modes \(headerModes.joined(separator: ","))"
            + " · animated \(wasAnimated)"
    }
}

/// How the session lists keep iOS's top scroll edge effect honest after a thread folds. UIKit grows
/// the effect to cover what an animated diff inserts and then keeps that height until the next
/// relayout (a chat round trip relaid it out on the server-switch case, commit `ed866aa9f`): a blurred
/// band over the rows under the bar. The list measures the effect once a fold's apply finishes and, only
/// when it is taller than the bar by more than `tolerance`, relayouts the list and leaves one
/// breadcrumb. A normal fold measures and stops there: no relayout, no event.
@MainActor
struct SessionListEdgeEffectGuard {
    /// The effect's height, or nil when the list draws none.
    var measure: (UICollectionView) -> CGFloat?
    /// Puts the effect's measurement back: empty the list, then apply its snapshot without animation.
    var relayout: () -> Void
    /// The one breadcrumb a band leaves.
    var report: (SessionListEdgeEffectReport) -> Void

    /// A bar is this much taller than the effect at most; anything beyond it is a band, not a
    /// measurement of the bar. Healthy lists measure 156-196 pt against a 170 pt inset.
    static let tolerance: CGFloat = 60

    /// Whether `band` is taller than the bar it covers, by more than `tolerance`.
    static func isBand(_ band: CGFloat, over expected: CGFloat) -> Bool {
        expected > 0 && band > expected + tolerance
    }

    /// The guard a shipped list uses: UIKit's own views for the measurement, the list's relayout, and
    /// one breadcrumb on the client log (`SessionListEdgeEffect.log`).
    static func standard(relayout: @escaping () -> Void) -> SessionListEdgeEffectGuard {
        SessionListEdgeEffectGuard(
            measure: { SessionListEdgeEffect.measuredHeight(in: $0) },
            relayout: relayout,
            report: { SessionListEdgeEffect.log($0) }
        )
    }
}

/// Reads the effect's height off the views UIKit puts on a scroll view's top edge.
///
/// `UIScrollEdgeEffect` exposes a style and `isHidden` and nothing else, so the height is not
/// available through public API. This reads the view tree by class name only — no selectors, no
/// ivars, no subclassing — and answers nil when UIKit's shape changes, which the guard reads as
/// "nothing to check" rather than as a band.
@MainActor
enum SessionListEdgeEffect {
    /// The height of the backdrop on the scroll view's top edge, in the effect's own coordinates.
    static func measuredHeight(in scrollView: UIScrollView) -> CGFloat? {
        func backdrops(_ view: UIView) -> [UIView] {
            view.subviews.flatMap { subview -> [UIView] in
                let isBackdrop = String(describing: type(of: subview)).contains("ScrollEdgeEffect")
                return (isBackdrop ? [subview] : []) + backdrops(subview)
            }
        }
        // The top effect sits on the scroll view's top edge; the bottom one sits on its bottom edge.
        let top = backdrops(scrollView)
            .filter { $0.frame.minY <= 0.5 }
            .max { $0.frame.height < $1.frame.height }
        return top?.frame.height
    }

    /// The breadcrumb a band leaves. It goes through `ClientLog`, so it reaches the server's client log
    /// (`telemetry/client-logs-*.jsonl`) on the next upload; an `os_log` line alone never leaves the device.
    static func log(_ report: SessionListEdgeEffectReport) {
        ClientLog.info("SessionList", "Edge effect band", metadata: metadata(for: report), flush: true)
        logger.notice("\(report.summary, privacy: .public)")
    }

    /// The numbers an operator needs from a band, as strings for the client log.
    static func metadata(for report: SessionListEdgeEffectReport) -> [String: String] {
        [
            "band": format(report.band),
            "expected": format(report.expected),
            "insetTop": format(report.adjustedContentInset.top),
            "insetBottom": format(report.adjustedContentInset.bottom),
            "pinnedHeader": report.pinnedHeader.map { "\(format($0.minY))…\(format($0.maxY))" } ?? "none",
            "headerModes": report.headerModes.joined(separator: ","),
            "animated": report.wasAnimated ? "true" : "false",
        ]
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SessionList")
