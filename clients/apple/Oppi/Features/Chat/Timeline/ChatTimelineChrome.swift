import UIKit

enum TimelineRenderWindowPolicy {
    enum ShowEarlierAction: Equatable {
        case revealLocal(newWindow: Int)
        case fetchOlderPage
        case none
    }

    static let standardWindow = 80
    static let renderWindowStep = 60

    static func syncedWindow(currentWindow: Int, totalItems: Int) -> Int {
        let clampedTotal = max(0, totalItems)
        let clampedCurrent = min(max(0, currentWindow), clampedTotal)
        let baseline = min(clampedTotal, standardWindow)
        return max(clampedCurrent, baseline)
    }

    static func showsShowEarlierControl(hiddenCount: Int, hasOlderServerPage: Bool) -> Bool {
        hiddenCount > 0 || hasOlderServerPage
    }

    static func showEarlierAction(
        currentWindow: Int,
        totalItems: Int,
        step: Int,
        hasOlderServerPage: Bool
    ) -> ShowEarlierAction {
        let clampedTotal = max(0, totalItems)
        let clampedCurrent = min(max(0, currentWindow), clampedTotal)
        if clampedCurrent < clampedTotal {
            return .revealLocal(newWindow: min(clampedTotal, clampedCurrent + max(1, step)))
        }
        return hasOlderServerPage ? .fetchOlderPage : .none
    }
}
/// The chat collection view reaches up under the navigation bar so rows can
/// scroll under Liquid Glass, with `contentInsetAdjustmentBehavior` `.never`.
///
/// The overlap is measured from frames, never from a safe-area inset. Both
/// frames are in window coordinates: the timeline starts under the navigation
/// bar, and the header is the top of the safe area below that bar.
/// `header.maxY - timeline.minY` then covers the bar and the chrome above it,
/// and follows any change to either.
enum ChatTimelineChromeOverlap {
    static func topInset(timelineFrame: CGRect, headerFrame: CGRect) -> CGFloat {
        if timelineFrame == .zero, headerFrame == .zero {
            return 0
        }
        return max(0, headerFrame.maxY - timelineFrame.minY)
    }
}
