import Foundation

struct TimelineExpandableTextInteractionSpec: Equatable {
    let supportsFullScreenPreview: Bool
    let inlineSelectionEnabled: Bool
    let enablesTapActivation: Bool
    let enablesPinchActivation: Bool

    static func build(
        hasSelectedTextContext: Bool,
        supportsFullScreenPreview: Bool
    ) -> Self {
        let inlineSelectionEnabled = hasSelectedTextContext && !supportsFullScreenPreview
        return Self(
            supportsFullScreenPreview: supportsFullScreenPreview,
            inlineSelectionEnabled: inlineSelectionEnabled,
            enablesTapActivation: supportsFullScreenPreview,
            enablesPinchActivation: supportsFullScreenPreview
        )
    }

}
