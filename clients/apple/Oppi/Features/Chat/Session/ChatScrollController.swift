import SwiftUI
import UIKit

struct TimelineViewportSnapshot: Equatable {
    let anchorItemID: String
    let anchorRelativeY: CGFloat
    /// The complete timeline order, not the currently rendered suffix window.
    let fullTimelineItemIDs: [String]
    /// The anchor's absolute ordinal in `fullTimelineItemIDs`.
    let anchorOrdinal: Int

    init(anchorItemID: String, anchorRelativeY: CGFloat, fullTimelineItemIDs: [String]) {
        self.anchorItemID = anchorItemID
        self.anchorRelativeY = anchorRelativeY
        self.fullTimelineItemIDs = fullTimelineItemIDs
        anchorOrdinal = fullTimelineItemIDs.firstIndex(of: anchorItemID) ?? 0
    }
}

struct TimelineViewportRestoration: Equatable {
    let itemID: String
    let relativeY: CGFloat
}

struct TimelineImagePreviewPreservation {
    let token: UInt
    let snapshot: TimelineViewportSnapshot?
}

enum TimelineInitialPlacement: Equatable {
    case bottom(itemID: String)
    case viewport(TimelineViewportRestoration)
}

enum TimelineViewportRestorationResolver {
    static func resolve(
        _ snapshot: TimelineViewportSnapshot,
        availableFullTimelineItemIDs: [String]
    ) -> TimelineViewportRestoration? {
        guard !availableFullTimelineItemIDs.isEmpty else { return nil }
        let available = Set(availableFullTimelineItemIDs)

        if available.contains(snapshot.anchorItemID) {
            return TimelineViewportRestoration(
                itemID: snapshot.anchorItemID,
                relativeY: snapshot.anchorRelativeY
            )
        }

        // Prefer any surviving following context over all preceding context.
        // This keeps the same reading direction even when the nearest item on
        // the preceding side is closer than the nearest surviving following row.
        let followingStart = snapshot.anchorOrdinal + 1
        if followingStart < snapshot.fullTimelineItemIDs.count {
            for index in followingStart..<snapshot.fullTimelineItemIDs.count {
                let followingID = snapshot.fullTimelineItemIDs[index]
                if available.contains(followingID) {
                    return TimelineViewportRestoration(
                        itemID: followingID,
                        relativeY: snapshot.anchorRelativeY
                    )
                }
            }
        }

        if snapshot.anchorOrdinal > 0 {
            let precedingStart = min(
                snapshot.anchorOrdinal - 1,
                snapshot.fullTimelineItemIDs.count - 1
            )
            for index in stride(from: precedingStart, through: 0, by: -1) {
                let precedingID = snapshot.fullTimelineItemIDs[index]
                if available.contains(precedingID) {
                    return TimelineViewportRestoration(
                        itemID: precedingID,
                        relativeY: snapshot.anchorRelativeY
                    )
                }
            }
        }

        // `anchorOrdinal` is absolute in the full timeline. The available IDs
        // must use that same full-timeline coordinate system; a rendered suffix
        // window would turn this fallback into a window-relative jump.
        let fallbackIndex = min(
            max(0, snapshot.anchorOrdinal),
            availableFullTimelineItemIDs.count - 1
        )
        return TimelineViewportRestoration(
            itemID: availableFullTimelineItemIDs[fallbackIndex],
            relativeY: snapshot.anchorRelativeY
        )
    }

    static func resolveRenderedWindow(
        _ restoration: TimelineViewportRestoration,
        availableFullTimelineItemIDs: [String],
        renderedTimelineItemIDs: [String],
        renderedIDForFullTimelineItemID: ((String) -> String?)? = nil
    ) -> TimelineViewportRestoration? {
        let rendered = Set(renderedTimelineItemIDs)
        guard !rendered.isEmpty,
              let targetOrdinal = availableFullTimelineItemIDs.firstIndex(of: restoration.itemID) else {
            return nil
        }

        if rendered.contains(restoration.itemID) {
            return restoration
        }
        if let renderedID = renderedIDForFullTimelineItemID?(restoration.itemID),
           rendered.contains(renderedID) {
            return TimelineViewportRestoration(
                itemID: renderedID,
                relativeY: restoration.relativeY
            )
        }

        if targetOrdinal + 1 < availableFullTimelineItemIDs.count {
            for index in (targetOrdinal + 1)..<availableFullTimelineItemIDs.count {
                let itemID = availableFullTimelineItemIDs[index]
                if rendered.contains(itemID) {
                    return TimelineViewportRestoration(
                        itemID: itemID,
                        relativeY: restoration.relativeY
                    )
                }
                if let renderedID = renderedIDForFullTimelineItemID?(itemID),
                   rendered.contains(renderedID) {
                    return TimelineViewportRestoration(
                        itemID: renderedID,
                        relativeY: restoration.relativeY
                    )
                }
            }
        }

        if targetOrdinal > 0 {
            for index in stride(from: targetOrdinal - 1, through: 0, by: -1) {
                let itemID = availableFullTimelineItemIDs[index]
                if rendered.contains(itemID) {
                    return TimelineViewportRestoration(
                        itemID: itemID,
                        relativeY: restoration.relativeY
                    )
                }
                if let renderedID = renderedIDForFullTimelineItemID?(itemID),
                   rendered.contains(renderedID) {
                    return TimelineViewportRestoration(
                        itemID: renderedID,
                        relativeY: restoration.relativeY
                    )
                }
            }
        }

        return nil
    }
}

/// Manages scroll behavior for the chat timeline.
///
/// Coordinates auto-follow (scroll to bottom as content grows), user
/// detach (stop following when user scrolls up), and re-attach (resume
/// following when user taps jump-to-bottom or sends a message).
///
/// Uses a non-reactive `ScrollAnchorState` class to avoid SwiftUI
/// body re-evaluation feedback loops from sentinel visibility changes.
@MainActor @Observable
final class ChatScrollController: NSObject {
    /// Non-reactive anchor — mutations are invisible to SwiftUI observation.
    private let anchor = ScrollAnchorState()

    private enum NavigationRestoration {
        case liveTail
        case viewport(TimelineViewportSnapshot)
    }

    /// Current stable item order and viewport anchor are kept in the chat's
    /// state owner, not the pushed document view, so either back path can use
    /// the same re-entry restoration.
    private var timelineItemOrder: [String] = []
    private var latestViewportSnapshot: TimelineViewportSnapshot?
    private var navigationRestoration: NavigationRestoration?
    /// Modal image previews freeze the reader's attached/detached intent while
    /// UIKit presents over the timeline. The preview coordinator owns geometry
    /// restoration; this guard prevents passive layout callbacks from changing
    /// that intent while the chat cannot receive touches.
    private var imagePreviewGeneration: UInt = 0
    private var activeImagePreviewPreservation: (token: UInt, wasAttachedToTail: Bool)?

    /// Set by outline view to scroll to a specific item.
    var scrollTargetID: String?

    /// Next timeline item that should receive a transient visual emphasis after
    /// programmatic navigation lands on it.
    private(set) var pendingNavigationHighlightItemID: String?

    /// Monotonic token for navigation highlight requests. Lets the collection
    /// view treat repeated jumps to the same row as distinct highlight events.
    private(set) var pendingNavigationHighlightNonce: UInt = 0

    /// Shows a subtle "live updates" hint while streaming continues off-screen.
    var isDetachedStreamingHintVisible = false

    /// Shows a compact jump-to-bottom affordance whenever user is detached.
    var isJumpToBottomHintVisible = false

    /// Set after initial history load to trigger scroll-to-bottom.
    var needsInitialScroll = false

    /// Incremented when the user sends a message and we need to scroll
    /// to the bottom. ChatTimelineView observes this via `.onChange`.
    var scrollToBottomNonce: UInt = 0

    // MARK: - Scroll Position (Non-Reactive)

    /// Current topmost visible item ID. For saving to restoration state.
    var currentTopVisibleItemId: String? {
        anchor.topVisibleItemId
    }

    /// Current visual vertical offset (`contentOffset.y + adjusted top inset`).
    ///
    /// Stored non-reactively for harness diagnostics so tests can read exact
    /// scroll movement after gesture drags without reintroducing SwiftUI body
    /// feedback loops on every scroll tick.
    var currentContentOffsetY: CGFloat {
        anchor.contentOffsetY
    }

    /// Whether the user is currently scrolled to the bottom.
    var isCurrentlyNearBottom: Bool {
        anchor.isNearBottom
    }

    /// Real touch/deceleration ownership reported by the timeline delegate.
    /// Ambient restoration must not mutate logical or physical scroll state
    /// while this is true, even when UIKit's gesture flags have already changed.
    var isUserInteracting: Bool {
        anchor.isUserInteracting
    }

    /// Item count used to detect newly appended timeline items.
    var itemCount: Int = 0 {
        didSet {
            if itemCount > oldValue, oldValue > 0 {
                hasNewItems = true
            }
        }
    }

    /// Set to `true` when new items are appended. Consumed by the scroll
    /// callback to decide whether `scrollToItem` should animate.
    /// Reset after each scroll command.
    private(set) var hasNewItems = false

    /// Consume the `hasNewItems` flag, returning its value and resetting it.
    func consumeHasNewItems() -> Bool {
        defer { hasNewItems = false }
        return hasNewItems
    }

    // MARK: - CollectionView Callbacks

    /// CollectionView backend updates nearBottom from scroll position math.
    func updateNearBottom(_ isNearBottom: Bool) {
        if let activeImagePreviewPreservation,
           activeImagePreviewPreservation.wasAttachedToTail != isNearBottom {
            return
        }

        if !isNearBottom, anchor.isFollowLocked {
            // Preserve follow after an explicit user send/jump-to-latest.
            // Only explicit user upward scroll may detach while locked.
            return
        }

        guard anchor.isNearBottom != isNearBottom else { return }
        anchor.isNearBottom = isNearBottom
    }

    /// CollectionView backend marks active user drag/deceleration windows.
    func setUserInteracting(_ isInteracting: Bool) {
        if isInteracting {
            // Treat every reported touch begin as a new ownership boundary,
            // even if UIKit repeats the callback while interaction is active.
            navigationRestoration = nil
            activeImagePreviewPreservation = nil
        }

        guard anchor.isUserInteracting != isInteracting else { return }
        anchor.isUserInteracting = isInteracting
    }

    /// User initiated a manual upward scroll. Detach from bottom immediately
    /// so streaming auto-follow cannot pull the viewport back down mid-gesture.
    func detachFromBottomForUserScroll() {
        anchor.isNearBottom = false
        anchor.isFollowLocked = false
        navigationRestoration = nil
        activeImagePreviewPreservation = nil
    }

    /// CollectionView backend updates visibility for the detached streaming hint.
    func setDetachedStreamingHintVisible(_ isVisible: Bool) {
        guard isDetachedStreamingHintVisible != isVisible else { return }
        isDetachedStreamingHintVisible = isVisible
    }

    /// CollectionView backend updates visibility for jump-to-bottom affordance.
    func setJumpToBottomHintVisible(_ isVisible: Bool) {
        guard isJumpToBottomHintVisible != isVisible else { return }
        isJumpToBottomHintVisible = isVisible
    }

    /// CollectionView backend updates the complete stable timeline order after
    /// a structural snapshot change. Synthetic load-more/working rows are
    /// omitted, and this must not be replaced with the rendered suffix window.
    func updateTimelineItemOrder(_ itemIDs: [String]) {
        timelineItemOrder = itemIDs
    }

    /// CollectionView backend updates the stable visible anchor and its exact
    /// screen-relative Y. This is cheap on scroll: the item order is copied only
    /// when the diffable snapshot changes.
    func updateViewportAnchor(itemID: String?, relativeY: CGFloat?) {
        updateTopVisibleItemId(itemID)
        guard let itemID, let relativeY, relativeY.isFinite else { return }
        latestViewportSnapshot = TimelineViewportSnapshot(
            anchorItemID: itemID,
            anchorRelativeY: relativeY,
            fullTimelineItemIDs: timelineItemOrder
        )
    }

    func beginImagePreviewViewportPreservation(
        wasAttachedToTail: Bool
    ) -> TimelineImagePreviewPreservation {
        imagePreviewGeneration &+= 1
        let token = imagePreviewGeneration
        activeImagePreviewPreservation = (token, wasAttachedToTail)
        return TimelineImagePreviewPreservation(
            token: token,
            snapshot: wasAttachedToTail ? nil : latestViewportSnapshot
        )
    }

    func ownsImagePreviewViewportPreservation(_ token: UInt) -> Bool {
        activeImagePreviewPreservation?.token == token
    }

    func endImagePreviewViewportPreservation(_ token: UInt) {
        guard activeImagePreviewPreservation?.token == token else { return }
        activeImagePreviewPreservation = nil
    }

    /// CollectionView backend updates top visible item from scroll position.
    func updateTopVisibleItemId(_ itemId: String?) {
        guard anchor.topVisibleItemId != itemId else { return }
        anchor.topVisibleItemId = itemId
    }

    /// Freeze the current navigation re-entry intent while cancelling only
    /// transient scroll work. A later permanent session change still calls
    /// `cancel()` and discards this snapshot.
    func suspendForNavigation() {
        anchor.isUserInteracting = false
        anchor.isFollowLocked = false
        isDetachedStreamingHintVisible = false
        isJumpToBottomHintVisible = false
        pendingNavigationHighlightItemID = nil

        // A route preflight captures live collection geometry before the push.
        // Arm re-entry here rather than waiting for a reconnect flag: NavigationStack
        // can rebuild the collection without republishing session history.
        needsInitialScroll = true

        // The later onDisappear cleanup must not overwrite that frozen intent.
        guard navigationRestoration == nil else { return }

        if anchor.isNearBottom {
            navigationRestoration = .liveTail
        } else if let latestViewportSnapshot {
            navigationRestoration = .viewport(latestViewportSnapshot)
        }
    }

    /// Resolve one initial placement after cache/fresh history publication.
    /// Navigation restoration remains armed until the user explicitly moves,
    /// allowing a later authoritative history refresh to restore the same
    /// stable context again instead of reverting to the tail.
    /// `availableFullTimelineItemIDs` must be the full timeline order, not the
    /// currently rendered suffix window.
    func initialPlacement(
        availableFullTimelineItemIDs: [String],
        bottomItemID: String?
    ) -> TimelineInitialPlacement? {
        guard needsInitialScroll else { return nil }
        guard !availableFullTimelineItemIDs.isEmpty || bottomItemID != nil else { return nil }

        switch navigationRestoration {
        case .liveTail:
            needsInitialScroll = false
            return prepareBottomPlacement(bottomItemID: bottomItemID)
        case .viewport(let snapshot):
            guard let restoration = TimelineViewportRestorationResolver.resolve(
                snapshot,
                availableFullTimelineItemIDs: availableFullTimelineItemIDs
            ) else {
                return nil
            }
            needsInitialScroll = false
            anchor.isNearBottom = false
            anchor.isFollowLocked = false
            isJumpToBottomHintVisible = true
            return .viewport(restoration)
        case nil:
            needsInitialScroll = false
            return prepareBottomPlacement(bottomItemID: bottomItemID)
        }
    }

    private func prepareBottomPlacement(bottomItemID: String?) -> TimelineInitialPlacement? {
        anchor.isNearBottom = true
        anchor.isFollowLocked = true
        isJumpToBottomHintVisible = false
        isDetachedStreamingHintVisible = false
        guard let bottomItemID else { return nil }
        return .bottom(itemID: bottomItemID)
    }

    /// CollectionView backend updates precise visual offset for diagnostics.
    func updateContentOffsetY(_ value: CGFloat) {
        anchor.contentOffsetY = value
    }

    /// Called when `scrollTargetID` changes. Issues a scroll command
    /// synchronously — the actual scroll executes inside
    /// `Coordinator.apply()` after `dataSource.apply` + `layoutIfNeeded`.
    func handleScrollTarget(performScrollToTop: @escaping (String) -> Void) {
        guard let target = scrollTargetID else { return }
        scrollTargetID = nil
        navigationRestoration = nil
        requestNavigationHighlight(for: target)
        performScrollToTop(target)
    }

    func requestNavigationHighlight(for itemID: String) {
        pendingNavigationHighlightItemID = itemID
        pendingNavigationHighlightNonce &+= 1
    }

    func navigationHighlightTokenIfNeeded(for itemID: String) -> UInt? {
        guard pendingNavigationHighlightItemID == itemID else { return nil }
        return pendingNavigationHighlightNonce
    }

    func clearNavigationHighlightIfNeeded(for itemID: String, token: UInt) {
        guard pendingNavigationHighlightItemID == itemID,
              pendingNavigationHighlightNonce == token else {
            return
        }
        pendingNavigationHighlightItemID = nil
    }

    func consumeNavigationHighlightIfNeeded(for itemID: String) -> UInt? {
        guard let token = navigationHighlightTokenIfNeeded(for: itemID) else { return nil }
        pendingNavigationHighlightItemID = nil
        return token
    }

    // MARK: - Imperative Scroll

    /// Request scroll to bottom (e.g. after sending a message).
    /// Re-attaches and temporarily locks follow so passive layout/content
    /// shifts cannot detach until the user explicitly scrolls up.
    func requestScrollToBottom() {
        navigationRestoration = nil
        activeImagePreviewPreservation = nil
        anchor.isNearBottom = true
        anchor.isFollowLocked = true
        isJumpToBottomHintVisible = false
        isDetachedStreamingHintVisible = false
        scrollToBottomNonce &+= 1
    }

    // MARK: - Cleanup

    func cancel() {
        anchor.isNearBottom = true
        anchor.isUserInteracting = false
        anchor.isFollowLocked = false
        anchor.topVisibleItemId = nil
        anchor.contentOffsetY = 0
        timelineItemOrder = []
        latestViewportSnapshot = nil
        navigationRestoration = nil
        activeImagePreviewPreservation = nil
        isDetachedStreamingHintVisible = false
        isJumpToBottomHintVisible = false
        pendingNavigationHighlightItemID = nil
    }
}

// MARK: - Scroll Anchor (non-reactive)

/// Tracks scroll state without triggering SwiftUI observation.
///
/// Deliberately NOT `@Observable` — mutations must NOT trigger body
/// re-evaluations. A reactive version creates a feedback loop:
/// sentinel flickers -> state change -> body re-eval -> layout -> loop.
private final class ScrollAnchorState {
    var isNearBottom = true
    var isUserInteracting = false
    var isFollowLocked = false
    var topVisibleItemId: String?
    var contentOffsetY: CGFloat = 0
}
