import Foundation

struct ToolTimelineRowInteractionPolicy: Equatable {
    enum ExpandedMode: Equatable {
        case bash(unwrapped: Bool)
        case diff
        case code
        case markdown
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
    ) -> Self {
        let mode = ExpandedMode(content)
        let supportsFullScreenPreview = supportsFullScreenPreview(mode: mode)

        switch mode {
        case .bash(let unwrapped):
            return Self(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: supportsFullScreenPreview,
                allowsHorizontalScroll: unwrapped
            )

        case .diff, .code:
            return Self(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: supportsFullScreenPreview,
                allowsHorizontalScroll: true
            )

        case .markdown:
            return Self(
                mode: mode,
                enablesTapCopyGesture: false,
                enablesPinchGesture: true,
                supportsFullScreenPreview: supportsFullScreenPreview,
                allowsHorizontalScroll: false
            )

        case .plot, .readMedia:
            return Self(
                mode: mode,
                enablesTapCopyGesture: false,
                enablesPinchGesture: false,
                supportsFullScreenPreview: false,
                allowsHorizontalScroll: false
            )

        case .text:
            return Self(
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
        case .plot, .readMedia:
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
        case .plot:
            self = .plot
        case .readMedia:
            self = .readMedia
        case .text:
            self = .text
        }
    }
}
