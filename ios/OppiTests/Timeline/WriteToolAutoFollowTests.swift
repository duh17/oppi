import Testing
import UIKit
@testable import Oppi

// Tests the write tool's streaming viewport auto-follow behavior.
//
// The write tool renders via either the code path (code files) or the
// text path (plain files / arg-preview fallback). Both must auto-scroll
// the inner viewport to follow tail during streaming, matching the behavior
// that already works for thinking rows and edit tool rows.

// MARK: - Strategy-level: code path (write .swift file)

@Suite("Write tool code strategy auto-follow")
@MainActor
struct WriteToolCodeAutoFollowTests {

    /// Simulates incremental write content growth from toolcall_delta args.
    /// Each delta appends more content (like LLM streaming the `content` arg).
    @Test("auto-follow fires on each streaming growth")
    func autoFollowFiresOnEachGrowth() {
        let view = ExpandedToolRowView()

        // First chunk — auto-follow should activate
        renderWriteCode(view, "import Foundation\n", streaming: true, visible: false)
        #expect(view.needsFollowTail, "First chunk should trigger scroll")
        #expect(view.expandedShouldAutoFollow, "Auto-follow should be enabled after first chunk")

        // Second chunk — continuation growth
        let text2 = "import Foundation\n\nstruct Writer {\n"
        view.needsFollowTail = false
        renderWriteCode(view, text2, streaming: true, visible: true)
        #expect(view.needsFollowTail, "Second chunk should trigger scroll")
        #expect(view.expandedShouldAutoFollow, "Auto-follow should remain enabled during streaming")

        // Third chunk — more growth
        let text3 = text2 + "    func write() {\n        print(\"hello\")\n    }\n}\n"
        view.needsFollowTail = false
        renderWriteCode(view, text3, streaming: true, visible: true)
        #expect(view.needsFollowTail, "Third chunk should trigger scroll")
        #expect(view.expandedShouldAutoFollow, "Auto-follow should remain enabled during streaming")
    }

    @Test("auto-follow disabled on done transition")
    func autoFollowDisabledOnDone() {
        let view = ExpandedToolRowView()

        renderWriteCode(view, "import Foundation\n", streaming: true, visible: false)
        #expect(view.expandedShouldAutoFollow)

        // Tool completes
        let finalText = "import Foundation\n\nstruct Writer {}\n"
        renderWriteCode(view, finalText, streaming: false, visible: true)
        #expect(!view.expandedShouldAutoFollow, "Auto-follow should be disabled when done")
    }

    @Test("cell reuse during streaming re-enables auto-follow")
    func cellReuseDuringStreamingReenables() {
        let view = ExpandedToolRowView()

        // Previous tool's done content (cell reuse)
        renderWriteCode(view, "old file content\n", streaming: false, visible: false)
        #expect(!view.expandedShouldAutoFollow)

        // New write tool starts streaming
        renderWriteCode(view, "new content\n", streaming: true, visible: true)
        #expect(view.expandedShouldAutoFollow, "Cell reuse should re-enable auto-follow for new streaming tool")
    }

    // MARK: - Helpers

    private func renderWriteCode(
        _ view: ExpandedToolRowView,
        _ text: String,
        streaming: Bool,
        visible: Bool
    ) {
        _ = view.apply(
            input: ExpandedRenderInput(
                mode: .code(text: text, language: .swift, startLine: 1),
                isStreaming: streaming,
                outputColor: .white
            ),
            wasExpandedVisible: visible
        )
    }
}

// MARK: - Strategy-level: text path (write fallback / plain file)

@Suite("Write tool text strategy auto-follow")
@MainActor
struct WriteToolTextAutoFollowTests {

    /// When write content comes through the text path (no language detected or
    /// arg preview via tool_output), auto-follow must still work.
    @Test("auto-follow fires on each streaming growth via text path")
    func autoFollowFiresOnEachGrowth() {
        let view = ExpandedToolRowView()

        renderWriteText(view, "line 1\n", streaming: true, visible: false)
        #expect(view.needsFollowTail)
        #expect(view.expandedShouldAutoFollow)

        view.needsFollowTail = false
        renderWriteText(view, "line 1\nline 2\nline 3\n", streaming: true, visible: true)
        #expect(view.needsFollowTail)
        #expect(view.expandedShouldAutoFollow)
    }

    @Test("auto-follow disabled on done transition")
    func autoFollowDisabledOnDone() {
        let view = ExpandedToolRowView()

        renderWriteText(view, "content\n", streaming: true, visible: false)
        #expect(view.expandedShouldAutoFollow)

        renderWriteText(view, "content\nfinal\n", streaming: false, visible: true)
        #expect(!view.expandedShouldAutoFollow)
    }

    @Test("cell reuse during streaming re-enables auto-follow")
    func cellReuseDuringStreamingReenables() {
        let view = ExpandedToolRowView()

        renderWriteText(view, "old content", streaming: false, visible: false)
        #expect(!view.expandedShouldAutoFollow)

        renderWriteText(view, "new streaming content\n", streaming: true, visible: true)
        #expect(view.expandedShouldAutoFollow)
    }

    // MARK: - Helpers

    private func renderWriteText(
        _ view: ExpandedToolRowView,
        _ text: String,
        streaming: Bool,
        visible: Bool
    ) {
        _ = view.apply(
            input: ExpandedRenderInput(
                mode: .text(text: text, language: nil, isError: false),
                isStreaming: streaming,
                outputColor: .white
            ),
            wasExpandedVisible: visible
        )
    }
}

// MARK: - View integration: write tool viewport tail visibility

/// Tests that the write tool's expanded scroll view actually scrolls to
/// the bottom during streaming. Checks the real scroll position, not just
/// the auto-follow flag (which can pass trivially when bounds are zero).
///
/// Pattern: create the view inside a window so Auto Layout resolves real
/// bounds, then check the expanded scroll view is near bottom after each
/// streaming apply. This is the same rigor as the thinking row tail test.
@Suite("Write tool viewport tail visibility")
@MainActor
struct WriteToolViewportTailVisibilityTests {

    /// Root cause: code mode activates expandedLabelHeightLock which pins
    /// the label height to the scroll view frame. The label can't grow
    /// beyond the viewport, so contentSize == viewport and there's nothing
    /// to scroll. The user sees only the first viewport-worth of content.
    @Test("code file write content overflows viewport during streaming")
    func codeFileWriteContentOverflowsViewport() {
        let view = makeWindowedWriteView(text: "import Foundation\n", language: .swift)

        // Grow content well past the 200px streaming viewport
        applyStreaming(view, text: generateSwiftCode(lines: 60), language: .swift)

        let scrollView = view.expandedScrollView
        let viewportHeight = scrollView.bounds.height
        let contentHeight = scrollView.contentSize.height

        // Viewport must have real bounds (not zero)
        #expect(viewportHeight > 0, "Expanded scroll view should have non-zero height after layout")
        // Content must overflow the viewport (60 lines >> 200px viewport).
        // BUG: expandedLabelHeightLock clamps contentHeight to viewportHeight
        // so the scroll view can't scroll vertically to follow new content.
        #expect(contentHeight > viewportHeight, "Content should overflow the viewport for auto-follow to work")
    }

    @Test("code file write scroll view is near bottom after growth")
    func codeFileWriteScrollViewNearBottom() {
        let view = makeWindowedWriteView(text: "import Foundation\n", language: .swift)

        // Grow content well past the 200px streaming viewport
        applyStreaming(view, text: generateSwiftCode(lines: 60), language: .swift)

        let scrollView = view.expandedScrollView
        let viewportHeight = scrollView.bounds.height
        let contentHeight = scrollView.contentSize.height
        let offsetY = scrollView.contentOffset.y

        #expect(viewportHeight > 0, "Expanded scroll view should have non-zero height after layout")
        #expect(view.expandedShouldAutoFollow, "Auto-follow should be on during streaming")
        // This only passes if content overflows and followTail actually scrolled
        let isNearBottom = ToolTimelineRowUIHelpers.isNearBottom(scrollView)
        #expect(contentHeight > viewportHeight, "Content must overflow viewport")
        #expect(
            isNearBottom,
            Comment(rawValue: "Scroll view should be near bottom after streaming growth. "
                + "offset=\(offsetY) content=\(contentHeight) viewport=\(viewportHeight)")
        )
    }

    @Test("plain text write scroll view is near bottom after growth")
    func plainTextWriteScrollViewNearBottom() {
        let view = makeWindowedWriteView(text: "line 1\n", language: nil)

        applyStreaming(view, text: generatePlainText(lines: 60), language: nil)

        let scrollView = view.expandedScrollView
        #expect(scrollView.bounds.height > 0, "Expanded scroll view should have non-zero height")
        #expect(view.expandedShouldAutoFollow, "Auto-follow should be on during streaming")
        #expect(
            ToolTimelineRowUIHelpers.isNearBottom(scrollView),
            "Scroll view should be near bottom after plain text growth"
        )
    }

    @Test("scroll view stays near bottom across three consecutive updates")
    func scrollViewNearBottomAcrossThreeUpdates() {
        let view = makeWindowedWriteView(text: "start\n", language: .swift)

        for batch in [30, 60, 90] {
            applyStreaming(view, text: generateSwiftCode(lines: batch), language: .swift)

            let scrollView = view.expandedScrollView
            let nearBottom = ToolTimelineRowUIHelpers.isNearBottom(scrollView)
            #expect(
                nearBottom,
                Comment(rawValue: "Scroll view should be near bottom at \(batch) lines. "
                    + "offset=\(scrollView.contentOffset.y) "
                    + "content=\(scrollView.contentSize.height) "
                    + "viewport=\(scrollView.bounds.height)")
            )
        }
    }

    @Test("done state disables auto-follow")
    func doneStateDisablesAutoFollow() {
        let view = makeWindowedWriteView(
            text: generateSwiftCode(lines: 40),
            language: .swift
        )

        // Transition to done
        view.configuration = makeTimelineToolConfiguration(
            title: "write Test.swift",
            expandedContent: .code(
                text: generateSwiftCode(lines: 40),
                language: .swift,
                startLine: 1,
                filePath: "Test.swift"
            ),
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: true
        )
        forceLayout(view)

        #expect(!view.expandedShouldAutoFollow, "Auto-follow should be off when done")
    }

    // MARK: - Helpers

    /// Create a write tool view inside a UIWindow so Auto Layout gives real
    /// bounds to the expanded scroll view. Without a window, constraints
    /// resolve to zero and isNearBottom returns true trivially.
    private func makeWindowedWriteView(
        text: String,
        language: SyntaxLanguage?
    ) -> ToolTimelineRowContentView {
        let expandedContent: ToolPresentationBuilder.ToolExpandedContent
        if let language {
            expandedContent = .code(text: text, language: language, startLine: 1, filePath: "Test.swift")
        } else {
            expandedContent = .text(text: text, language: nil)
        }

        let config = makeTimelineToolConfiguration(
            title: "write Test.swift",
            expandedContent: expandedContent,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        // Embed in a window to get real layout
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            view.topAnchor.constraint(equalTo: window.topAnchor),
        ])
        window.makeKeyAndVisible()
        forceLayout(view)

        return view
    }

    private func applyStreaming(
        _ view: ToolTimelineRowContentView,
        text: String,
        language: SyntaxLanguage?
    ) {
        let expandedContent: ToolPresentationBuilder.ToolExpandedContent
        if let language {
            expandedContent = .code(text: text, language: language, startLine: 1, filePath: "Test.swift")
        } else {
            expandedContent = .text(text: text, language: nil)
        }

        view.configuration = makeTimelineToolConfiguration(
            title: "write Test.swift",
            expandedContent: expandedContent,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        // apply() must drive auto-follow. Force layout so constraints resolve
        // and followTail actually moves the scroll offset.
        forceLayout(view)
    }

    private func forceLayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // Second pass to settle nested scroll view content size
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func generateSwiftCode(lines: Int) -> String {
        (1...max(1, lines)).map { "    let value\($0) = \($0) // line \($0)" }
            .joined(separator: "\n")
    }

    private func generatePlainText(lines: Int) -> String {
        (1...max(1, lines)).map { "Line \($0) of streaming write content" }
            .joined(separator: "\n")
    }
}

// MARK: - ToolPresentationBuilder: write tool expanded content correctness

@Suite("Write tool presentation builder streaming content")
@MainActor
struct WritePresentationBuilderStreamingTests {

    @Test("write with args content during streaming produces code content")
    func writeArgsStreamingProducesCode() {
        let config = ToolPresentationBuilder.build(
            itemID: "tool-1",
            tool: "write",
            argsSummary: "write Test.swift",
            outputPreview: "",
            isError: false,
            isDone: false,
            context: .init(
                args: [
                    "path": .string("Test.swift"),
                    "content": .string("struct Test {}\n"),
                ],
                expandedItemIDs: ["tool-1"],
                fullOutput: "",
                isLoadingOutput: false
            )
        )

        guard case .code(let text, let language, let startLine, _) = config.expandedContent else {
            Issue.record("Expected .code expanded content for streaming write, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(text == "struct Test {}\n")
        #expect(language == .swift)
        #expect(startLine == 1)
    }

    @Test("write without args content but with output falls back to text")
    func writeNoArgsWithOutputFallsToText() {
        let config = ToolPresentationBuilder.build(
            itemID: "tool-1",
            tool: "write",
            argsSummary: "write Test.swift",
            outputPreview: "streaming preview content",
            isError: false,
            isDone: false,
            context: .init(
                args: ["path": .string("Test.swift")],
                expandedItemIDs: ["tool-1"],
                fullOutput: "streaming preview content",
                isLoadingOutput: false
            )
        )

        guard case .text(let text, _) = config.expandedContent else {
            Issue.record("Expected .text expanded content for write without args content, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(text == "streaming preview content")
    }

    @Test("write with no content shows status placeholder")
    func writeNoContentShowsStatus() {
        let config = ToolPresentationBuilder.build(
            itemID: "tool-1",
            tool: "write",
            argsSummary: "write Test.swift",
            outputPreview: "",
            isError: false,
            isDone: false,
            context: .init(
                args: ["path": .string("Test.swift")],
                expandedItemIDs: ["tool-1"],
                fullOutput: "",
                isLoadingOutput: false
            )
        )

        guard case .status(let message) = config.expandedContent else {
            Issue.record("Expected .status expanded content for write with no content, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(message == "Writing…")
    }

    @Test("write done with args content produces code (not text)")
    func writeDoneWithArgsProducesCode() {
        let config = ToolPresentationBuilder.build(
            itemID: "tool-1",
            tool: "write",
            argsSummary: "write Test.swift",
            outputPreview: "File written successfully",
            isError: false,
            isDone: true,
            context: .init(
                args: [
                    "path": .string("Test.swift"),
                    "content": .string("struct Test {}\n"),
                ],
                expandedItemIDs: ["tool-1"],
                fullOutput: "File written successfully",
                isLoadingOutput: false
            )
        )

        guard case .code(let text, let language, _, _) = config.expandedContent else {
            Issue.record("Expected .code expanded content for done write, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(text == "struct Test {}\n")
        #expect(language == .swift)
    }

    @Test("write markdown file during streaming produces text (not markdown)")
    func writeMarkdownStreamingProducesText() {
        let config = ToolPresentationBuilder.build(
            itemID: "tool-1",
            tool: "write",
            argsSummary: "write README.md",
            outputPreview: "",
            isError: false,
            isDone: false,
            context: .init(
                args: [
                    "path": .string("README.md"),
                    "content": .string("# Title\n\nBody text\n"),
                ],
                expandedItemIDs: ["tool-1"],
                fullOutput: "",
                isLoadingOutput: false
            )
        )

        guard case .text(let text, _) = config.expandedContent else {
            Issue.record("Expected .text expanded content for streaming markdown write, got \(String(describing: config.expandedContent))")
            return
        }
        #expect(text == "# Title\n\nBody text\n")
    }
}

// MARK: - View integration: write tool through ToolTimelineRowContentView

@Suite("Write tool view auto-follow")
@MainActor
struct WriteToolViewAutoFollowTests {

    /// Drive write tool through ToolTimelineRowContentView with incremental
    /// streaming configurations and verify expandedShouldAutoFollow stays on.
    @Test("expandedShouldAutoFollow stays true across streaming updates")
    func autoFollowStaysTrueAcrossUpdates() {
        let view = ToolTimelineRowContentView(configuration: makeWriteConfig(
            text: generateSwiftCode(lines: 5),
            streaming: true
        ))
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.expandedShouldAutoFollow, "Initial streaming should enable auto-follow")

        // Grow content
        view.configuration = makeWriteConfig(
            text: generateSwiftCode(lines: 30),
            streaming: true
        )
        #expect(view.expandedShouldAutoFollow, "Auto-follow should persist after growth")

        // Grow again
        view.configuration = makeWriteConfig(
            text: generateSwiftCode(lines: 60),
            streaming: true
        )
        #expect(view.expandedShouldAutoFollow, "Auto-follow should persist after second growth")
    }

    @Test("done transition disables expandedShouldAutoFollow")
    func doneDisablesAutoFollow() {
        let view = ToolTimelineRowContentView(configuration: makeWriteConfig(
            text: generateSwiftCode(lines: 30),
            streaming: true
        ))
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.expandedShouldAutoFollow)

        // Transition to done
        view.configuration = makeWriteConfig(
            text: generateSwiftCode(lines: 30),
            streaming: false
        )
        #expect(!view.expandedShouldAutoFollow, "Done should disable auto-follow")
    }

    // MARK: - Helpers

    private func makeWriteConfig(
        text: String,
        streaming: Bool
    ) -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "write Generated.swift",
            expandedContent: .code(
                text: text,
                language: .swift,
                startLine: 1,
                filePath: "Generated.swift"
            ),
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: !streaming
        )
    }

    private func generateSwiftCode(lines: Int) -> String {
        (1...max(1, lines)).map { "    let value\($0) = \($0) // generated line \($0)" }
            .joined(separator: "\n")
    }
}
