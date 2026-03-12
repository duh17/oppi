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
        if canShowFullScreenContent {
            showFullScreenContent()
            return
        }

        guard let text = outputCopyText else { return }
        copy(text: text, feedbackView: feedbackView)
    }
}
