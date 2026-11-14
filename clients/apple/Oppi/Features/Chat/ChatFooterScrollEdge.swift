import UIKit

extension UIScrollView {
    /// Keeps this scroll view's content from shaping an edge effect claimed by a container above
    /// it. The chat footer claims the timeline's bottom edge effect
    /// (`UIScrollEdgeElementContainerInteraction` on the footer stack), and UIKit shapes that
    /// effect from every label and control under the footer by frame, ignoring this scroll
    /// view's clipping: rows scrolled up out of a drawer's viewport pulled a frosted band up
    /// over the timeline as far as they had scrolled. An interaction of its own, tied to no
    /// scroll view, closes this subtree to the outer one and draws nothing; the drawer's own
    /// surface still shapes the effect.
    func keepsContentOutOfEnclosingEdgeEffects() {
        addInteraction(UIScrollEdgeElementContainerInteraction())
    }
}
