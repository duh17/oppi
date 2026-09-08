import SwiftUI

/// Mac timeline follow policy: stay pinned to the latest row while the user
/// is near the bottom. Geometry math lives here so OppiMacTests can cover it
/// without embedding UIKit's chat scroller.
/// Pane-owned timeline viewport. Retiling must restore this instead of
/// remounting a detached scroller at the top.
struct MacSessionTimelineViewport: Equatable, Sendable {
    var offsetY: Double = 0
    var anchorID: String? = nil
}

enum MacSessionTimelineRemountTarget: Equatable, Sendable {
    case latest
    case anchor(String, offsetY: Double)
    case offset(Double)
    case top
}

enum MacSessionTimelineRestoreCommand: Equatable, Sendable {
    case latest
    case rowStart(String)
    case contentOffset(Double)
    case none
}

struct MacSessionTimelineRemountRestoreDecision: Equatable, Sendable {
    var pending: MacSessionTimelineRemountTarget?
    var applyRestore: Bool
    var holdRestore: Bool
}

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

    /// Inspector open/close changes timeline width and reflows wrapping.
    /// That can grow `contentHeight` without new rows; treating it as document
    /// growth retriggers follow-scroll and AppKit constraint passes.
    static func contentHeightIncreasedFromDocumentGrowth(
        previousHeight: CGFloat,
        nextHeight: CGFloat,
        previousViewportWidth: CGFloat,
        nextViewportWidth: CGFloat
    ) -> Bool {
        guard nextHeight > previousHeight else { return false }
        if previousViewportWidth == 0 {
            return true
        }
        return measurementsMatch(previousViewportWidth, nextViewportWidth)
    }

    static func measurementsMatch(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    static func shouldScrollToLatestRow(isAttached: Bool) -> Bool {
        isAttached
    }

    static func recordedViewport(
        offsetY: Double,
        anchorID: String?,
        isAttached: Bool
    ) -> MacSessionTimelineViewport {
        MacSessionTimelineViewport(
            offsetY: max(offsetY, 0),
            anchorID: isAttached ? latestAnchorID : anchorID
        )
    }

    static func remountScrollTarget(
        isAttached: Bool,
        viewport: MacSessionTimelineViewport,
        availableAnchorIDs: Set<String>? = nil
    ) -> MacSessionTimelineRemountTarget {
        if isAttached {
            return .latest
        }
        if let anchorID = viewport.anchorID,
           !anchorID.isEmpty,
           anchorID != latestAnchorID,
           availableAnchorIDs?.contains(anchorID) ?? true {
            return .anchor(anchorID, offsetY: viewport.offsetY)
        }
        if viewport.offsetY > 0.5 {
            return .offset(viewport.offsetY)
        }
        return .top
    }

    /// Restore command for a remount target. An anchored row with a stored
    /// offset must keep that offset; `.top` of the row would jump the user.
    static func restoreCommand(
        for target: MacSessionTimelineRemountTarget
    ) -> MacSessionTimelineRestoreCommand {
        switch target {
        case .latest:
            .latest
        case .anchor(let id, let offsetY):
            offsetY > 0.5 ? .contentOffset(offsetY) : .rowStart(id)
        case .offset(let offsetY):
            .contentOffset(offsetY)
        case .top:
            .none
        }
    }

    /// Explicit Latest or outline navigation owns the viewport. Drop any
    /// pending remount restore so later achievable geometry cannot reapply
    /// the pre-navigation offset.
    static func pendingRemountTargetAfterExplicitNavigation(
        _ pending: MacSessionTimelineRemountTarget?
    ) -> MacSessionTimelineRemountTarget? {
        switch pending {
        case .latest, .anchor, .offset, .top, nil:
            nil
        }
    }

    /// Keep a remount restore until the saved offset is reachable. A short
    /// first geometry frame would otherwise no-op `scrollTo(y:)`, look
    /// near-bottom, and reattach live-tail so later growth jumps to latest.
    static func remountRestoreDecision(
        pending: MacSessionTimelineRemountTarget?,
        contentHeight: CGFloat,
        offsetY: CGFloat,
        viewportHeight: CGFloat
    ) -> MacSessionTimelineRemountRestoreDecision {
        guard let pending else {
            return MacSessionTimelineRemountRestoreDecision(
                pending: nil,
                applyRestore: false,
                holdRestore: false
            )
        }
        guard let requested = requestedRestoreOffset(for: pending) else {
            return MacSessionTimelineRemountRestoreDecision(
                pending: nil,
                applyRestore: false,
                holdRestore: false
            )
        }
        if measurementsMatch(offsetY, CGFloat(requested)) {
            return MacSessionTimelineRemountRestoreDecision(
                pending: nil,
                applyRestore: false,
                holdRestore: false
            )
        }
        if isRestoreOffsetAchievable(
            offsetY: requested,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        ) {
            return MacSessionTimelineRemountRestoreDecision(
                pending: nil,
                applyRestore: true,
                holdRestore: true
            )
        }
        return MacSessionTimelineRemountRestoreDecision(
            pending: pending,
            applyRestore: false,
            holdRestore: true
        )
    }

    private static func requestedRestoreOffset(
        for target: MacSessionTimelineRemountTarget
    ) -> Double? {
        switch target {
        case .offset(let offsetY) where offsetY > 0.5:
            offsetY
        case .anchor(_, let offsetY) where offsetY > 0.5:
            offsetY
        default:
            nil
        }
    }

    private static func isRestoreOffsetAchievable(
        offsetY: Double,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        guard contentHeight > 1, viewportHeight > 1 else { return false }
        let maxOffset = max(0, contentHeight - viewportHeight)
        return CGFloat(offsetY) <= maxOffset + 0.5
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
