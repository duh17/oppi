import Testing
import UIKit
@testable import Oppi

@Suite("WorkingIndicatorTimelineRowContentView")
@MainActor
struct WorkingIndicatorTimelineRowContentTests {
    @Test func rendersExtensionMessageAndStaticIndicator() {
        let view = makeView(
            workingState: ExtensionWorkingState(
                message: "Running checks",
                indicator: ExtensionUIWorkingIndicator(frames: ["●"], intervalMs: nil)
            )
        )

        let texts = visibleLabelTexts(in: view)
        #expect(texts.contains("Running checks"))
        #expect(texts.contains("●"))
        #expect(view.accessibilityLabel == "Running checks")
    }

    @Test func hiddenIndicatorFramesKeepMessageWithoutVisibleIndicatorText() {
        let view = makeView(
            workingState: ExtensionWorkingState(
                message: "Waiting for tools",
                indicator: ExtensionUIWorkingIndicator(frames: [], intervalMs: nil)
            )
        )

        let texts = visibleLabelTexts(in: view)
        #expect(texts.contains("Waiting for tools"))
        #expect(!texts.contains("●"))
        #expect(!texts.contains("⠋"))
    }

    @Test func defaultStateUsesNativeWorkingMessage() {
        let view = makeView(workingState: nil)

        let texts = visibleLabelTexts(in: view)
        #expect(texts.contains("Working..."))
    }

    @Test func reduceMotionChangeReappliesCustomIndicatorState() {
        let view = makeView(
            workingState: ExtensionWorkingState(
                message: "Running checks",
                indicator: ExtensionUIWorkingIndicator(frames: ["A", "B"], intervalMs: 120)
            )
        )
        guard let indicatorLabel = firstVisibleLabel(withText: "A", in: view) else {
            Issue.record("expected custom indicator label")
            return
        }

        indicatorLabel.text = "B"
        NotificationCenter.default.post(
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )

        #expect(indicatorLabel.text == "A")
    }

    private func makeView(workingState: ExtensionWorkingState?) -> UIView {
        let configuration = WorkingIndicatorTimelineRowConfiguration(
            modelId: nil,
            workingState: workingState
        )
        let contentView = configuration.makeContentView()
        let view = contentView as UIView
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    private func visibleLabelTexts(in view: UIView) -> [String] {
        timelineAllLabels(in: view)
            .filter(timelineViewIsVisible)
            .map(timelineRenderedText)
            .filter { !$0.isEmpty }
    }

    private func firstVisibleLabel(withText text: String, in view: UIView) -> UILabel? {
        timelineAllLabels(in: view)
            .filter(timelineViewIsVisible)
            .first { $0.text == text }
    }
}
