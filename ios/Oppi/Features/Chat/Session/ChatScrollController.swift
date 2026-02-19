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
final class ChatScrollController {
    /// Non-reactive anchor — mutations are invisible to SwiftUI observation.
    private let anchor = ScrollAnchorState()

    /// Throttle task for scroll-to-bottom during streaming.
    /// Uses "first-wins" throttle: if a scroll is scheduled, subsequent
    /// triggers are no-ops. This prevents cancel loops during 33ms streaming
    /// where a debounce pattern (cancel + reschedule) would never fire.
    private var scrollTask: Task<Void, Never>?

    /// Last completed auto-scroll timestamp.
    private var lastAutoScrollAt: ContinuousClock.Instant?

    // MARK: - Tuning Constants

    /// Timelines with more items than this use conservative scroll timing.
    private let heavyTimelineThreshold = 120

    /// Streaming auto-scroll delay: responsive enough to follow live tokens.
    private let streamingDelay: Duration = .milliseconds(33)

    /// Non-streaming delay: less aggressive to reduce needless churn.
    private let nonStreamingDelay: Duration = .milliseconds(60)

    /// Heavy timeline streaming: smooth but bounded.
    private let heavyStreamingDelay: Duration = .milliseconds(80)
    private let heavyStreamingMinInterval: Duration = .milliseconds(120)

    /// Keyboard animation settle time — suppress auto-scroll until layout settles.
    private let keyboardSettleDuration: Duration = .milliseconds(500)
    private var keyboardTransitionUntil: ContinuousClock.Instant?
    nonisolated(unsafe) private var keyboardObservers: [NSObjectProtocol] = []

    /// Set by outline view to scroll to a specific item.
    var scrollTargetID: String?

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

    init() {
        startKeyboardObservers()
    }

    deinit {
        let center = NotificationCenter.default
        for token in keyboardObservers {
            center.removeObserver(token)
        }
    }

    // MARK: - Keyboard Tracking

    private func startKeyboardObservers() {
        let center = NotificationCenter.default
        let names: [NSNotification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ]

        keyboardObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.keyboardTransitionUntil = ContinuousClock.now.advanced(by: self.keyboardSettleDuration)
                }
            }
        }
    }

    private var isKeyboardSettling: Bool {
        guard let keyboardTransitionUntil else { return false }
        if ContinuousClock.now < keyboardTransitionUntil {
            return true
        }
        self.keyboardTransitionUntil = nil
        return false
    }

    // MARK: - CollectionView Callbacks

    /// CollectionView backend updates nearBottom from scroll position math.
    func updateNearBottom(_ isNearBottom: Bool) {
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

    // MARK: - Auto-Scroll on Content Change

    /// Called when `renderVersion` changes. Schedules a throttled scroll
    /// if the user is near the bottom and not interacting.
    ///
    /// - Parameters:
    ///   - isBusy: Whether the agent session is active (streaming, thinking, tools).
    ///   - streamingAssistantID: ID of the currently streaming assistant message, if any.
    ///   - bottomItemID: ID of the last item (or working indicator) to scroll to.
    ///   - performScrollToBottom: Callback to execute the actual scroll command.
    func handleContentChange(
        isBusy: Bool,
        streamingAssistantID: String?,
        bottomItemID: String?,
        performScrollToBottom: @escaping (String) -> Void
    ) {
        guard anchor.isNearBottom else { return }
        guard !anchor.isUserInteracting else { return }
        guard !isKeyboardSettling else { return }

        let isHeavy = itemCount >= heavyTimelineThreshold
        let isActive = isBusy  // agent is doing something — always auto-scroll

        // In heavy timelines, only auto-scroll when the agent is active.
        // Idle content changes (e.g. late reconfigures) are skipped to
        // avoid expensive layout cascades.
        if isHeavy, !isActive {
            return
        }

        // First-wins throttle: if a scroll is already scheduled, skip.
        guard scrollTask == nil else { return }

        // Rate-limit heavy timeline streaming.
        if isHeavy,
           let lastAutoScrollAt,
           ContinuousClock.now - lastAutoScrollAt < heavyStreamingMinInterval {
            return
        }

        // Determine scroll target: streaming message if available, else bottom.
        guard let targetID = streamingAssistantID ?? bottomItemID else { return }

        let isStreaming = streamingAssistantID != nil
        let delay: Duration
        if isHeavy {
            delay = isStreaming ? heavyStreamingDelay : nonStreamingDelay
        } else {
            delay = isStreaming ? streamingDelay : nonStreamingDelay
        }

        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            scrollTask = nil
            guard !Task.isCancelled else { return }
            guard anchor.isNearBottom else { return }
            guard !anchor.isUserInteracting else { return }
            guard !isKeyboardSettling else { return }

            performScrollToBottom(targetID)
            lastAutoScrollAt = ContinuousClock.now
        }
    }

    /// Called when `needsInitialScroll` becomes true. Scrolls to bottom
    /// after a short layout delay.
    func handleInitialScroll(bottomItemID: String?, performScrollToBottom: @escaping (String) -> Void) {
        guard needsInitialScroll else { return }
        needsInitialScroll = false

        guard let bottomItemID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            performScrollToBottom(bottomItemID)
        }
    }

    /// Called when `scrollTargetID` changes. Scrolls to the target item
    /// with animation after a layout delay.
    func handleScrollTarget(performScrollToTop: @escaping (String) -> Void) {
        guard let target = scrollTargetID else { return }
        scrollTargetID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            performScrollToTop(target)
        }
    }

    // MARK: - Imperative Scroll

    /// Request scroll to bottom (e.g. after sending a message).
    /// Re-attaches to bottom so auto-follow resumes for the response.
    func requestScrollToBottom() {
        anchor.isNearBottom = true
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
        isDetachedStreamingHintVisible = false
        isJumpToBottomHintVisible = false
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
    var topVisibleItemId: String?
}
