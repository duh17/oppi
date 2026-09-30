import Foundation

struct ToolTimelineRowInteractionPolicy: Equatable {
    enum ExpandedMode: Equatable {
        case bash(unwrapped: Bool)
        case diff
        case code
        case markdown
        case readMedia
        case audioMessage
        case status
        case text
        case document
    }

    let mode: ExpandedMode
    let enablesTapCopyGesture: Bool
    let enablesPinchGesture: Bool
    let supportsFullScreenPreview: Bool
    let allowsHorizontalScroll: Bool

    static func forExpandedContent(
        _ content: ToolPresentationBuilder.ToolExpandedContent,
        isDone: Bool
    ) -> Self {
        let mode = ExpandedMode(content)

        switch mode {
        case .bash(let unwrapped):
            return Self(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: true,
                allowsHorizontalScroll: unwrapped && isDone
            )

        case .diff, .code:
            return Self(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: true,
                allowsHorizontalScroll: isDone
            )

        case .readMedia, .audioMessage, .status:
            return Self(
                mode: mode,
                enablesTapCopyGesture: false,
                enablesPinchGesture: false,
                supportsFullScreenPreview: false,
                allowsHorizontalScroll: false
            )

        case .markdown, .document, .text:
            return Self(
                mode: mode,
                enablesTapCopyGesture: true,
                enablesPinchGesture: true,
                supportsFullScreenPreview: true,
                allowsHorizontalScroll: false
            )
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
        case .readMedia:
            self = .readMedia
        case .audioMessage:
            self = .audioMessage
        case .status:
            self = .status
        case .text:
            self = .text
        case .document:
            self = .document
        }
    }
}
