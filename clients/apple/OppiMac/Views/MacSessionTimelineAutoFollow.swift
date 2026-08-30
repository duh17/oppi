import SwiftUI

/// Mac timeline follow policy: stay pinned to the latest row while the user
/// is near the bottom. Geometry math lives here so OppiMacTests can cover it
/// without embedding UIKit's chat scroller.
enum MacSessionTimelineAutoFollow {
    static let nearBottomThreshold: CGFloat = 64
    static let latestAnchorID = "mac.timeline.latest"

    static func distanceFromBottom(
        contentHeight: CGFloat,
        offsetY: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        contentHeight - offsetY - viewportHeight
    }

    static func isNearBottom(
        contentHeight: CGFloat,
        offsetY: CGFloat,
        viewportHeight: CGFloat,
        threshold: CGFloat = nearBottomThreshold
    ) -> Bool {
        distanceFromBottom(
            contentHeight: contentHeight,
            offsetY: offsetY,
            viewportHeight: viewportHeight
        ) <= threshold
    }

    /// Offset leaving the tail detaches even if streaming also grew the
    /// document. Mac cannot tell user-drag from layout growth, so treating
    /// growth as still-attached would pin the user during a scroll-up.
    static func isAttachedAfterGeometryChange(
        wasAttached: Bool,
        isNearBottom: Bool,
        scrollPhase: ScrollPhase
    ) -> Bool {
        isNearBottom || (wasAttached && !isUserDriven(scrollPhase))
    }

    static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            true
        case .idle, .animating:
            false
        }
    }

    static func shouldScrollAfterContentGrowth(
        isAttached: Bool,
        isNearBottom: Bool,
        contentHeightIncreased: Bool
    ) -> Bool {
        isAttached && !isNearBottom && contentHeightIncreased
    }

    static func shouldScrollToLatestRow(isAttached: Bool) -> Bool {
        isAttached
    }

    /// Outline jump pins to a specific row. Stay attached only when that row
    /// is already the latest, so live follow does not yank the user back.
    static func shouldAttachToLatestAfterJump(
        targetID: String,
        latestItemID: String?
    ) -> Bool {
        targetID == latestItemID
    }

    static func scrollAnimation(reduceMotion: Bool) -> Animation? {
        ThemeMotion.easeInOut(duration: 0.18, reduceMotion: reduceMotion)
    }
}

/// Bottom overlap so the last timeline row sits above the composer glass,
/// matching iOS `contentInset.bottom = footerHeight`.
enum MacSessionTimelineOverlap {
    /// Text row + action row + capsule padding before geometry measures.
    static let defaultComposerHeight: CGFloat = 92
    static let extraBreathingRoom: CGFloat = 8

    static func bottomContentInset(composerHeight: CGFloat) -> CGFloat {
        max(composerHeight, 0) + extraBreathingRoom
    }
}
