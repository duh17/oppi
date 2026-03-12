import Testing
import UIKit
@testable import Oppi

// Tests the streaming auto-follow contract: during streaming, the tail
// of the content must be visible in the viewport after each apply().
//
// Tests use the behavioral `isShowingTailForTesting` property instead of
// poking at scroll offsets or layout internals. This catches any regression
// regardless of how auto-follow is implemented internally.

// MARK: - Thinking row

@Suite("Thinking streaming tail visibility")
@MainActor
struct ThinkingStreamingTailVisibilityTests {

    @Test("tail visible after incremental streaming growth")
    func tailVisibleAfterIncrementalGrowth() throws {
        let view = makeStreamingThinkingView(lines: 1)

        // Grow to overflow.
        applyStreaming(view, lines: 80)
        #expect(view.contentIsTruncated, "80 lines should overflow the bubble cap")
        #expect(view.isShowingTailForTesting, "Tail should be visible after first overflow")

        // Grow again.
        applyStreaming(view, lines: 160)
        #expect(view.isShowingTailForTesting, "Tail should be visible after second growth")
    }

    @Test("tail visible across three consecutive updates")
    func tailVisibleAcrossThreeUpdates() throws {
        let view = makeStreamingThinkingView(lines: 1)

        for batch in [60, 120, 180] {
            applyStreaming(view, lines: batch)
            #expect(
                view.isShowingTailForTesting,
                "Tail should be visible at \(batch) lines"
            )
        }
    }

    @Test("tail visible when starting from empty text")
    func tailVisibleFromEmpty() throws {
        let view = makeStreamingThinkingView(text: "")

        applyStreaming(view, lines: 100)
        #expect(view.isShowingTailForTesting, "Tail should be visible after growing from empty")
    }

    @Test("short content reports tail visible without scrolling")
    func shortContentAlwaysShowsTail() throws {
        let view = makeStreamingThinkingView(text: "Short thought")
        #expect(view.isShowingTailForTesting, "Short content fits — tail trivially visible")
    }

    @Test("done state reports tail visible")
    func doneStateReportsTailVisible() throws {
        let view = makeStreamingThinkingView(lines: 80)

        // Transition to done.
        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: generateLines(80),
            themeID: .dark
        )
        #expect(view.isShowingTailForTesting, "Done state should report tail visible")
    }

    // MARK: - Helpers

    private func makeStreamingThinkingView(lines: Int) -> ThinkingTimelineRowContentView {
        makeStreamingThinkingView(text: generateLines(lines))
    }

    private func makeStreamingThinkingView(text: String) -> ThinkingTimelineRowContentView {
        let view = ThinkingTimelineRowContentView(configuration: ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: text,
            fullText: nil,
            themeID: .dark
        ))
        // Initial layout to establish bounds — mirrors collection view first layout.
        _ = fittedTimelineSize(for: view, width: 360)
        return view
    }

    private func applyStreaming(_ view: ThinkingTimelineRowContentView, lines: Int) {
        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: generateLines(lines),
            fullText: nil,
            themeID: .dark
        )
        // No external layout — apply() must drive auto-follow on its own.
    }

    private func applyStreaming(_ view: ThinkingTimelineRowContentView, text: String) {
        view.configuration = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: text,
            fullText: nil,
            themeID: .dark
        )
    }
}

// MARK: - Tool row render strategy callbacks

@Suite("Tool row streaming auto-follow callback")
@MainActor
struct ToolRowStreamingAutoFollowCallbackTests {

    /// Code strategy must declare followTail on each streaming growth.
    @Test("code strategy declares followTail on each streaming growth")
    func codeStrategyFollowTailOnEachGrowth() {
        var state = makeCodeState()

        let r1 = renderCode("line 1\n", streaming: true, visible: false, state: &state)
        #expect(r1.scrollBehavior == .followTail)

        let r2 = renderCode("line 1\nline 2\nline 3\n", streaming: true, visible: true, state: &state)
        #expect(r2.scrollBehavior == .followTail)

        let r3 = renderCode("line 1\nline 2\nline 3\nline 4\nline 5\n", streaming: true, visible: true, state: &state)
        #expect(r3.scrollBehavior == .followTail)
    }

    /// Diff strategy must declare followTail on each streaming growth.
    @Test("diff strategy declares followTail on each streaming growth")
    func diffStrategyFollowTailOnEachGrowth() {
        var state = makeDiffState()

        let lines1: [DiffLine] = [
            DiffLine(kind: .context, text: "line 1"),
            DiffLine(kind: .added, text: "added"),
            DiffLine(kind: .context, text: "line 2"),
        ]
        let r1 = renderDiff(lines1, streaming: true, visible: false, state: &state)
        #expect(r1.scrollBehavior == .followTail)

        let lines2 = lines1 + [
            DiffLine(kind: .added, text: "another"),
            DiffLine(kind: .context, text: "line 3"),
        ]
        let r2 = renderDiff(lines2, streaming: true, visible: true, state: &state)
        #expect(r2.scrollBehavior == .followTail)
    }

    // MARK: - Code helpers

    private struct CodeState {
        var signature: Int?
        var text: String?
        var autoFollow = false
        var label: UITextView
        var scrollView: UIScrollView
    }

    private func makeCodeState() -> CodeState {
        CodeState(label: UITextView(), scrollView: UIScrollView())
    }

    @discardableResult
    private func renderCode(
        _ text: String,
        streaming: Bool,
        visible: Bool,
        state: inout CodeState
    ) -> ExpandedRenderOutput {
        let result = ToolRowCodeRenderStrategy.render(
            text: text,
            language: nil,
            startLine: 1,
            isStreaming: streaming,
            expandedLabel: state.label,
            expandedScrollView: state.scrollView,
            previousSignature: state.signature,
            previousRenderedText: state.text,
            previousAutoFollow: state.autoFollow,
            isCurrentModeCode: state.signature != nil,
            wasExpandedVisible: visible
        )
        state.signature = result.renderSignature
        state.text = result.renderedText
        state.autoFollow = result.shouldAutoFollow
        return result
    }

    // MARK: - Diff helpers

    private struct DiffState {
        var signature: Int?
        var text: String?
        var autoFollow = false
        var label: UITextView
        var scrollView: UIScrollView
    }

    private func makeDiffState() -> DiffState {
        DiffState(label: UITextView(), scrollView: UIScrollView())
    }

    @discardableResult
    private func renderDiff(
        _ lines: [DiffLine],
        streaming: Bool,
        visible: Bool,
        state: inout DiffState
    ) -> ExpandedRenderOutput {
        let result = ToolRowDiffRenderStrategy.render(
            lines: lines,
            path: "file.swift",
            isStreaming: streaming,
            expandedLabel: state.label,
            expandedScrollView: state.scrollView,
            previousSignature: state.signature,
            previousRenderedText: state.text,
            previousAutoFollow: state.autoFollow,
            isCurrentModeDiff: state.signature != nil,
            wasExpandedVisible: visible
        )
        state.signature = result.renderSignature
        state.text = result.renderedText
        state.autoFollow = result.shouldAutoFollow
        return result
    }
}

// MARK: - Shared helpers

@MainActor
private func generateLines(_ count: Int) -> String {
    (1...max(1, count)).map { "Line \($0) of streaming content" }.joined(separator: "\n")
}
