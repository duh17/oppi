import UIKit

/// UIScrollView variant for nested horizontal-only tool viewports.
///
/// Expanded tool rows (code/diff/bash unwrapped) need horizontal scrolling,
/// but vertical drags must stay owned by the outer chat timeline collection
/// view so users can always detach from bottom/follow lock.
///
/// This view only begins its pan gesture for clear horizontal intent. Vertical
/// (or near-diagonal) drags are rejected and bubble to the parent timeline.
final class HorizontalPanPassthroughScrollView: UIScrollView {
    private static let horizontalIntentBias: CGFloat = 1.15

    #if DEBUG
    /// Unit tests cannot synthesize UIKit touch velocity. This seam still runs
    /// through the real nested scroll view's gestureRecognizerShouldBegin path.
    var panVelocityOverrideForTesting: CGPoint?
    #endif

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        guard isScrollEnabled else {
            return false
        }

        #if DEBUG
        let velocity = panVelocityOverrideForTesting ?? panGestureRecognizer.velocity(in: self)
        #else
        let velocity = panGestureRecognizer.velocity(in: self)
        #endif
        guard Self.shouldBeginHorizontalPan(with: velocity) else {
            return false
        }

        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    static func shouldBeginHorizontalPan(with velocity: CGPoint) -> Bool {
        let vx = abs(velocity.x)
        let vy = abs(velocity.y)

        if vx == 0, vy == 0 {
            // No direction signal yet — don't block begin preemptively.
            return true
        }

        return vx >= vy * horizontalIntentBias
    }
}
