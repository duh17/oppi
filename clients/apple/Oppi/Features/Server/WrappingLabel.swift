import UIKit

/// A label that wraps at the width it is laid out at, for labels in stack views.
///
/// A multi-line `UILabel` measures its height for the width it had on the pass before, so
/// a stack that narrows (a phone at an accessibility text size, the safe area settling)
/// can keep a height sized for the wider pass and draw the text clipped or over what
/// follows. Handing the laid-out width back as `preferredMaxLayoutWidth` makes the next
/// measure use it.
final class WrappingLabel: UILabel {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard numberOfLines != 1, bounds.width > 0, preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
    }
}
