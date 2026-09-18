import UIKit

extension ToolTimelineRowContentView {
    @objc func handleOutputDoubleTap() {
        performOutputActivation()
    }

    @objc func handleExpandedDoubleTap() {
        performExpandedActivation()
    }

    func performOutputActivation() {
        performOutputFullScreenOrCopy(feedbackView: bashToolRowView.outputContainer)
    }

    func performExpandedActivation() {
        performOutputFullScreenOrCopy(feedbackView: expandedContainer)
    }

    private func performOutputFullScreenOrCopy(feedbackView: UIView) {
        if canActivateExpandedContent {
            AppHaptics.toolbarExpansion()
            activateExpandedContent()
            FeatureEducationTips.markToolOutputShortcutUsed()
            dismissFeatureEducationTipForAction()
            return
        }

        copyResolvedOutput(feedbackView: feedbackView)
    }
}
