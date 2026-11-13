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

    /// The working row shares the 16 pt leading edge of every other row (the
    /// row column starts there) and its status text reads on the chat
    /// background, whatever the extension writes in it.
    @Test(arguments: [ThemeID.dark, .light])
    func workingRowStartsAtTheRowEdgeAndReadsOnTheBackground(themeID: ThemeID) throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        ThemeRuntimeState.setThemeID(themeID)
        // Alone, and carrying the turn's work at its trailing end: the spinner
        // and the text keep the leading edge either way.
        let work = WorkingRowWork(
            workLine: QuietTimelineWorkLine(
                id: "quiet-work-line:t", turnID: "t", sourceItemIDs: ["t"],
                buckets: [QuietWorkBucket(kind: .terminal, count: 1)], displayStyle: .icons,
                isExpanded: false, isLive: true, liveStartedAt: Date()
            ),
            chromeStyle: .conversation,
            onTap: {}
        )
        for work in [nil, work] {
            let view = makeView(
                workingState: ExtensionWorkingState(message: "Walking the maze · 4s", indicator: nil),
                work: work
            )
            let spinner = try #require(timelineFirstView(ofType: WorkingSpinnerUIView.self, in: view))
            let label = try #require(firstVisibleLabel(withText: "Walking the maze · 4s", in: view))
            #expect(spinner.convert(spinner.bounds, to: view).minX < 0.5)
            #expect(abs(label.convert(label.bounds, to: view).minX - 26) < 0.5)
            let color = try #require(label.textColor)
            #expect(wcagContrast(color, themeID.palette.bg) >= 4.5)
        }
    }

    /// With no folded work to carry, the row still shows the turn's time, counted from
    /// its prompt, after the extension's text.
    @Test func aloneTheRowShowsTheTurnsTime() throws {
        let surface = SessionExtensionSurface()
        surface.replace(with: ExtensionSurfaceState(working: ExtensionWorkingState(message: "Putting it in words", indicator: nil)))
        let configuration = WorkingIndicatorTimelineRowConfiguration(
            modelId: nil,
            surface: surface,
            turnStartedAt: Date().addingTimeInterval(-65)
        )
        let view = configuration.makeContentView() as UIView
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        view.layoutIfNeeded()

        let texts = visibleLabelTexts(in: view)
        #expect(texts.contains("Putting it in words"))
        #expect(texts.contains { $0.hasPrefix("1m ") }, "no turn time in \(texts)")
    }

    private func makeView(workingState: ExtensionWorkingState?, work: WorkingRowWork? = nil) -> UIView {
        let surface = SessionExtensionSurface()
        surface.replace(with: ExtensionSurfaceState(working: workingState))
        return makeView(surface: surface, work: work)
    }

    private func makeView(surface: SessionExtensionSurface, work: WorkingRowWork? = nil) -> UIView {
        let configuration = WorkingIndicatorTimelineRowConfiguration(modelId: nil, surface: surface, work: work)
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
