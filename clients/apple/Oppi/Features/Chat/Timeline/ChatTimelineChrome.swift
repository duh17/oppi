import SwiftUI

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
/// bar, and the context bar sits below that bar. `header.maxY - timeline.minY`
/// then covers the bar and the chrome above it, and follows any change to
/// either.
enum ChatTimelineChromeOverlap {
    static func topInset(timelineFrame: CGRect, headerFrame: CGRect) -> CGFloat {
        if timelineFrame == .zero, headerFrame == .zero {
            return 0
        }
        return max(0, headerFrame.maxY - timelineFrame.minY)
    }
}

/// The empty state stays a SwiftUI view, hosted as the collection background
/// by the controller, which observes `reducer.items` itself.
private struct ChatTimelineEmptyOverlay: View {
    var sessionId: String
    var agentId: String?
    var agentIcon: IconChoice?
    var topOverlap: CGFloat
    var bottomOverlap: CGFloat

    var body: some View {
        ChatEmptyState(
            sessionId: sessionId,
            agentId: agentId,
            agentIcon: agentIcon
        )
        .padding(.top, topOverlap)
        .padding(.bottom, bottomOverlap)
    }
}

extension ChatTimelineController {
    func updateOwnedEmptyOverlay(
        isEmpty: Bool,
        configuration: ChatTimelineConfiguration,
        collectionView: UICollectionView
    ) {
        let shouldShow = isEmpty && !configuration.isBusy
        let overlay = ChatTimelineEmptyOverlay(
            sessionId: configuration.sessionId,
            agentId: configuration.agentId,
            agentIcon: configuration.agentIcon,
            topOverlap: configuration.topOverlap,
            bottomOverlap: configuration.bottomOverlap
        )
        if shouldShow {
            if let host = ownedClock.emptyOverlayController as? HostedContentController {
                host.setContent(overlay)
                if collectionView.backgroundView !== host.view {
                    collectionView.backgroundView = host.view
                }
            } else {
                let host = HostFactory.content(overlay, root: contentRoot)
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = false
                collectionView.backgroundView = host.view
                ownedClock.emptyOverlayController = host
            }
        } else if ownedClock.emptyOverlayController != nil {
            collectionView.backgroundView = nil
            ownedClock.emptyOverlayController = nil
        }
    }
}
