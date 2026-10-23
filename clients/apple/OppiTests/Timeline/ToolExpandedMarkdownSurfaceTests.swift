import Testing
import UIKit
@testable import Oppi

/// Transitions of the expanded Markdown viewport that the mode-dispatch and
/// surface-host suites do not exercise: reuse across content kinds, collapse
/// and reuse while a reader is still preparing, tail-follow after a drag, and
/// the surface's own identity and geometry signatures.
@Suite("Tool expanded Markdown surface")
@MainActor
struct ToolExpandedMarkdownSurfaceTests {
    // MARK: - Reuse and teardown through the row

    @Test func reuseAcrossContentKindsBuildsAFreshCompletedReader() throws {
        let text = "# One\n\nBody with **bold** text."
        let view = ToolTimelineRowContentView(configuration: markdownConfiguration(text))
        _ = fittedTimelineSize(for: view, width: 360)
        let first = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view))

        view.configuration = codeConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(
            timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view) == nil,
            "The completed reader must not outlive the switch to a label surface"
        )
        #expect(first.superview == nil)
        #expect(!view.expandedLabel.isHidden)

        view.configuration = markdownConfiguration(text)
        _ = fittedTimelineSize(for: view, width: 360)
        let second = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view))
        #expect(second !== first, "Returning to Markdown must not resurrect the earlier reader")
        #expect(second.debugSourceTextForTesting == text)
        #expect(view.expandedLabel.isHidden)
        let labelText = view.expandedLabel.attributedText?.string ?? view.expandedLabel.text ?? ""
        #expect(labelText.isEmpty)
    }

    /// Collapsing only hides the viewport: coming back to the same streaming call
    /// must not convert or lay out the document again. Another surface taking the
    /// viewport drops the parse, so coming back from it does.
    @Test func liveViewportKeepsParsedContentThroughCollapseButNotASurfaceSwitch() throws {
        let text = (0..<40).map { "Paragraph \($0) of the streaming document." }.joined(separator: "\n\n")
        let view = ToolTimelineRowContentView(configuration: markdownConfiguration(text, isDone: false))
        _ = fittedTimelineSize(for: view, width: 360)
        let live = try #require(timelineFirstView(ofType: AssistantMarkdownContentView.self, in: view))
        let rendered = timelineAllTextViews(in: live)
        #expect(!rendered.isEmpty, "The streaming viewport should hold parsed segments")

        view.configuration = collapsedConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        view.configuration = markdownConfiguration(text, isDone: false)
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(
            timelineAllTextViews(in: live).first === rendered.first,
            "Collapsing keeps the parsed document, so expanding again must not render it from scratch"
        )

        view.configuration = codeConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        view.configuration = markdownConfiguration(text, isDone: false)
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(
            timelineAllTextViews(in: live).first !== rendered.first,
            "Another surface taking the viewport drops the parse, so coming back renders it again"
        )
    }

    /// A reused tool cell can move to another item without a retirement. The
    /// second call is longer than the first and repeats the first call's last 64
    /// bytes at the same byte offset, which is exactly the parser's append
    /// proof: with the item-id reset removed the first call's frozen prefix
    /// survives and the second call's own opening text never renders.
    @Test func reusedCellDoesNotKeepAnotherItemsParsedContent() throws {
        // The closing line is what a longer second call repeats. It carries none
        // of the first call's paragraph text, so a leaked prefix is unambiguous.
        let firstText = (0..<20)
            .map { "First tool call paragraph \($0) with prose." }
            .joined(separator: "\n\n")
            + "\n\nclosing line of the first call alpha bravo charlie delta echo foxtrot golf hotel"
        let sharedTail = String(decoding: firstText.utf8.suffix(64), as: UTF8.self)
        #expect(!sharedTail.contains("First tool call paragraph"))
        let secondText = Self.padded(
            "Second tool call opens with different text.",
            toUTF8Count: firstText.utf8.count - sharedTail.utf8.count
        ) + sharedTail + "\n\nSecond tool call closing paragraph."
        #expect(secondText.utf8.count > firstText.utf8.count)

        let harness = SurfaceHarness()
        harness.apply(firstText, isStreaming: true)
        #expect(!timelineAllTextViews(in: harness.surface.liveView).isEmpty)

        harness.apply(secondText, itemID: "second-call", isStreaming: true)
        let text = timelineAllTextViews(in: harness.surface.liveView)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(text.contains("Second tool call opens"))
        #expect(!text.contains("First tool call paragraph"))
    }

    @Test func collapsingWhileTheReaderPreparesReleasesIt() async throws {
        let view = ToolTimelineRowContentView(configuration: markdownConfiguration(Self.deferredDocument))
        _ = fittedTimelineSize(for: view, width: 360)

        weak var weakReader: NativeFullScreenMarkdownBody?
        do {
            let reader = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view))
            weakReader = reader
            #expect(
                reader.debugRenderedSegmentCountForTesting == 0,
                "A document this large should still be waiting for its deferred first render"
            )
        }

        view.configuration = collapsedConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        // Suspend between checks so UIKit's autorelease pool for this job drains.
        // The release must not wait for the 750 ms deferred render to fire or finish.
        var released = false
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(25))
            if weakReader == nil {
                released = true
                break
            }
        }
        #expect(released, "Collapse must release the reader that was still preparing")

        try await Task.sleep(for: Self.pastDeferredRenderDelay)
        #expect(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view) == nil)
    }

    @Test func reuseBeforeTheDeferredRenderFiresIgnoresItsLateCompletion() async throws {
        let view = ToolTimelineRowContentView(configuration: markdownConfiguration(Self.deferredDocument))
        _ = fittedTimelineSize(for: view, width: 360)
        weak let weakReader = timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view)
        #expect(weakReader != nil)

        view.configuration = codeConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        try await Task.sleep(for: Self.pastDeferredRenderDelay)

        #expect(weakReader == nil)
        #expect(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view) == nil)
        #expect(!view.expandedLabel.isHidden)
        let labelText = view.expandedLabel.attributedText?.string ?? ""
        #expect(labelText.contains("struct App"))

        // A small document mounted afterwards renders its own text, untouched
        // by the abandoned large render.
        let small = "# Small\n\nJust this."
        view.configuration = markdownConfiguration(small)
        _ = fittedTimelineSize(for: view, width: 360)
        let reader = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view))
        try await Task.sleep(for: Self.pastDeferredRenderDelay)
        #expect(reader.debugSourceTextForTesting == small)
    }

    @Test func completedViewportStaysPinnedHorizontallyAfterAStrayOffset() throws {
        let view = ToolTimelineRowContentView(configuration: markdownConfiguration("# Done\n\nBody text."))
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 2_000))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutIfNeeded()

        let scrollView = view.expandedScrollView
        scrollView.setContentOffset(CGPoint(x: 24, y: 0), animated: false)
        #expect(scrollView.contentOffset.x == 24)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(abs(scrollView.contentOffset.x) < 0.5, "The completed reader fills the frame width; the row must not drift sideways")
        withExtendedLifetime(container) {}
    }

    // MARK: - Tail follow through the row's scroll delegate

    @Test func draggingDetachesLiveFollowAndReleasingNearTheTailReattaches() throws {
        let text = (0..<80).map {
            "Paragraph \($0) with enough markdown text to overflow the streaming viewport."
        }.joined(separator: "\n\n")
        let view = ToolTimelineRowContentView(configuration: markdownConfiguration(text, isDone: false))
        _ = fittedTimelineSize(for: view, width: 360)
        let scrollView = view.expandedScrollView
        #expect(scrollView.contentSize.height > scrollView.bounds.height + 100)
        #expect(view.expandedShouldAutoFollow)

        view.scrollViewWillBeginDragging(scrollView)
        #expect(!view.expandedShouldAutoFollow, "Touching the viewport detaches the tail follow")

        ToolTimelineRowUIHelpers.resetScrollPosition(scrollView)
        view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        #expect(!view.expandedShouldAutoFollow, "Releasing away from the tail stays detached")

        view.scrollViewWillBeginDragging(scrollView)
        ToolTimelineRowUIHelpers.scrollToBottom(scrollView, animated: false)
        view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        #expect(view.expandedShouldAutoFollow, "Releasing at the tail of a live stream follows it again")
    }

    @Test func releasingNearTheTailAfterTheStreamCompletedDoesNotFollow() throws {
        let text = (0..<80).map {
            "Paragraph \($0) with enough markdown text to overflow the streaming viewport."
        }.joined(separator: "\n\n")
        let view = ToolTimelineRowContentView(configuration: markdownConfiguration(text, isDone: false))
        _ = fittedTimelineSize(for: view, width: 360)
        let scrollView = view.expandedScrollView

        view.scrollViewWillBeginDragging(scrollView)
        // The stream finishes while the finger is still down. The reader takes
        // over, so the row's drag callbacks no longer belong to the viewport.
        view.configuration = markdownConfiguration(text + "\n\nDone.", isDone: true)
        _ = fittedTimelineSize(for: view, width: 360)
        ToolTimelineRowUIHelpers.scrollToBottom(scrollView, animated: false)
        view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        #expect(!view.expandedShouldAutoFollow)
    }

    // MARK: - Surface identity and geometry signatures

    /// A theme change rebuilds the reader too; `expandedMarkdownViewportRebuildsForThemeChange`
    /// covers that, so this suite does not flip the process-wide theme again.
    @Test func completedReaderIsRebuiltOnlyWhenItsTextChanges() {
        let harness = SurfaceHarness()
        #expect(harness.apply("# Same", isStreaming: false) == .completedInstalled)
        let reader = harness.surface.completedBody
        #expect(reader != nil)

        #expect(harness.apply("# Same", isStreaming: false) == .completedUnchanged)
        #expect(harness.surface.completedBody === reader)

        #expect(harness.apply("# Changed", isStreaming: false) == .completedInstalled)
        #expect(harness.surface.completedBody !== reader)
        #expect(reader?.superview == nil)
        #expect(harness.surface.themeID == ThemeRuntimeState.currentThemeID())
        #expect(!harness.surface.isThemeStale)
    }

    @Test func retiringClearsTheViewportIdentity() {
        let harness = SurfaceHarness()
        harness.apply("# Live", isStreaming: true)
        harness.activate()
        #expect(harness.surface.isLiveLayoutActive)
        #expect(harness.surface.themeID == ThemeRuntimeState.currentThemeID())

        harness.surface.retire(.collapsed)
        #expect(!harness.surface.isViewportActive)
        #expect(harness.surface.themeID == nil)
        #expect(harness.surface.isThemeStale)

        harness.apply("# Done", isStreaming: false)
        harness.activate()
        let reader = harness.surface.completedBody
        #expect(reader != nil)
        #expect(harness.surface.isViewportActive)

        harness.surface.retire(.replaced)
        #expect(harness.surface.completedBody == nil)
        #expect(reader?.superview == nil)
        #expect(!harness.surface.isViewportActive)
        #expect(harness.surface.themeID == nil)
    }

    @Test func geometrySignaturesAskForOneOuterMeasureOnlyOnRealChange() {
        let harness = SurfaceHarness()
        harness.apply("# Done", isStreaming: false)
        harness.activate()
        let container = harness.surface.completedContainer

        container.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        #expect(!harness.surface.refreshWidthSignature(policyOwnsViewport: true), "First sight seeds the signature")
        container.frame.size.width = 360.3
        #expect(!harness.surface.refreshWidthSignature(policyOwnsViewport: true), "Sub-half-point drift is not a change")
        container.frame.size.width = 420
        #expect(harness.surface.refreshWidthSignature(policyOwnsViewport: true))
        #expect(!harness.surface.refreshWidthSignature(policyOwnsViewport: true))

        // Losing the policy forgets the signature, so the next sighting only reseeds it.
        #expect(!harness.surface.refreshWidthSignature(policyOwnsViewport: false))
        container.frame.size.width = 300
        #expect(!harness.surface.refreshWidthSignature(policyOwnsViewport: true))

        #expect(!harness.surface.recordViewportHeight(200, policyOwnsViewport: true))
        #expect(!harness.surface.recordViewportHeight(200.4, policyOwnsViewport: true))
        #expect(harness.surface.recordViewportHeight(480, policyOwnsViewport: true))
        #expect(!harness.surface.recordViewportHeight(480, policyOwnsViewport: false))
        #expect(!harness.surface.recordViewportHeight(200, policyOwnsViewport: true))
    }

    @Test func liveViewportFollowsTheTailUntilTouchedAndOnlyWhileStreaming() {
        let harness = SurfaceHarness()
        harness.apply("# Live", isStreaming: true)
        #expect(harness.surface.followsTail)

        harness.surface.viewportInteractionBegan()
        #expect(!harness.surface.followsTail)

        harness.scrollView.contentSize = CGSize(width: 360, height: 1_000)
        harness.scrollView.contentOffset = .zero
        #expect(!harness.surface.viewportInteractionEnded(isStreaming: true))
        #expect(!harness.surface.followsTail)

        harness.surface.viewportInteractionBegan()
        ToolTimelineRowUIHelpers.scrollToBottom(harness.scrollView, animated: false)
        #expect(harness.surface.viewportInteractionEnded(isStreaming: true))
        #expect(harness.surface.followsTail)

        harness.surface.viewportInteractionBegan()
        #expect(!harness.surface.viewportInteractionEnded(isStreaming: false))
        #expect(!harness.surface.followsTail)
    }

    // MARK: - Fixtures

    /// Large enough to take the reader's deferred first-render path.
    private static let deferredDocument = String(
        repeating: "Paragraph with a few words that pad the document out.\n\n",
        count: 4_200
    )
    private static let pastDeferredRenderDelay = Duration.milliseconds(1_200)

    private func markdownConfiguration(
        _ text: String,
        isDone: Bool = true
    ) -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "notes",
            expandedContent: .markdown(text: text),
            toolNamePrefix: "extensions.notes",
            isExpanded: true,
            isDone: isDone
        )
    }

    private func codeConfiguration() -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "read App.swift",
            expandedContent: .code(
                text: "struct App {\n    var name: String\n}",
                language: .swift,
                startLine: 1,
                filePath: "App.swift"
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )
    }

    private func collapsedConfiguration() -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "notes",
            toolNamePrefix: "extensions.notes",
            isExpanded: false,
            isDone: false
        )
    }

    /// Pads `text` with ASCII prose to an exact UTF-8 byte count.
    private static func padded(_ text: String, toUTF8Count utf8Count: Int) -> String {
        let filler = "prose padding "
        var result = text
        while result.utf8.count + filler.utf8.count <= utf8Count {
            result += filler
        }
        result += String(repeating: "x", count: utf8Count - result.utf8.count)
        return result
    }
}

/// A surface mounted in a host inside a bare scroll view, without a tool row.
@MainActor
private final class SurfaceHarness {
    let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 200))
    let host = ToolExpandedSurfaceHostView()
    let surface: ToolExpandedMarkdownSurface

    init() {
        surface = ToolExpandedMarkdownSurface(viewport: scrollView)
        scrollView.addSubview(host)
        surface.mount(in: host)
    }

    @discardableResult
    func apply(
        _ text: String,
        itemID: String = "surface-harness",
        isStreaming: Bool
    ) -> ToolExpandedMarkdownSurface.Outcome {
        surface.apply(ToolExpandedMarkdownSurface.Input(
            itemID: itemID,
            text: text,
            isStreaming: isStreaming,
            textSelectionEnabled: false,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            resourceAccess: .empty,
            sourceFilePath: nil,
            resourcePressure: .nominal,
            viewportWidth: nil,
            viewportFollowsTail: false,
            wasVisible: surface.isViewportActive,
            previousText: nil,
            shouldRerender: true
        ))
    }

    func activate() {
        host.activateSurfaceView(surface.mountedView, contentInsets: surface.mountInsets)
        surface.didActivate()
    }
}
