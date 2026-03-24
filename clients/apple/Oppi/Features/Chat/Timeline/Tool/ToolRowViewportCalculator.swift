import UIKit

/// Viewport height calculation subsystem extracted from ToolTimelineRowContentView.
///
/// Pure calculation — returns height values for the caller to apply to constraints.
/// Needs window/container geometry passed as parameters; never reads UI state directly.
@MainActor
enum ToolRowViewportCalculator {

    // MARK: - Public API

    /// Parameters describing the geometry available for viewport sizing.
    struct GeometryContext {
        let windowHeight: CGFloat
        let safeAreaInsets: UIEdgeInsets
        let cellWidth: CGFloat
    }

    /// Compute the fixed viewport height used during streaming, clamped to screen space.
    static func streamingConstrainedHeight(
        for mode: ViewportMode,
        geometry: GeometryContext
    ) -> CGFloat {
        let available = availableViewportHeight(for: mode, geometry: geometry)
        return max(mode.minHeight, min(ToolTimelineRowContentView.streamingViewportHeight, available))
    }

    /// Compute the preferred viewport height for completed (non-streaming) content.
    ///
    /// Measures the content view at the best available width, then clamps
    /// the result between the mode's min/max and the available screen space.
    static func preferredViewportHeight(
        for contentView: UIView,
        in container: UIView,
        mode: ViewportMode,
        expandedScrollView: UIScrollView?,
        expandedLabelWidthConstraint: NSLayoutConstraint?,
        outputScrollView: UIScrollView?,
        outputUsesUnwrappedLayout: Bool,
        outputLabelWidthConstraint: NSLayoutConstraint?,
        geometry: GeometryContext
    ) -> CGFloat {
        let fallbackContainerWidth = max(100, geometry.cellWidth - 16)
        let measuredContainerWidth = max(container.bounds.width, fallbackContainerWidth)

        // For diff/horizontal-scroll modes, measure at the label's actual
        // width (lines don't wrap). Using the container width would cause
        // text wrapping in the measurement, producing a height much taller
        // than the real rendered content.
        let width: CGFloat
        if mode == .expandedDiff || mode == .expandedCode,
           let widthConstraint = expandedLabelWidthConstraint,
           widthConstraint.constant > 1 {
            let scrollBounds = expandedScrollView?.bounds.width ?? 0
            let frameWidth = scrollBounds > 10 ? scrollBounds : measuredContainerWidth
            width = max(1, frameWidth + widthConstraint.constant)
        } else if mode == .output,
                  outputUsesUnwrappedLayout,
                  let widthConstraint = outputLabelWidthConstraint,
                  widthConstraint.constant > 1 {
            let scrollBounds = outputScrollView?.bounds.width ?? 0
            let frameWidth = scrollBounds > 10 ? scrollBounds : measuredContainerWidth
            width = max(1, frameWidth + widthConstraint.constant)
        } else {
            width = max(1, measuredContainerWidth - 12)
        }

        let contentHeight = measuredExpandedContentHeight(for: contentView, width: width)
        let availableHeight = availableViewportHeight(for: mode, geometry: geometry)
        let maxAllowed = min(mode.maxHeight, availableHeight)

        return min(maxAllowed, max(mode.minHeight, contentHeight))
    }

    /// Measure the natural content height of a view at a given width.
    static func measuredExpandedContentHeight(for contentView: UIView, width: CGFloat) -> CGFloat {
        if let label = contentView as? UILabel {
            let labelSize = label.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            )
            return ceil(max(1, labelSize.height) + 10)
        }

        let contentSize = contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingExpandedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(max(1, contentSize.height) + 10)
    }

    /// Available screen height for a viewport, accounting for safe area and mode-specific reserves.
    static func availableViewportHeight(
        for mode: ViewportMode,
        geometry: GeometryContext
    ) -> CGFloat {
        max(
            mode.minHeight,
            geometry.windowHeight - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom - mode.closeSafeAreaReserve
        )
    }
}

// MARK: - ViewportMode

extension ToolRowViewportCalculator {
    /// Discriminates between viewport sizing contexts.
    ///
    /// `cacheKey` and `perfName` are extended in `ToolTimelineRowLayoutPerformance`
    /// via the `ToolTimelineRowContentView.ViewportMode` typealias.
    enum ViewportMode: Equatable {
        case output
        case expandedDiff
        case expandedCode
        case expandedText

        var minHeight: CGFloat {
            switch self {
            case .output, .expandedText:
                return ToolTimelineRowContentView.minOutputViewportHeight
            case .expandedDiff, .expandedCode:
                return ToolTimelineRowContentView.minDiffViewportHeight
            }
        }

        var maxHeight: CGFloat {
            switch self {
            case .output, .expandedText:
                return ToolTimelineRowContentView.maxOutputViewportHeight
            case .expandedDiff, .expandedCode:
                return ToolTimelineRowContentView.maxDiffViewportHeight
            }
        }

        var closeSafeAreaReserve: CGFloat {
            switch self {
            case .output, .expandedText:
                return ToolTimelineRowContentView.outputViewportCloseSafeAreaReserve
            case .expandedDiff, .expandedCode:
                return ToolTimelineRowContentView.diffViewportCloseSafeAreaReserve
            }
        }
    }
}
