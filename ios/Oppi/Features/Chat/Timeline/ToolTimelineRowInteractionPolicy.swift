import Foundation

struct ToolTimelineRowInteractionPolicy: Equatable {
    enum ExpandedMode: Equatable {
        case bash(unwrapped: Bool)
        case diff
        case code
        case markdown
        case todo
        case plot
        case readMedia
        case text
    }

    let mode: ExpandedMode
    let enablesTapCopyGesture: Bool
    let enablesPinchGesture: Bool
    let supportsFullScreenPreview: Bool
    let allowsHorizontalScroll: Bool

    static func forExpandedContent(
        _ content: ToolPresentationBuilder.ToolExpandedContent
    ) -> ToolTimelineRowInteractionPolicy {
        let mode = ExpandedMode(content)
        let supportsFullScreenPreview = supportsFullScreenPreview(mode: mode)

        switch mode {
        case .bash(let unwrapped):
            return ToolTimelineRowInteractionPolicy(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: supportsFullScreenPreview,
                allowsHorizontalScroll: unwrapped
            )

        case .diff, .code:
            return ToolTimelineRowInteractionPolicy(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: supportsFullScreenPreview,
                allowsHorizontalScroll: true
            )

        case .markdown:
            return ToolTimelineRowInteractionPolicy(
                mode: mode,
                enablesTapCopyGesture: false,
                enablesPinchGesture: true,
                supportsFullScreenPreview: supportsFullScreenPreview,
                allowsHorizontalScroll: false
            )

        case .todo, .plot, .readMedia:
            return ToolTimelineRowInteractionPolicy(
                mode: mode,
                enablesTapCopyGesture: false,
                enablesPinchGesture: false,
                supportsFullScreenPreview: false,
                allowsHorizontalScroll: false
            )

        case .text:
            return ToolTimelineRowInteractionPolicy(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: supportsFullScreenPreview,
                allowsHorizontalScroll: false
            )
        }
    }

    private static func supportsFullScreenPreview(mode: ExpandedMode) -> Bool {
        switch mode {
        case .diff, .code, .markdown, .bash, .text:
            return true
        case .todo, .plot, .readMedia:
            return false
        }
    }
}

private extension ToolTimelineRowInteractionPolicy.ExpandedMode {
    init(_ content: ToolPresentationBuilder.ToolExpandedContent) {
        switch content {
        case .bash(_, _, let unwrapped):
            self = .bash(unwrapped: unwrapped)
        case .diff:
            self = .diff
        case .code:
            self = .code
        case .markdown:
            self = .markdown
        case .todoCard:
            self = .todo
        case .plot:
            self = .plot
        case .readMedia:
            self = .readMedia
        case .text:
            self = .text
        }
    }
}
