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

    /// The row follows its session's working text without a reconfigure, and
    /// a text tick leaves the running custom indicator where it is.
    @Test func workingTextTickUpdatesInPlaceWithoutRestartingTheIndicator() {
        let surface = SessionExtensionSurface()
        surface.replace(with: ExtensionSurfaceState(working: ExtensionWorkingState(
            message: "Busy · 1s",
            indicator: ExtensionUIWorkingIndicator(frames: ["A", "B"], intervalMs: 120)
        )))
        let view = makeView(surface: surface)
        guard let indicatorLabel = firstVisibleLabel(withText: "A", in: view) else {
            Issue.record("expected custom indicator label")
            return
        }
        indicatorLabel.text = "B"

        var next = surface.state
        next.working?.message = "Busy · 2s"
        surface.replace(with: next)
        view.updatePropertiesIfNeeded()

        #expect(visibleLabelTexts(in: view).contains("Busy · 2s"))
        #expect(view.accessibilityLabel == "Busy · 2s")
        #expect(indicatorLabel.text == "B")
    }

    private func makeView(workingState: ExtensionWorkingState?) -> UIView {
        let surface = SessionExtensionSurface()
        surface.replace(with: ExtensionSurfaceState(working: workingState))
        return makeView(surface: surface)
    }

    private func makeView(surface: SessionExtensionSurface) -> UIView {
        let configuration = WorkingIndicatorTimelineRowConfiguration(modelId: nil, surface: surface)
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
            .first { timelineViewIsVisible($0) && $0.text == text }
    }
}
