import UIKit

@MainActor
enum ToolTimelineRowUIHelpers {
    private static let autoFollowBottomThreshold: CGFloat = 18
    private static let genericLanguageBadgeSymbolName = "chevron.left.forwardslash.chevron.right"

    static func clampScrollOffsetIfNeeded(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        let viewportWidth = max(0, scrollView.bounds.width - inset.left - inset.right)
        let viewportHeight = max(0, scrollView.bounds.height - inset.top - inset.bottom)

        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width - viewportWidth + inset.right)
        let maxY = max(minY, scrollView.contentSize.height - viewportHeight + inset.bottom)

        var clamped = scrollView.contentOffset
        clamped.x = min(max(clamped.x, minX), maxX)
        clamped.y = min(max(clamped.y, minY), maxY)

        guard abs(clamped.x - scrollView.contentOffset.x) > 0.5
                || abs(clamped.y - scrollView.contentOffset.y) > 0.5 else {
            return
        }

        scrollView.setContentOffset(clamped, animated: false)
    }

    static func resetScrollPosition(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        scrollView.setContentOffset(
            CGPoint(x: -inset.left, y: -inset.top),
            animated: false
        )
    }

    static func scrollToBottom(_ scrollView: UIScrollView, animated: Bool) {
        let inset = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard viewportHeight > 0 else { return }

        let bottomY = max(
            -inset.top,
            scrollView.contentSize.height - viewportHeight + inset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: -inset.left, y: bottomY),
            animated: animated
        )
    }

    /// Settle content size and scroll to bottom in one synchronous step.
    ///
    /// Call from `apply()` after setting text — never from `layoutSubviews()`.
    /// UITextView doesn't always propagate intrinsic-size invalidation through
    /// the content layout guide on the same run-loop pass as `.text=`, so we
    /// explicitly invalidate, force layout, then scroll.
    static func followTail(
        in scrollView: UIScrollView,
        contentLabel: UIView
    ) {
        contentLabel.invalidateIntrinsicContentSize()
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        scrollToBottom(scrollView, animated: false)
    }

    /// Pure computation of auto-follow state after a render pass.
    ///
    /// Used by strategies that return `ExpandedRenderOutput` — they call this
    /// to determine the new auto-follow flag without side effects.
    ///
    /// Rules:
    /// - First render while streaming: enable
    /// - Streaming continuation: preserve current state (user scroll respected)
    /// - Cell reuse during streaming (non-continuation rerender): re-enable
    /// - Done: disable
    static func computeAutoFollow(
        isStreaming: Bool,
        shouldRerender: Bool,
        wasExpandedVisible: Bool,
        previousRenderedText: String?,
        currentDisplayText: String,
        currentAutoFollow: Bool
    ) -> Bool {
        let isStreamingContinuation = previousRenderedText.map {
            !$0.isEmpty && currentDisplayText.hasPrefix($0)
        } ?? false

        if isStreaming {
            if !wasExpandedVisible || previousRenderedText == nil {
                return true
            } else if !isStreamingContinuation, shouldRerender {
                return true
            }
            return currentAutoFollow
        } else {
            return false
        }
    }

    /// Unified auto-follow logic for expanded tool content (code, diff, text).
    ///
    /// Determines whether to enable/disable auto-follow and whether to scroll
    /// after a render pass. Delegates to `computeAutoFollow` for the pure
    /// state computation, then applies the scroll side effects.
    static func applyExpandedAutoFollow(
        isStreaming: Bool,
        shouldRerender: Bool,
        wasExpandedVisible: Bool,
        previousRenderedText: String?,
        currentDisplayText: String,
        expandedShouldAutoFollow: inout Bool,
        expandedScrollView: UIScrollView,
        scheduleFollowTail: () -> Void
    ) {
        expandedShouldAutoFollow = computeAutoFollow(
            isStreaming: isStreaming,
            shouldRerender: shouldRerender,
            wasExpandedVisible: wasExpandedVisible,
            previousRenderedText: previousRenderedText,
            currentDisplayText: currentDisplayText,
            currentAutoFollow: expandedShouldAutoFollow
        )

        if shouldRerender {
            if expandedShouldAutoFollow {
                scheduleFollowTail()
            } else if !isStreaming {
                resetScrollPosition(expandedScrollView)
            }
        }
    }

    static func isNearBottom(_ scrollView: UIScrollView) -> Bool {
        let inset = scrollView.adjustedContentInset
        let viewportHeight = scrollView.bounds.height - inset.top - inset.bottom
        guard viewportHeight > 0 else { return true }

        let bottomY = scrollView.contentOffset.y + inset.top + viewportHeight
        let distance = max(0, scrollView.contentSize.height - bottomY)
        return distance <= autoFollowBottomThreshold
    }

    static func toolSymbolName(for toolNamePrefix: String?) -> String? {
        switch toolNamePrefix {
        case "$":
            return "dollarsign"
        case "read":
            return "magnifyingglass"
        case "write":
            return "pencil"
        case "edit":
            return "arrow.left.arrow.right"
        default:
            return nil
        }
    }

    /// Resolve a language badge string to either an asset catalog image or an SF Symbol.
    ///
    /// Prefers custom language icons from the asset catalog (`lang-*`),
    /// falls back to SF Symbols for languages without a custom icon.
    static func languageBadgeImage(for badge: String?) -> UIImage? {
        guard let badge, !badge.isEmpty else {
            return nil
        }

        let normalized = badge.lowercased()
        if normalized.contains("⚠︎media") || normalized.contains("media") {
            return UIImage(systemName: "exclamationmark.triangle")
        }

        // Check for a custom asset catalog icon first (lang-javascript, lang-python, etc.)
        let assetMap: [String: String] = [
            "javascript": "lang-nodejs",
            "typescript": "lang-typescript",
            "python": "lang-python",
            "ruby": "lang-ruby",
            "go": "lang-go",
            "rust": "lang-rust",
            "swift": "lang-swift",
            "zig": "lang-zig",
            "markdown": "lang-markdown",
        ]
        if let assetName = assetMap[normalized],
           let image = UIImage(named: assetName) {
            return image
        }

        // SF Symbol fallbacks
        if normalized == "swift", let img = UIImage(systemName: "swift") {
            return img
        }
        if normalized == "sql" {
            return UIImage(systemName: "cylinder")
        }

        return UIImage(systemName: genericLanguageBadgeSymbolName)
    }
}
