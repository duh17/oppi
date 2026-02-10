import SwiftUI

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

    /// Set by outline view to scroll to a specific item.
    var scrollTargetID: String?

    /// Set after initial history load to trigger scroll-to-bottom.
    var needsInitialScroll = false

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
        guard scrollTask == nil else { return }

        // During active streaming, scroll to the message itself so the
        // cursor stays pinned in the viewport. Fall back to the sentinel
        // for non-streaming updates (tool rows, working indicator, etc.).
        let targetID = streamingID ?? "bottom-sentinel"

        scrollTask = Task { @MainActor in
            // 50ms throttle (was 100ms) — tighter tracking reduces the
            // visible bounce between content growth and scroll catch-up.
            try? await Task.sleep(for: .milliseconds(50))
            scrollTask = nil
            guard !Task.isCancelled else { return }
            guard anchor.isNearBottom else { return }

            MainThreadBreadcrumb.set("scrollTo-bottom")
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
            MainThreadBreadcrumb.set("idle")
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
            MainThreadBreadcrumb.set("scrollTo-initial")
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo("bottom-sentinel", anchor: .bottom)
            }
            MainThreadBreadcrumb.set("idle")
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
}
