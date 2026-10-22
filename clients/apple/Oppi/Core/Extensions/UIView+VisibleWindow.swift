import UIKit

extension UIView {
    /// True when this view is attached to a window a person can see.
    ///
    /// `window != nil` is not enough before focusing a field: a window that is
    /// hidden (a torn-down screen, a test window on its way out) keeps its view
    /// hierarchy attached, and UIKit focuses a field in it as happily as in a
    /// visible one. The keyboard that comes up has no responder in any visible
    /// window, so nothing can resign it and it stays up over every screen after.
    var isOnVisibleWindow: Bool {
        guard let window else { return false }
        return !window.isHidden
    }
}
