import UIKit

/// The one source of truth for the widest a full-width content column grows
/// (settings forms). The cap depends on width only, never on the size class, so
/// an iPhone Pro Max in landscape gets it too. Bars, backgrounds, and scroll
/// views stay full-bleed; only the content column is capped.
///
/// Reader prose keeps `ReaderReadingColumn`: it is pure prose at the reader's
/// own text scale (40 em), and it widens tables and code past the column.
enum ReadableContentWidth {
    static let column: CGFloat = 760

    /// `view` is at most the cap wide, as wide as `container` when that is
    /// narrower (at `.defaultHigh`, so the cap wins), and centered in the
    /// container's safe area, never wider than it. A container can run under a
    /// sidebar or a rail (an iPad split view's detail extends under its
    /// sidebar, which is a safe-area inset), so centering on its bounds would
    /// center on the window and slide the column under the sidebar. The caller
    /// activates the constraints.
    @MainActor
    static func constrain(_ view: UIView, to container: UIView) -> [NSLayoutConstraint] {
        let safe = container.safeAreaLayoutGuide
        let fill = view.widthAnchor.constraint(equalTo: container.widthAnchor)
        fill.priority = .defaultHigh
        return [
            view.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            view.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor),
            fill,
            view.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
        ]
    }
}
