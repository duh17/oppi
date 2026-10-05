import Testing
import UIKit
@testable import Oppi

@Suite("Notebook cell presentation")
struct NotebookCellPresentationTests {
    private func codeHints(_ language: String = "javascript") -> ToolInputPresentation {
        .init(fields: ["code": .init(role: "code", language: language)])
    }

    private func expanded(
        tool: String,
        args: [String: JSONValue],
        output: String,
        hints: ToolInputPresentation? = nil,
        calls: NestedToolCalls? = nil,
        display: ToolDisplay? = nil,
        isError: Bool = false,
        isDone: Bool = true,
        previewOnly: Bool = false,
        totalBytes: Int? = nil
    ) -> ToolTimelineRowConfiguration {
        var context = ToolPresentationBuilder.Context(
            args: args,
            expandedItemIDs: ["cell"],
            fullOutput: output,
            isLoadingOutput: false
        )
        context.inputPresentation = hints
        context.nestedCalls = calls
        context.display = display
        context.previewOnly = previewOnly
        context.totalBytes = totalBytes
        return ToolPresentationBuilder.build(
            itemID: "cell",
            tool: tool,
            argsSummary: "ignored summary",
            outputPreview: output,
            isError: isError,
            isDone: isDone,
            context: context
        )
    }

    @Test func codeRolePaintsNotebookNotAFencedDocument() throws {
        let config = expanded(
            tool: "python_exec",
            args: ["code": .string("const hits = await lookup()\nreturn hits[0]"), "limit": .number(20)],
            output: "3",
            hints: codeHints(),
            calls: NestedToolCalls(calls: [
                .init(id: "1", name: "lookup", arguments: ["q": .string("oppi")], status: "ok", durationMs: 84)
            ], complete: true)
        )
        guard case .notebook(let plan) = config.expandedContent else {
            Issue.record("Code-role input must paint a notebook cell, not markdown")
            return
        }
        #expect(plan.sources.first?.code == "const hits = await lookup()\nreturn hits[0]")
        #expect(plan.sources.first?.languageName == "JavaScript")
        #expect(plan.metadata == ["limit 20"])
        #expect(plan.calls.first?.name == "lookup")
        #expect(plan.calls.first?.duration == "84 ms")
        if case .stdout(let text) = plan.output {
            #expect(text == "3")
        } else {
            Issue.record("A scalar result should be stdout, not another fence")
        }
        #expect(config.copyOutputText == "3")
        #expect(config.rawMarkdownText?.contains("const hits = await lookup()") == true)
        #expect(config.rawMarkdownText?.hasSuffix("3") == true)
        #expect(!((config.rawMarkdownText ?? "").contains("```")))
        let reader = try #require(ToolTimelineRowFullScreenSupport.staticFullScreenContent(
            configuration: config, outputCopyText: config.copyOutputText, terminalStream: nil))
        guard case .notebook(let opened) = reader else {
            Issue.record("Full-screen reader should show the same notebook cell")
            return
        }
        #expect(opened.sources == plan.sources)
        #expect(opened.calls == plan.calls)
    }

    @Test func toolNameDoesNotSelectTheCell() {
        let named = expanded(
            tool: "codemode",
            args: ["code": .string("return 1")],
            output: "1"
        )
        guard case .markdown = named.expandedContent else {
            Issue.record("A code argument without a code-role fact stays a document")
            return
        }
        let fact = expanded(
            tool: "custom_script",
            args: ["source": .string("print(1)")],
            output: "1",
            hints: .init(fields: ["source": .init(role: "code", language: "python")])
        )
        guard case .notebook(let plan) = fact.expandedContent else {
            Issue.record("Any code-role field paints the cell")
            return
        }
        #expect(plan.sources.first?.languageName == "Python")
    }

    @Test func collapsedTitleIsTheFirstCodeLineWhenSegmentsAreAbsent() {
        var context = ToolPresentationBuilder.Context(
            args: ["code": .string("  \nconst hits = await lookup()\nreturn hits")],
            expandedItemIDs: [],
            fullOutput: "",
            isLoadingOutput: false
        )
        context.inputPresentation = codeHints()
        context.display = .init(title: "Code mode")
        let config = ToolPresentationBuilder.build(
            itemID: "cell", tool: "codemode", argsSummary: "{\"code\":\"...\"}",
            outputPreview: "", isError: false, isDone: false, context: context
        )
        #expect(config.title == "const hits = await lookup()")
        #expect(config.languageBadge == "JavaScript")
        #expect(config.glyph == "chevron.left.forwardslash.chevron.right")
        #expect(config.expandedContent == nil)
    }

    @Test func runningEmptyCellStaysANotebookAndCopyIsUnchanged() throws {
        let config = expanded(
            tool: "script",
            args: ["code": .string("await work()")],
            output: "",
            hints: codeHints(),
            isDone: false
        )
        guard case .notebook(let plan) = config.expandedContent else {
            Issue.record("A running code cell is still a notebook")
            return
        }
        #expect(plan.running)
        #expect(plan.output == .none)
        #expect(config.copyOutputText == nil)
    }

    @Test @MainActor func cellFitsItsSource() {
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: "await lookup()")],
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .stdout("3"),
            availabilityNote: nil,
            running: false,
            failed: false
        )
        let view = NotebookCellView()
        #expect(view.apply(plan))
        #expect(!view.apply(plan))
        let size = view.systemLayoutSizeFitting(
            CGSize(width: 370, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        #expect(size.height > 40)
        #expect(size.height < 500)
        #expect(view.accessibilityIdentifier == "tool.notebook.cell")
    }

    @Test @MainActor func expandedCellDoesNotScroll() {
        let view = NotebookCellView()
        view.apply(NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: String(repeating: "const line = 1\n", count: 40))],
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .stdout(String(repeating: "out\n", count: 20)),
            availabilityNote: nil,
            running: true,
            failed: false
        ))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        view.layoutIfNeeded()

        let scrolls = scrollViews(in: view)
        #expect(scrolls.allSatisfy { $0 is UITextView })
        let texts = scrolls.compactMap { $0 as? UITextView }
        #expect(texts.count >= 2)
        for text in texts {
            #expect(text is BaselineSafeTextView)
            #expect(!text.isScrollEnabled)
            #expect(
                text.gestureRecognizerShouldBegin(text.panGestureRecognizer) == false,
                "Selectable notebook text should pass vertical drags to the timeline"
            )
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for subview in view.subviews {
            found.append(contentsOf: scrollViews(in: subview))
        }
        return found
    }
}
