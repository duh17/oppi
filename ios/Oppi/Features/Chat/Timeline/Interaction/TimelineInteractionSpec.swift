import Foundation

struct TimelineInteractionSpec: Equatable {
    let enablesTapCopyGesture: Bool
    let enablesPinchGesture: Bool
    let allowsHorizontalScroll: Bool
    let commandSelectionEnabled: Bool
    let outputSelectionEnabled: Bool
    let expandedLabelSelectionEnabled: Bool
    let markdownSelectionEnabled: Bool

    static let collapsed = Self(
        enablesTapCopyGesture: true,
        enablesPinchGesture: true,
        allowsHorizontalScroll: false,
        commandSelectionEnabled: false,
        outputSelectionEnabled: false,
        expandedLabelSelectionEnabled: false,
        markdownSelectionEnabled: false
    )
}
