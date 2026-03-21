import UIKit

/// Factory for the double-tap gesture recognizers used by timeline rows
/// for copy-to-clipboard. Every row type wires the same three properties;
/// this centralises the boilerplate.
enum DoubleTapCopyGesture {
    /// Creates a double-tap gesture recognizer.
    ///
    /// - Parameters:
    ///   - target: The object that receives the action message.
    ///   - action: The selector to invoke on double-tap.
    ///   - cancelsTouchesInView: Whether the gesture cancels touches in the
    ///     view. Defaults to `false`. Set to `true` for rows that need to
    ///     block single-tap selection (tool rows, thinking rows).
    @MainActor
    static func makeGesture(
        target: AnyObject,
        action: Selector,
        cancelsTouchesInView: Bool = false
    ) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer(target: target, action: action)
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = cancelsTouchesInView
        return recognizer
    }
}
