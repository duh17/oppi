import Testing
import UIKit
@testable import Oppi

// MARK: - Code strategy auto-follow

@Suite("Code render strategy auto-follow")
@MainActor
struct CodeRenderAutoFollowTests {

    @Test("first streaming render enables auto-follow")
    func firstStreamingRenderEnablesAutoFollow() {
        var state = CodeRenderState()
        _ = renderCode("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(state.autoFollow == true)
    }

    @Test("streaming continuation preserves auto-follow")
    func streamingContinuationPreservesAutoFollow() {
        var state = CodeRenderState()
        _ = renderCode("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(state.autoFollow == true)

        _ = renderCode("line1\nline2\n", isStreaming: true, wasVisible: true, state: &state)
        #expect(state.autoFollow == true)
    }

    @Test("cell reuse during streaming re-enables auto-follow")
    func cellReuseDuringStreamingReEnablesAutoFollow() {
        var state = CodeRenderState()
        // Simulate previous tool's content from cell reuse
        _ = renderCode("old tool content", isStreaming: false, wasVisible: false, state: &state)
        #expect(state.autoFollow == false) // done, so false

        // New tool starts streaming — different content, not a continuation
        _ = renderCode("new file line1\n", isStreaming: true, wasVisible: true, state: &state)
        #expect(state.autoFollow == true, "Cell reuse with streaming should re-enable auto-follow")
    }

    @Test("done disables auto-follow")
    func doneDisablesAutoFollow() {
        var state = CodeRenderState()
        _ = renderCode("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(state.autoFollow == true)

        _ = renderCode("line1\nline2\n", isStreaming: false, wasVisible: true, state: &state)
        #expect(state.autoFollow == false)
    }

    @Test("auto-follow triggers followTail scroll behavior")
    func autoFollowTriggersFollowTail() {
        var state = CodeRenderState()
        let result1 = renderCode("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(result1.scrollBehavior == .followTail)

        let result2 = renderCode("line1\nline2\n", isStreaming: true, wasVisible: true, state: &state)
        #expect(result2.scrollBehavior == .followTail)
    }

    // MARK: - Helpers

    private struct CodeRenderState {
        var signature: Int?
        var renderedText: String?
        var autoFollow = false
        var label: UITextView
        var scrollView: UIScrollView

        init() {
            label = UITextView()
            scrollView = UIScrollView()
        }
    }

    @discardableResult
    private func renderCode(
        _ text: String,
        isStreaming: Bool,
        wasVisible: Bool,
        state: inout CodeRenderState
    ) -> ExpandedRenderOutput {
        let result = ToolRowCodeRenderStrategy.render(
            text: text,
            language: nil,
            startLine: 1,
            isStreaming: isStreaming,
            expandedLabel: state.label,
            expandedScrollView: state.scrollView,
            previousSignature: state.signature,
            previousRenderedText: state.renderedText,
            previousAutoFollow: state.autoFollow,
            isCurrentModeCode: state.signature != nil,
            wasExpandedVisible: wasVisible
        )
        state.signature = result.renderSignature
        state.renderedText = result.renderedText
        state.autoFollow = result.shouldAutoFollow
        return result
    }
}

// MARK: - Text strategy auto-follow

@Suite("Text render strategy auto-follow")
@MainActor
struct TextRenderAutoFollowTests {

    @Test("first streaming render enables auto-follow")
    func firstStreamingRenderEnablesAutoFollow() {
        var state = TextRenderState()
        _ = renderText("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(state.autoFollow == true)
    }

    @Test("streaming continuation preserves auto-follow")
    func streamingContinuationPreservesAutoFollow() {
        var state = TextRenderState()
        _ = renderText("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(state.autoFollow == true)

        _ = renderText("line1\nline2\n", isStreaming: true, wasVisible: true, state: &state)
        #expect(state.autoFollow == true)
    }

    @Test("cell reuse during streaming re-enables auto-follow")
    func cellReuseDuringStreamingReEnablesAutoFollow() {
        var state = TextRenderState()
        // Simulate previous tool's content
        _ = renderText("old tool content", isStreaming: false, wasVisible: false, state: &state)
        #expect(state.autoFollow == false)

        // New tool starts streaming — not a continuation of old content
        _ = renderText("completely different\n", isStreaming: true, wasVisible: true, state: &state)
        #expect(state.autoFollow == true, "Cell reuse with streaming should re-enable auto-follow")
    }

    @Test("done disables auto-follow")
    func doneDisablesAutoFollow() {
        var state = TextRenderState()
        _ = renderText("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(state.autoFollow == true)

        _ = renderText("line1\nfinal\n", isStreaming: false, wasVisible: true, state: &state)
        #expect(state.autoFollow == false)
    }

    @Test("auto-follow triggers followTail scroll behavior")
    func autoFollowTriggersFollowTail() {
        var state = TextRenderState()
        let result1 = renderText("line1\n", isStreaming: true, wasVisible: false, state: &state)
        #expect(result1.scrollBehavior == .followTail)

        let result2 = renderText("line1\nline2\n", isStreaming: true, wasVisible: true, state: &state)
        #expect(result2.scrollBehavior == .followTail)
    }

    // MARK: - Helpers

    private struct TextRenderState {
        var signature: Int?
        var renderedText: String?
        var autoFollow = false
        var label: UITextView
        var scrollView: UIScrollView

        init() {
            label = UITextView()
            scrollView = UIScrollView()
        }
    }

    @discardableResult
    private func renderText(
        _ text: String,
        isStreaming: Bool,
        wasVisible: Bool,
        state: inout TextRenderState
    ) -> ExpandedRenderOutput {
        let result = ToolRowTextRenderStrategy.render(
            text: text,
            language: nil,
            isError: false,
            isStreaming: isStreaming,
            outputColor: .white,
            expandedLabel: state.label,
            expandedScrollView: state.scrollView,
            previousSignature: state.signature,
            previousRenderedText: state.renderedText,
            previousAutoFollow: state.autoFollow,
            wasExpandedVisible: wasVisible,
            isCurrentModeText: state.signature != nil,
            isUsingMarkdownLayout: false,
            isUsingReadMediaLayout: false
        )
        state.signature = result.renderSignature
        state.renderedText = result.renderedText
        state.autoFollow = result.shouldAutoFollow
        return result
    }
}
