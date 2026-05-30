import SwiftUI
import UIKit

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
            scrollTask?.cancel()
            scrollTask = nil
        }
    }

    /// User initiated a manual upward scroll. Detach from bottom immediately
    /// so streaming auto-follow cannot pull the viewport back down mid-gesture.
    func detachFromBottomForUserScroll() {
        anchor.isNearBottom = false
        anchor.isFollowLocked = false
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

    /// CollectionView backend updates top visible item from scroll position.
    func updateTopVisibleItemId(_ itemId: String?) {
        guard anchor.topVisibleItemId != itemId else { return }
        anchor.topVisibleItemId = itemId
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

        // Re-entry should always land attached at the live bottom, even if the
        // previous visit left the controller detached while reading history.
        anchor.isNearBottom = true
        anchor.isFollowLocked = true
        isJumpToBottomHintVisible = false
        isDetachedStreamingHintVisible = false

        guard let bottomItemID else { return }
        performScrollToBottom(bottomItemID)
    }

    /// Called when `scrollTargetID` changes. Issues a scroll command
    /// synchronously — the actual scroll executes inside
    /// `Coordinator.apply()` after `dataSource.apply` + `layoutIfNeeded`.
    func handleScrollTarget(performScrollToTop: @escaping (String) -> Void) {
        guard let target = scrollTargetID else { return }
        scrollTargetID = nil
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
        anchor.isUserInteracting = false
        anchor.isFollowLocked = false
        anchor.contentOffsetY = 0
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
