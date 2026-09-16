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

/// The chat collection view ignores the top safe area so rows can scroll
/// under Liquid Glass. `contentInsetAdjustmentBehavior` is `.never` because
/// SwiftUI zeros the UIKit safe area on that expanded view.
///
/// Named-space frames often share the safe-area origin instead of starting
/// at 0 under the nav. In that case `header.maxY - timeline.minY` is only
/// the branch chip, and pull-to-top cannot uncover the first row. Add the
/// SwiftUI safe-area gap when both frames share `minY`.
enum ChatTimelineChromeOverlap {
    static let coordinateSpaceName = "chatTimelineChrome"

    static func topInset(
        timelineFrame: CGRect,
        headerFrame: CGRect,
        safeAreaTop: CGFloat = 0
    ) -> CGFloat {
        if timelineFrame == .zero, headerFrame == .zero {
            return 0
        }

        let headerBottom = max(0, headerFrame.maxY - timelineFrame.minY)
        if safeAreaTop > 0, abs(headerFrame.minY - timelineFrame.minY) < 1 {
            return headerBottom + safeAreaTop
        }
        return headerBottom
    }

    /// Keep overlay measurement on the bar's ideal height, not a full-screen
    /// `ZStack` proposal from `.overlay(alignment: .top)`.
    struct HuggingHeader: ViewModifier {
        func body(content: Content) -> some View {
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// Extracted from ChatView so that @State inputText changes (every keystroke)
/// do NOT rebuild the timeline host.
///
/// Streaming is not this view's clock. The collection controller observes
/// `TimelineReducer` and owns Quiet projection, render window, and settled
/// ends. `body` must not read `reducer.items` or `renderVersion`.
struct ChatTimelineView: View {
    private static let renderWindowStep = TimelineRenderWindowPolicy.renderWindowStep

    let sessionId: String
    let serverId: String?
    let workspaceId: String?
    var agentId: String? = nil
    var agentIcon: IconChoice? = nil
    var routeScope: SessionRouteScope?
    let isBusy: Bool
    let extensionWorkingState: ExtensionWorkingState?
    let extensionHiddenThinkingLabel: String?
    let currentModel: String?
    let connection: ServerConnection
    let scrollController: ChatScrollController
    let sessionManager: ChatSessionManager
    let audioLifecycleCoordinator: AudioLifecycleCoordinator?
    var quietModeEnabled: Bool = false
    var workStripStyle: AppPreferences.ChatDisplay.WorkStripStyle = .icons
    let onFork: (String) -> Void
    let onOpenCurrentFile: (String) -> Void
    var onOpenChatReader: (ChatReaderPayload) -> Void = { _ in }
    let onBackSwipe: () -> Void
    let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    let topOverlap: CGFloat
    let bottomOverlap: CGFloat
    var onVisibleAudioStripItemIDsChange: ((Set<String>) -> Void)? = nil
    var outlineAvailability: ChatTimelineOutlineAvailability? = nil

    @Environment(TimelineReducer.self) private var reducer
    @Environment(AudioPlayerService.self) private var audioPlayer

    private var showsWorkingIndicator: Bool {
        isBusy && (extensionWorkingState?.visible ?? true)
    }

    var body: some View {
        ChatTimelineCollectionHost(
            configuration: .init(
                items: [],
                hiddenCount: 0,
                renderWindowStep: Self.renderWindowStep,
                isBusy: isBusy,
                showsWorkingIndicator: showsWorkingIndicator,
                streamingAssistantID: nil,
                sessionId: sessionId,
                serverId: serverId,
                workspaceId: workspaceId,
                agentId: agentId,
                agentIcon: agentIcon,
                routeScope: routeScope,
                onFork: onFork,
                onOpenCurrentFile: onOpenCurrentFile,
                onOpenChatReader: onOpenChatReader,
                onBackSwipe: onBackSwipe,
                onShowEarlier: {},
                scrollController: scrollController,
                reducer: reducer,
                toolOutputStore: reducer.toolOutputStore,
                toolArgsStore: reducer.toolArgsStore,
                toolSegmentStore: reducer.toolSegmentStore,
                toolDetailsStore: reducer.toolDetailsStore,
                connection: connection,
                currentModel: currentModel,
                extensionWorkingState: extensionWorkingState,
                extensionHiddenThinkingLabel: extensionHiddenThinkingLabel,
                audioPlayer: audioPlayer,
                audioLifecycleCoordinator: audioLifecycleCoordinator,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                topOverlap: topOverlap,
                bottomOverlap: bottomOverlap,
                onVisibleAudioStripItemIDsChange: onVisibleAudioStripItemIDsChange,
                ownsTimelineProjection: true,
                quietModeEnabled: quietModeEnabled,
                workStripStyle: workStripStyle,
                sessionManager: sessionManager,
                outlineAvailability: outlineAvailability
            )
        )
        .background(.themeBg)
    }
}

/// Empty overlay stays a SwiftUI view, hosted as the collection background so
/// `ChatTimelineView.body` does not observe `reducer.items`.
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

extension ChatTimelineCollectionHost.Controller {
    func updateOwnedEmptyOverlay(
        isEmpty: Bool,
        configuration: ChatTimelineCollectionHost.Configuration,
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
            if let host = ownedClock.emptyOverlayController as? UIHostingController<ChatTimelineEmptyOverlay> {
                host.rootView = overlay
                if collectionView.backgroundView !== host.view {
                    collectionView.backgroundView = host.view
                }
            } else {
                let host = UIHostingController(rootView: overlay)
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
