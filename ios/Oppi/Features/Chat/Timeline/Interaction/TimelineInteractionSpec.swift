import Foundation

struct TimelineInteractionSpec: Equatable {
    let expandedSurfaceInteraction: TimelineExpandableTextInteractionSpec
    let enablesTapCopyGesture: Bool
    let enablesPinchGesture: Bool
    let allowsHorizontalScroll: Bool
    let supportsFullScreenPreview: Bool
    let commandSelectionEnabled: Bool
    let outputSelectionEnabled: Bool
    let expandedLabelSelectionEnabled: Bool
    let markdownSelectionEnabled: Bool

    static let collapsed = Self(
        expandedSurfaceInteraction: .collapsed,
        enablesTapCopyGesture: true,
        enablesPinchGesture: true,
        allowsHorizontalScroll: false,
        supportsFullScreenPreview: false,
        commandSelectionEnabled: false,
        outputSelectionEnabled: false,
        expandedLabelSelectionEnabled: false,
        markdownSelectionEnabled: false
    )
}
