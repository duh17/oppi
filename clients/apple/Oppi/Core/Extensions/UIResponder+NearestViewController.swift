import UIKit

extension UIResponder {
    /// The first view controller on the responder chain, starting at this
    /// responder: the controller whose view this view sits in, the nearest one
    /// when controllers are nested as children, or `nil` for a view that is
    /// not in a controller's hierarchy (a detached view, a bare window).
    ///
    /// The presenter for a sheet, alert, or child controller slot is this
    /// controller, not the window's root: a reader or a presented sheet in
    /// between would be skipped.
    var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
