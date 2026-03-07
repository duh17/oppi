import UIKit

@MainActor
enum ToolTimelineRowContextMenuTargeting {
    typealias ContextMenuTarget = ToolTimelineRowContentView.ContextMenuTarget

    static func target(
        for interactionView: UIView?,
        commandContainer: UIView,
        outputContainer: UIView,
        expandedContainer: UIView,
        imagePreviewContainer: UIView
    ) -> ContextMenuTarget? {
        guard let interactionView else {
            return nil
        }

        if interactionView === commandContainer {
            return .command
        }

        if interactionView === outputContainer {
            return .output
        }

        if interactionView === expandedContainer {
            return .expanded
        }

        if interactionView === imagePreviewContainer {
            return .imagePreview
        }

        return nil
    }

    static func feedbackView(
        for target: ContextMenuTarget,
        commandContainer: UIView,
        outputContainer: UIView,
        expandedContainer: UIView,
        imagePreviewContainer: UIView
    ) -> UIView {
        switch target {
        case .command:
            commandContainer
        case .output:
            outputContainer
        case .expanded:
            expandedContainer
        case .imagePreview:
            imagePreviewContainer
        }
    }
}
