import UIKit

/// The one motion policy for timeline rows that change size: expand, collapse,
/// and content that settles after its first layout pass (a wrapped file title,
/// a hosted notebook cell, a Markdown viewport).
///
/// Row size changes are instant for every row type, with no expand motion.
/// UIKit animates a self-sizing cell's resize by default, so a row whose
/// height settled one pass late bounced while a row that settled in its first
/// pass snapped. The timeline runs its layout through `layout(_:)`, so no row
/// starts its own resize animation; a caller's animation (keyboard, rotation)
/// still carries the layout. Expand keeps the tapped header in place and grows
/// downward (`AnchoredCollectionView`).
@MainActor
enum TimelineRowMotion {
    /// Runs timeline layout without starting resize animations of its own.
    static func layout(_ body: () -> Void) {
        if UIView.inheritedAnimationDuration > 0 {
            body()
        } else {
            UIView.performWithoutAnimation(body)
        }
    }
}
