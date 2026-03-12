import Testing
import UIKit
@testable import Oppi

// MARK: - Code auto-follow

@Suite("Code render strategy auto-follow")
@MainActor
struct CodeRenderAutoFollowTests {

    @Test("first streaming render enables auto-follow")
    func firstStreamingRenderEnablesAutoFollow() {
        let view = ExpandedToolRowView()
        _ = renderCode(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == true)
    }

    @Test("streaming continuation preserves auto-follow")
    func streamingContinuationPreservesAutoFollow() {
        let view = ExpandedToolRowView()
        _ = renderCode(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == true)

        _ = renderCode(view, "line1\nline2\n", isStreaming: true, wasVisible: true)
        #expect(view.expandedShouldAutoFollow == true)
    }

    @Test("cell reuse during streaming re-enables auto-follow")
    func cellReuseDuringStreamingReEnablesAutoFollow() {
        let view = ExpandedToolRowView()
        // Simulate previous tool's content from cell reuse
        _ = renderCode(view, "old tool content", isStreaming: false, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == false) // done, so false

        // New tool starts streaming — different content, not a continuation
        _ = renderCode(view, "new file line1\n", isStreaming: true, wasVisible: true)
        #expect(view.expandedShouldAutoFollow == true, "Cell reuse with streaming should re-enable auto-follow")
    }

    @Test("done disables auto-follow")
    func doneDisablesAutoFollow() {
        let view = ExpandedToolRowView()
        _ = renderCode(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == true)

        _ = renderCode(view, "line1\nline2\n", isStreaming: false, wasVisible: true)
        #expect(view.expandedShouldAutoFollow == false)
    }

    @Test("auto-follow triggers scroll callback")
    func autoFollowTriggersScrollCallback() {
        let view = ExpandedToolRowView()
        _ = renderCode(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.needsFollowTail == true)

        view.needsFollowTail = false
        _ = renderCode(view, "line1\nline2\n", isStreaming: true, wasVisible: true)
        #expect(view.needsFollowTail == true)
    }

    // MARK: - Helpers

    @discardableResult
    private func renderCode(
        _ view: ExpandedToolRowView,
        _ text: String,
        isStreaming: Bool,
        wasVisible: Bool
    ) -> ExpandedRenderResult {
        view.needsFollowTail = false
        return view.apply(
            input: ExpandedRenderInput(
                mode: .code(text: text, language: nil, startLine: 1),
                isStreaming: isStreaming,
                outputColor: .white
            ),
            wasExpandedVisible: wasVisible
        )
    }
}

// MARK: - Text auto-follow

@Suite("Text render strategy auto-follow")
@MainActor
struct TextRenderAutoFollowTests {

    @Test("first streaming render enables auto-follow")
    func firstStreamingRenderEnablesAutoFollow() {
        let view = ExpandedToolRowView()
        _ = renderText(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == true)
    }

    @Test("streaming continuation preserves auto-follow")
    func streamingContinuationPreservesAutoFollow() {
        let view = ExpandedToolRowView()
        _ = renderText(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == true)

        _ = renderText(view, "line1\nline2\n", isStreaming: true, wasVisible: true)
        #expect(view.expandedShouldAutoFollow == true)
    }

    @Test("cell reuse during streaming re-enables auto-follow")
    func cellReuseDuringStreamingReEnablesAutoFollow() {
        let view = ExpandedToolRowView()
        // Simulate previous tool's content
        _ = renderText(view, "old tool content", isStreaming: false, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == false)

        // New tool starts streaming — not a continuation of old content
        _ = renderText(view, "completely different\n", isStreaming: true, wasVisible: true)
        #expect(view.expandedShouldAutoFollow == true, "Cell reuse with streaming should re-enable auto-follow")
    }

    @Test("done disables auto-follow")
    func doneDisablesAutoFollow() {
        let view = ExpandedToolRowView()
        _ = renderText(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.expandedShouldAutoFollow == true)

        _ = renderText(view, "line1\nfinal\n", isStreaming: false, wasVisible: true)
        #expect(view.expandedShouldAutoFollow == false)
    }

    @Test("auto-follow triggers scroll callback")
    func autoFollowTriggersScrollCallback() {
        let view = ExpandedToolRowView()
        _ = renderText(view, "line1\n", isStreaming: true, wasVisible: false)
        #expect(view.needsFollowTail == true)

        view.needsFollowTail = false
        _ = renderText(view, "line1\nline2\n", isStreaming: true, wasVisible: true)
        #expect(view.needsFollowTail == true)
    }

    // MARK: - Helpers

    @discardableResult
    private func renderText(
        _ view: ExpandedToolRowView,
        _ text: String,
        isStreaming: Bool,
        wasVisible: Bool
    ) -> ExpandedRenderResult {
        view.needsFollowTail = false
        return view.apply(
            input: ExpandedRenderInput(
                mode: .text(text: text, language: nil, isError: false),
                isStreaming: isStreaming,
                outputColor: .white
            ),
            wasExpandedVisible: wasVisible
        )
    }
}
