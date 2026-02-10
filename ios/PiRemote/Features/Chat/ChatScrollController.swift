import SwiftUI
import UIKit

/// Manages scroll behavior for the chat timeline.
///
/// Extracted from ChatView to isolate scroll-related state and logic.
/// Uses a non-reactive `ScrollAnchorState` class to avoid SwiftUI
/// body re-evaluation feedback loops from sentinel visibility changes.
@MainActor @Observable
final class ChatScrollController {
    /// Non-reactive anchor — mutations are invisible to SwiftUI observation.
    /// A reactive `@State Bool` causes a feedback loop: sentinel flickers
    /// -> state change -> body re-eval -> layout -> sentinel flickers -> freeze.
    private let anchor = ScrollAnchorState()

    /// Throttle task for scroll-to-bottom during streaming.
    /// Uses "first-wins" throttle: if a scroll is scheduled, subsequent
    /// triggers are no-ops. This prevents cancel loops during 33ms streaming
    /// where a debounce pattern (cancel + reschedule) would never fire.
    private var scrollTask: Task<Void, Never>?

    /// Last completed auto-scroll timestamp.
    private var lastAutoScrollAt: ContinuousClock.Instant?

    /// Guardrail for very large timelines where repeated ScrollViewReader
    /// `scrollTo` can wedge SwiftUI's lazy layout pass.
    private let heavyTimelineThreshold = 120
    /// In heavy timelines, back off auto-scroll cadence to reduce layout churn.
    private let heavyTimelineAutoScrollMinInterval: Duration = .milliseconds(320)

    /// During keyboard show/hide/frame-change animations, suppress automatic
    /// timeline scrolling until layout settles.
    private let keyboardSettleDuration: Duration = .milliseconds(500)
    private var keyboardTransitionUntil: ContinuousClock.Instant?
    nonisolated(unsafe) private var keyboardObservers: [NSObjectProtocol] = []

    /// Set by outline view to scroll to a specific item.
    var scrollTargetID: String?

    /// Set after initial history load to trigger scroll-to-bottom.
    var needsInitialScroll = false

    // MARK: - Scroll Position Tracking (Non-Reactive)

    /// Binding for `ScrollView.scrollPosition(id:anchor:)`.
    ///
    /// Reads/writes through the non-reactive `ScrollAnchorState` so that
    /// scroll position changes do NOT trigger SwiftUI body re-evaluation.
    /// The ForEach item IDs are `String`, so this binding is `String?`.
    var scrollPositionBinding: Binding<String?> {
        Binding<String?>(
            get: { [anchor] in anchor.topVisibleItemId },
            set: { [anchor] in anchor.topVisibleItemId = $0 }
        )
    }

    /// Current topmost visible item ID. Read-only, for saving to restoration state.
    var currentTopVisibleItemId: String? {
        anchor.topVisibleItemId
    }

    /// Whether the user is currently scrolled to the bottom. Read-only, for restoration.
    var isCurrentlyNearBottom: Bool {
        anchor.isNearBottom
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
                    self?.markKeyboardTransition()
                }
            }
        }
    }

    private func markKeyboardTransition() {
        keyboardTransitionUntil = ContinuousClock.now.advanced(by: keyboardSettleDuration)
    }

    private var isKeyboardTransitionActive: Bool {
        guard let keyboardTransitionUntil else { return false }
        if ContinuousClock.now < keyboardTransitionUntil {
            return true
        }
        self.keyboardTransitionUntil = nil
        return false
    }

    // MARK: - Sentinel Callbacks

    func onSentinelAppear() {
        anchor.isNearBottom = true
    }

    func onSentinelDisappear() {
        anchor.isNearBottom = false
    }

    // MARK: - Auto-Scroll on Content Change

    /// Called when `renderVersion` changes. Schedules a throttled scroll
    /// if the user is near the bottom.
    ///
    /// When `streamingID` is provided, scrolls to the streaming assistant
    /// message instead of the bottom sentinel. This prevents the cursor
    /// from bouncing as the sentinel position shifts with content growth.
    func handleRenderVersionChange(proxy: ScrollViewProxy, streamingID: String? = nil) {
        guard anchor.isNearBottom else { return }
        guard !isKeyboardTransitionActive else { return }

        let isHeavyTimeline = _diagnosticItemCount >= heavyTimelineThreshold

        // Guardrail: in very large timelines, non-streaming auto-scrolls are
        // usually redundant (the user is already at the tail) and can trigger
        // expensive LazyVStack placement cascades.
        if isHeavyTimeline, streamingID == nil {
            return
        }

        guard scrollTask == nil else { return }

        if isHeavyTimeline,
           let lastAutoScrollAt,
           ContinuousClock.now - lastAutoScrollAt < heavyTimelineAutoScrollMinInterval {
            return
        }

        // During active streaming, scroll to the message itself so the
        // cursor stays pinned in the viewport. Fall back to the sentinel
        // for non-streaming updates (tool rows, working indicator, etc.).
        let targetID = streamingID ?? "bottom-sentinel"
        let throttleDelay: Duration = isHeavyTimeline ? .milliseconds(180) : .milliseconds(60)

        scrollTask = Task { @MainActor in
            try? await Task.sleep(for: throttleDelay)
            scrollTask = nil
            guard !Task.isCancelled else { return }
            guard anchor.isNearBottom else { return }

            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
            lastAutoScrollAt = ContinuousClock.now
        }
    }

    /// Set by ChatTimelineView for diagnostic gating of scrollTo.
    var _diagnosticItemCount: Int = 0

    /// Called when `needsInitialScroll` becomes true. Scrolls to bottom
    /// after a short layout delay.
    func handleInitialScroll(proxy: ScrollViewProxy) {
        guard needsInitialScroll else { return }
        needsInitialScroll = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo("bottom-sentinel", anchor: .bottom)
            }
        }
    }

    /// Called when `scrollTargetID` changes. Scrolls to the target item
    /// with animation after a layout delay.
    func handleScrollTarget(proxy: ScrollViewProxy) {
        guard let target = scrollTargetID else { return }
        scrollTargetID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    // MARK: - Cleanup

    func cancel() {
        scrollTask?.cancel()
        scrollTask = nil
        lastAutoScrollAt = nil
        keyboardTransitionUntil = nil
    }
}

// MARK: - Scroll Anchor (non-reactive)

/// Tracks whether the user is near the bottom of the scroll view.
///
/// Deliberately NOT `@Observable` — mutations must NOT trigger SwiftUI
/// body re-evaluations. A reactive version (`@State Bool`) creates a
/// feedback loop: sentinel onAppear/onDisappear toggles state -> body
/// re-evaluates -> layout pass -> sentinel visibility changes -> loop.
///
/// This class is stored inside `@Observable` `ChatScrollController`
/// but property changes are invisible to SwiftUI's observation system.
private final class ScrollAnchorState {
    var isNearBottom = true
    /// ID of the topmost visible item, updated via `scrollPosition(id:)`.
    /// Non-reactive: mutations do NOT trigger SwiftUI body re-evaluation.
    var topVisibleItemId: String?
}
