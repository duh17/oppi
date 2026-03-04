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

    /// Legacy convenience — returns an SF Symbol name only (for tests).
    static func languageBadgeSymbolName(for badge: String?) -> String? {
        guard let badge, !badge.isEmpty else {
            return nil
        }

        let normalized = badge.lowercased()
        if normalized.contains("⚠︎media") || normalized.contains("media") {
            return "exclamationmark.triangle"
        }

        if normalized.contains("swift"), UIImage(systemName: "swift") != nil {
            return "swift"
        }

        return genericLanguageBadgeSymbolName
    }
}
