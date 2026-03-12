import UIKit

/// Declarative output from an expanded render strategy.
///
/// Each strategy returns this struct with every behavioral dimension
/// explicitly declared. The parent applies it via a single shared
/// `applyExpandedRenderOutput()` method — no closures, no inout params.
@MainActor
struct ExpandedRenderOutput {
    let renderSignature: Int?
    let renderedText: String?
    let shouldAutoFollow: Bool
    let surface: ExpandedSurface
    let viewportMode: ToolTimelineRowContentView.ExpandedViewportMode
    let verticalLock: Bool
    let scrollBehavior: ScrollBehavior
    let lineBreakMode: NSLineBreakMode
    let horizontalScroll: Bool
    let deferredHighlight: ToolRowCodeRenderStrategy.DeferredHighlight?
    let invalidateLayout: Bool

    enum ExpandedSurface {
        case label
        case markdown
        case hostedView
    }

    enum ScrollBehavior {
        case followTail
        case resetToTop
        case preserve
    }
}
