import UIKit

/// How a window's panes move, in one place: every change of the tree (split,
/// close, zoom, restore, collapse, expand, move, Undo, the launcher's pane)
/// and every settle of the chat's panel width (open, close, snap, the
/// swipe-to-close's release) goes through here. Panes are furniture: they
/// arrive briefly and never overshoot. With Reduce Motion a width lands at
/// once and a tree change only cross-fades.
@MainActor
enum PaneMotion {
    /// The panel width's settle: a critically damped spring, which carries a
    /// flick's speed into the settle and comes to rest without passing its
    /// target.
    static let settleDuration: TimeInterval = 0.3
    /// A flick faster than this many target distances a second would carry
    /// even a critically damped spring past its target; it is capped.
    private static let maximumRelativeVelocity: CGFloat = 8
    /// A tree change's cross-fade.
    static let changeDuration: TimeInterval = 0.18

    /// Whether a width lands at once: UIKit's animations are off (a test, or
    /// `performWithoutAnimation`) or the person asked for less motion.
    static var settlesAtOnce: Bool {
        !UIView.areAnimationsEnabled || UIAccessibility.isReduceMotionEnabled
    }

    /// The animator for a width settle covering `distance` points, starting
    /// at `velocity` points a second.
    static func settleAnimator(distance: CGFloat, velocity: CGFloat) -> UIViewPropertyAnimator {
        let relative = distance == 0 ? 0 : min(max(velocity / distance, 0), maximumRelativeVelocity)
        let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: relative, dy: 0))
        return UIViewPropertyAnimator(duration: settleDuration, timingParameters: timing)
    }

    /// Runs a change of the tree's cells in `view`: the panes take their new
    /// frames at once and the change cross-fades, briefly. It overrides
    /// whatever animation the change runs inside, such as a menu's dismissal
    /// spring, which would otherwise fling frames (and a new pane from its
    /// corner) with a bounce.
    static func changeCells(in view: UIView, _ change: @escaping @MainActor () -> Void) {
        guard UIView.areAnimationsEnabled, view.window != nil else {
            change()
            return
        }
        UIView.transition(
            with: view,
            duration: changeDuration,
            options: [.transitionCrossDissolve, .curveEaseOut, .overrideInheritedDuration,
                      .overrideInheritedCurve, .allowUserInteraction],
            animations: { UIView.performWithoutAnimation(change) }
        )
    }
}
