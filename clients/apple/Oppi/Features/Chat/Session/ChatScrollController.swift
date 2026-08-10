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

    /// Throttle task for idle explicit scroll-to-bottom requests.
    /// Busy streaming/tool output is followed by the collection view's
    /// layout-time tail governor, not by timer-driven SwiftUI scroll commands.
    private var scrollTask: Task<Void, Never>?

    /// Last completed idle auto-scroll timestamp.
    private var lastAutoScrollAt: ContinuousClock.Instant?

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

    // MARK: - Tuning Constants

    /// Timelines with more items than this use conservative scroll timing.
    private let heavyTimelineThreshold = 120

    /// Non-streaming delay: less aggressive to reduce needless churn.
    private var nonStreamingDelay: Duration = .milliseconds(60)

    /// Keyboard animation settle time — suppress auto-scroll until layout settles.
    private var keyboardSettleDuration: Duration = .milliseconds(500)
    private var keyboardTransitionUntil: ContinuousClock.Instant?

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

    /// Item count for heavy-timeline gating. Set before each scroll decision.
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

    override init() {
        super.init()
        startKeyboardObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Keyboard Tracking

    private func startKeyboardObservers() {
        let center = NotificationCenter.default
        let names: [NSNotification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ]

        for name in names {
            center.addObserver(
                self,
                selector: #selector(handleKeyboardTransitionNotification(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func handleKeyboardTransitionNotification(_: Notification) {
        keyboardTransitionUntil = ContinuousClock.now.advanced(by: keyboardSettleDuration)
    }

    private var isKeyboardSettling: Bool {
        guard let keyboardTransitionUntil else { return false }
        if ContinuousClock.now < keyboardTransitionUntil {
            return true
        }
        self.keyboardTransitionUntil = nil
        return false
    }

    #if DEBUG
        // periphery:ignore - used by ChatScrollControllerTests via @testable import
        func useFastTimingForTesting() {
            nonStreamingDelay = .milliseconds(1)
            keyboardSettleDuration = .milliseconds(1)
        }

        // periphery:ignore - used by ChatScrollControllerTests via @testable import
        func expireKeyboardTransitionForTesting() {
            keyboardTransitionUntil = nil
        }
    #endif

    // MARK: - CollectionView Callbacks

    /// CollectionView backend updates nearBottom from scroll position math.
    func updateNearBottom(_ isNearBottom: Bool) {
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
        guard anchor.isUserInteracting != isInteracting else { return }
        anchor.isUserInteracting = isInteracting

        if isInteracting {
            navigationRestoration = nil
            scrollTask?.cancel()
            scrollTask = nil
        }
    }

    /// User initiated a manual upward scroll. Detach from bottom immediately
    /// so streaming auto-follow cannot pull the viewport back down mid-gesture.
    func detachFromBottomForUserScroll() {
        anchor.isNearBottom = false
        anchor.isFollowLocked = false
        navigationRestoration = nil
        scrollTask?.cancel()
        scrollTask = nil
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

    /// CollectionView backend updates top visible item from scroll position.
    func updateTopVisibleItemId(_ itemId: String?) {
        guard anchor.topVisibleItemId != itemId else { return }
        anchor.topVisibleItemId = itemId
    }

    /// Freeze the current navigation re-entry intent while cancelling only
    /// transient scroll work. A later permanent session change still calls
    /// `cancel()` and discards this snapshot.
    func suspendForNavigation() {
        scrollTask?.cancel()
        scrollTask = nil
        lastAutoScrollAt = nil
        keyboardTransitionUntil = nil
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

    // MARK: - Auto-Scroll on Content Change

    /// Called when idle content changes and a caller wants an explicit
    /// scroll-to-bottom command. Busy streaming/tool output is intentionally
    /// excluded: live updates are handled by the collection view's tail
    /// visibility governor after layout settles, not by timer-driven
    /// `scrollToItem` commands from SwiftUI.
    ///
    /// - Parameters:
    ///   - isBusy: Whether the agent session is active (streaming, thinking, tools).
    ///   - streamingAssistantID: Ignored while busy; retained for call-site compatibility.
    ///   - bottomItemID: ID of the last item to scroll to when idle.
    ///   - performScrollToBottom: Callback to execute the explicit scroll command.
    func handleContentChange(
        isBusy: Bool,
        streamingAssistantID _: String?,
        bottomItemID: String?,
        performScrollToBottom: @escaping (String) -> Void
    ) {
        guard !isBusy else { return }
        guard anchor.isNearBottom else { return }
        guard !anchor.isUserInteracting else { return }
        guard !isKeyboardSettling else { return }

        let isHeavy = itemCount >= heavyTimelineThreshold
        if isHeavy {
            return
        }

        // First-wins throttle: if a scroll is already scheduled, skip.
        guard scrollTask == nil else { return }
        guard let targetID = bottomItemID else { return }

        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: nonStreamingDelay)
            scrollTask = nil
            guard !Task.isCancelled else { return }
            guard anchor.isNearBottom else { return }
            guard !anchor.isUserInteracting else { return }
            guard !isKeyboardSettling else { return }

            performScrollToBottom(targetID)
            lastAutoScrollAt = ContinuousClock.now
        }
    }

    /// Called when `needsInitialScroll` becomes true. Issues a scroll
    /// command synchronously — the actual scroll executes inside
    /// `Coordinator.apply()` after `dataSource.apply` + `layoutIfNeeded`.
    func handleInitialScroll(bottomItemID: String?, performScrollToBottom: @escaping (String) -> Void) {
        guard needsInitialScroll else { return }
        needsInitialScroll = false

        // A detached same-session re-entry is restored through
        // `initialPlacement(availableFullTimelineItemIDs:bottomItemID:)`; this
        // compatibility helper must never silently convert detached reading state
        // to tail follow.
        guard case .none = navigationRestoration else { return }
        guard case .bottom(let itemID) = prepareBottomPlacement(bottomItemID: bottomItemID) else { return }
        performScrollToBottom(itemID)
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
        anchor.isNearBottom = true
        anchor.isFollowLocked = true
        isJumpToBottomHintVisible = false
        isDetachedStreamingHintVisible = false
        scrollToBottomNonce &+= 1
    }

    // MARK: - Cleanup

    func cancel() {
        scrollTask?.cancel()
        scrollTask = nil
        lastAutoScrollAt = nil
        keyboardTransitionUntil = nil
        anchor.isNearBottom = true
        anchor.isUserInteracting = false
        anchor.isFollowLocked = false
        anchor.topVisibleItemId = nil
        anchor.contentOffsetY = 0
        timelineItemOrder = []
        latestViewportSnapshot = nil
        navigationRestoration = nil
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
