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
        details: JSONValue? = nil,
        display: ToolDisplay? = nil,
        isError: Bool = false,
        isDone: Bool = true,
        previewOnly: Bool = false,
        totalBytes: Int? = nil,
        outputPresentation: ToolOutputPresentation? = nil
    ) -> ToolTimelineRowConfiguration {
        var context = ToolPresentationBuilder.Context(
            args: args,
            details: details,
            expandedItemIDs: ["cell"],
            fullOutput: output,
            isLoadingOutput: false
        )
        context.inputPresentation = hints
        context.nestedCalls = calls
        context.display = display
        context.previewOnly = previewOnly
        context.totalBytes = totalBytes
        context.outputPresentation = outputPresentation
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

    @Test func declaredStatusHeaderIsHiddenFromTheCellButNotFromCopy() {
        let header = ToolOutputPresentation(
            kind: "structured",
            statusHeader: "Script (completed|failed)\\nWall time [0-9.]+ seconds\\nOutput:\\n\\n?"
        )
        let raw = "Script completed\nWall time 1.6 seconds\nOutput:\n\ntags: 14\nreleases: 3"
        let config = expanded(
            tool: "script",
            args: ["code": .string("text(1)")],
            output: raw,
            hints: codeHints(),
            outputPresentation: header
        )
        guard case .notebook(let plan) = config.expandedContent else {
            Issue.record("Code-role input paints a notebook cell")
            return
        }
        #expect(plan.output == .stdout("tags: 14\nreleases: 3"))

        // Printed lines ending in a returned object stay printed text, not
        // an escaped markdown document.
        let mixed = expanded(
            tool: "script",
            args: ["code": .string("text(1)")],
            output: "Script completed\nWall time 0.1 seconds\nOutput:\n\nnames:\n[\"voice_create\"]\n{\"stored\":1}",
            hints: codeHints(),
            outputPresentation: header
        )
        guard case .notebook(let printed) = mixed.expandedContent else {
            Issue.record("Code-role input paints a notebook cell")
            return
        }
        #expect(printed.output == .stdout("names:\n[\"voice_create\"]\n{\"stored\":1}"))
        #expect(config.copyOutputText == raw)

        // Without a match (rejected input has no header), nothing is hidden.
        let rejected = expanded(
            tool: "script",
            args: ["code": .string("text(1)")],
            output: "Script completed early",
            hints: codeHints(),
            outputPresentation: header
        )
        guard case .notebook(let unchanged) = rejected.expandedContent else {
            Issue.record("Code-role input paints a notebook cell")
            return
        }
        #expect(unchanged.output == .stdout("Script completed early"))
    }

    @Test func callArgumentsReadAsValuesNotJSON() throws {
        let config = expanded(
            tool: "script",
            args: ["code": .string("await tools.bash()")],
            output: "",
            hints: codeHints(),
            calls: NestedToolCalls(calls: [
                .init(id: "1", name: "bash", arguments: ["command": .string("git log\n-5")], status: "ok"),
                .init(id: "2", name: "read", arguments: ["path": .string("A.md"), "limit": .number(80)], status: "ok"),
                .init(id: "3", name: "ping", arguments: [:], status: "ok"),
            ], complete: true)
        )
        guard case .notebook(let plan) = config.expandedContent else {
            Issue.record("Code-role input paints a notebook cell")
            return
        }
        #expect(plan.calls.map(\.arguments) == ["git log -5", "limit: 80  path: A.md", nil])
    }

    @Test func toolNameDoesNotSelectTheCell() {
        let named = expanded(
            tool: "codemode",
            args: ["code": .string("return 1")],
            output: "1"
        )
        guard case .notebook(let arguments) = named.expandedContent else {
            Issue.record("A generic tool paints a notebook cell")
            return
        }
        #expect(!arguments.inputIsCode, "Without a code-role fact the cell shows arguments, not code")
        #expect(arguments.sources.first?.code == "code: return 1")
        #expect(arguments.metadata.isEmpty)
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

    @Test func argumentCellFormatsAWholeJSONResultAndPrintsText() throws {
        // A todo-style list: the formatted document opens with a bold key and
        // nests a table under a list item. It must render, not print as Markdown source.
        let json = expanded(
            tool: "todo",
            args: ["action": .string("list"), "note": .string("line one\nline two")],
            output: #"{"assigned":[],"open":[{"id":"TODO-1","title":"Ship build"}]}"#
        )
        guard case .notebook(let cell) = json.expandedContent else {
            Issue.record("A generic tool paints a notebook cell")
            return
        }
        #expect(cell.sources.first?.code == "action: list\nnote: |\n  line one\n  line two")
        #expect(cell.sources.first?.syntaxLanguage == .yaml)
        guard case .rich(let formatted) = cell.output else {
            Issue.record("A whole-JSON result renders as a formatted document")
            return
        }
        #expect(formatted.contains("Ship build"))

        let printed = expanded(tool: "web_search", args: ["query": .string("pi")], output: "# Results\n\n- one")
        guard case .notebook(let plain) = printed.expandedContent else {
            Issue.record("A generic tool paints a notebook cell")
            return
        }
        #expect(plain.output == .stdout("# Results\n\n- one"), "Printed text stays as printed, like a terminal")
    }

    @Test @MainActor func cellWithoutArgumentsStillOpensTheReader() throws {
        // The row's own gate, not just the reader factory: a no-argument call
        // with only a result, or only nested calls, must answer double-tap.
        let resultOnly = expanded(tool: "get_status", args: [:], output: #"{"ok":true}"#)
        let callsOnly = expanded(
            tool: "parent", args: [:], output: "",
            calls: NestedToolCalls(calls: [.init(id: "1", name: "child", status: "ok")], complete: true)
        )
        for config in [resultOnly, callsOnly] {
            guard case .notebook(let cell) = config.expandedContent else {
                Issue.record("A generic call paints a notebook cell")
                continue
            }
            #expect(cell.sources.isEmpty)
            let policy = try #require(ToolRowPlanBuilder.build(configuration: config).interactionPolicy)
            #expect(policy.supportsFullScreenPreview)
            let reader = try #require(ToolTimelineRowFullScreenSupport.fullScreenContent(
                configuration: config, outputCopyText: config.copyOutputText,
                interactionPolicy: policy, terminalStream: nil, sourceStream: nil
            ))
            guard case .notebook(let opened) = reader else {
                Issue.record("The reader shows the same cell")
                continue
            }
            #expect(opened == cell)
        }
    }

    @Test func producerCodeAndDiffKeepTheirHighlightedFence() {
        let code = expanded(
            tool: "codegen", args: ["name": .string("App")], output: "func app() {}",
            details: .object([
                "expandedText": .string("func app() {}"),
                "presentationFormat": .string("code"),
                "language": .string("swift"),
            ])
        )
        guard case .notebook(let cell) = code.expandedContent else {
            Issue.record("A generic call paints a notebook cell")
            return
        }
        #expect(cell.output == .rich("```swift\nfunc app() {}\n```"))

        let plain = expanded(
            tool: "echo", args: [:], output: "raw",
            details: .object(["expandedText": .string("hello"), "presentationFormat": .string("terminal")])
        )
        guard case .notebook(let printed) = plain.expandedContent else {
            Issue.record("A generic call paints a notebook cell")
            return
        }
        #expect(printed.output == .stdout("hello"), "A plain-text fence reads as printed output")
    }

    @Test func argumentValuesYAMLWouldMisreadAreQuoted() throws {
        let config = expanded(
            tool: "gh",
            args: ["title": .string("fix #123"), "ref": .string("main"), "note": .string("- bullet"), "count": .number(3)],
            output: "ok"
        )
        guard case .notebook(let cell) = config.expandedContent else {
            Issue.record("A generic call paints a notebook cell")
            return
        }
        let source = try #require(cell.sources.first?.code)
        #expect(source.contains(#"title: "fix #123""#))
        #expect(source.contains(#"note: "- bullet""#))
        #expect(source.contains("ref: main"))
        #expect(source.contains("count: 3"))
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

        var directiveContext = ToolPresentationBuilder.Context(
            args: ["code": .string("// @options: {\"timeout_ms\": 60000}\n// Find release tags\nawait tools.bash()")],
            expandedItemIDs: [],
            fullOutput: "",
            isLoadingOutput: false
        )
        directiveContext.inputPresentation = codeHints()
        let directive = ToolPresentationBuilder.build(
            itemID: "cell", tool: "codemode", argsSummary: "",
            outputPreview: "", isError: false, isDone: false, context: directiveContext
        )
        #expect(directive.title == "// Find release tags")
        #expect(config.glyph == "function")
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

        // Progress details repeat the calls; they are not output.
        var context = ToolPresentationBuilder.Context(
            args: ["code": .string("await tools.bash()")],
            details: .object(["calls": .array([.object(["name": .string("bash"), "status": .string("running")])])]),
            expandedItemIDs: ["cell"],
            fullOutput: "",
            isLoadingOutput: false
        )
        context.inputPresentation = codeHints()
        context.nestedCalls = NestedToolCalls(calls: [.init(id: "1", name: "bash", status: "running")], complete: true)
        let progress = ToolPresentationBuilder.build(
            itemID: "cell", tool: "script", argsSummary: "", outputPreview: "",
            isError: false, isDone: false, context: context
        )
        guard case .notebook(let running) = progress.expandedContent else {
            Issue.record("A running code cell is still a notebook")
            return
        }
        #expect(running.output == .none)
        #expect(running.calls.count == 1)
    }

    @Test @MainActor func cellFitsItsSource() {
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: "await lookup()")],
            inputIsCode: true,
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
        #expect(buttons(in: view).isEmpty)
    }

    private func buttons(in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton { found.append(button) }
        for subview in view.subviews {
            found.append(contentsOf: buttons(in: subview))
        }
        return found
    }

    @Test @MainActor func notebookPinchLivesOnTheExpandedContainer() throws {
        let config = expanded(
            tool: "script",
            args: ["code": .string("await lookup()")],
            output: "3",
            hints: codeHints()
        )
        let row = ToolTimelineRowContentView(configuration: config)
        let pinch = row.expandedContainer.gestureRecognizers?.first { $0 is UIPinchGestureRecognizer }
        #expect(pinch?.isEnabled == true)
        #expect(row.expandedScrollView.gestureRecognizers?.contains { $0 is UIPinchGestureRecognizer } != true)
        let containerDoubleTap = row.expandedContainer.gestureRecognizers?
            .compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.numberOfTapsRequired == 2 }
        let scrollDoubleTap = row.expandedScrollView.gestureRecognizers?
            .compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.numberOfTapsRequired == 2 }
        let opener = try #require(containerDoubleTap)
        let hiddenOpener = try #require(scrollDoubleTap)
        #expect(row.expandedScrollView.isHidden)
        #expect(!row.gestureRecognizer(opener, shouldRequireFailureOf: hiddenOpener))
    }

    @Test @MainActor func inlineCellLeavesDoubleTapToTheRowAndTheReaderSelects() {
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: "await lookup()")],
            inputIsCode: true,
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .stdout("3"),
            availabilityNote: nil,
            running: false,
            failed: false
        )
        let inline = NotebookCellView()
        inline.apply(plan)
        let inlineTexts = scrollViews(in: inline).compactMap { $0 as? UITextView }
        #expect(inlineTexts.count == 2)
        #expect(inlineTexts.allSatisfy { !$0.isSelectable })

        let reader = NotebookCellView(mode: .reader(.init()))
        reader.apply(plan)
        let readerTexts = scrollViews(in: reader).compactMap { $0 as? UITextView }
        #expect(readerTexts.count == 2)
        #expect(readerTexts.allSatisfy { $0.isSelectable })
    }

    @Test @MainActor func inlineCellTrimsLongSectionsAndTheReaderShowsAll() {
        let code = (1...40).map { "const line\($0) = \($0)" }.joined(separator: "\n")
        let calls = (1...9).map { _ in NotebookCellPlan.Call(name: "bash", status: "ok", duration: nil, arguments: "ls", error: nil) }
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: code)],
            inputIsCode: true,
            metadata: [],
            calls: calls,
            omittedCalls: 0,
            callsIncomplete: false,
            output: .stdout("done"),
            availabilityNote: nil,
            running: false,
            failed: false
        )
        let inline = NotebookCellView()
        inline.apply(plan)
        let inlineCode = scrollViews(in: inline).compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "tool.notebook.code" }
        #expect(inlineCode?.text.hasSuffix("const line12 = 12") == true)
        #expect(labels(in: inline).contains("+28 more lines"))
        #expect(labels(in: inline).contains("+3 more calls"))
        #expect(views(in: inline, id: "tool.notebook.call").count == 6)

        let reader = NotebookCellView(mode: .reader(.init()))
        reader.apply(plan)
        let readerCode = scrollViews(in: reader).compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "tool.notebook.code" }
        #expect(readerCode?.text == code)
        #expect(views(in: reader, id: "tool.notebook.call").count == 9)
    }

    @Test @MainActor func cellNeitherStretchesNorSqueezesItsRows() throws {
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: (1...20).map { "const a\($0) = 1" }.joined(separator: "\n"))],
            inputIsCode: true,
            metadata: [],
            calls: [
                .init(name: "bash", status: "ok", duration: "39 ms", arguments: "git tag --list", error: nil),
                .init(name: "bash", status: "running", duration: nil, arguments: "gh release list", error: nil),
            ],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .none,
            availabilityNote: nil,
            running: true,
            failed: false
        )
        let view = NotebookCellView()
        view.apply(plan)
        let fit = view.systemLayoutSizeFitting(
            CGSize(width: 340, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        func rowHeights(cellHeight: CGFloat) -> [CGFloat] {
            view.frame = CGRect(x: 0, y: 0, width: 340, height: cellHeight)
            view.layoutIfNeeded()
            return views(in: view, id: "tool.notebook.call").map(\.bounds.height)
        }
        let natural = rowHeights(cellHeight: fit.height)
        #expect(natural.count == 2)
        // A row taller than the content leaves space below; rows keep their size.
        #expect(rowHeights(cellHeight: fit.height + 120) == natural)
        // A capped row clips; captions keep their height instead of collapsing.
        _ = rowHeights(cellHeight: fit.height - 60)
        let caption = try #require(allLabels(in: view).first { $0.text == "+8 more lines" })
        #expect(caption.bounds.height > 8)
    }

    private func allLabels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = (view as? UILabel).map { [$0] } ?? []
        for subview in view.subviews { found.append(contentsOf: allLabels(in: subview)) }
        return found
    }

    private func labels(in view: UIView) -> [String] {
        var found: [String] = []
        if let label = view as? UILabel, let text = label.text { found.append(text) }
        for subview in view.subviews { found.append(contentsOf: labels(in: subview)) }
        return found
    }

    private func views(in view: UIView, id: String) -> [UIView] {
        var found: [UIView] = view.accessibilityIdentifier == id ? [view] : []
        for subview in view.subviews { found.append(contentsOf: views(in: subview, id: id)) }
        return found
    }

    @Test @MainActor func expandedCellDoesNotScroll() {
        let view = NotebookCellView()
        view.apply(NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: String(repeating: "const line = 1\n", count: 40))],
            inputIsCode: true,
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
                "Notebook text should pass vertical drags to the timeline"
            )
        }
    }

    @Test @MainActor func longArgumentDefersHighlightOffTheExpansionTap() {
        NotebookCellView.deferredHighlightDelayForTesting = .milliseconds(400)
        defer { NotebookCellView.deferredHighlightDelayForTesting = nil }

        let command = "cd ~/workspace/oppi && " + String(repeating: "echo ready && ", count: 30)
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "yaml", code: "command: " + command)],
            inputIsCode: false,
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .stdout("Backgrounded as job bash-32"),
            availabilityNote: nil,
            running: false,
            failed: false
        )
        let view = NotebookCellView()
        #expect(view.apply(plan))
        #expect(view.debugHighlightPendingForTesting)
        let code = scrollViews(in: view).compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "tool.notebook.code" }
        #expect(code?.text.contains("echo ready") == true)
        #expect(view.debugDeferredHighlightCountForTesting == 0)

        let short = NotebookCellView()
        short.apply(NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: "await lookup()")],
            inputIsCode: true,
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .none,
            availabilityNote: nil,
            running: false,
            failed: false
        ))
        #expect(!short.debugHighlightPendingForTesting)
    }

    @Test @MainActor func inlineRichOutputStaysAPreviewAndTheReaderKeepsTheDocument() {
        let tail = "TAIL_MARKER_SHOULD_NOT_PAINT"
        let body = (1...80).map { "paragraph \($0) of the formatted result" }.joined(separator: "\n")
            + "\n" + tail
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "yaml", code: "action: list")],
            inputIsCode: false,
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .rich(body),
            availabilityNote: nil,
            running: false,
            failed: false
        )
        let inline = NotebookCellView()
        inline.apply(plan)
        #expect(!paintedText(in: inline).contains(tail))
        #expect(firstView(of: AssistantMarkdownContentView.self, in: inline) != nil)
        // The row fades a clipped cell. A caption after the body would sit past the cap.
        #expect(!labels(in: inline).contains { $0.contains("more lines") })

        let reader = NotebookCellView(mode: .reader(.init()))
        reader.apply(plan)
        #expect(paintedText(in: reader).contains(tail))
    }

    @Test @MainActor func seriousPressureLeavesAShortSourcePlain() {
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "javascript", code: "await lookup()")],
            inputIsCode: true,
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .none,
            availabilityNote: nil,
            running: false,
            failed: false
        )
        let view = NotebookCellView()
        view.apply(plan, pressure: .serious)
        #expect(!view.debugHighlightPendingForTesting)
        let code = scrollViews(in: view).compactMap { $0 as? UITextView }.first
        let colors = foregroundColors(in: code?.attributedText)
        #expect(colors.count <= 1)
    }

    @Test @MainActor func richHeightIsNotFrozenFromTheUnsizedPass() {
        let paragraph = String(repeating: "word ", count: 80)
        let plan = NotebookCellPlan(
            sources: [.init(label: nil, language: "yaml", code: "action: list")],
            inputIsCode: false,
            metadata: [],
            calls: [],
            omittedCalls: 0,
            callsIncomplete: false,
            output: .rich(paragraph),
            availabilityNote: nil,
            running: false,
            failed: false
        )
        let view = NotebookCellView()
        view.apply(plan)
        let unsized = view.systemLayoutSizeFitting(
            CGSize(width: 360, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(x: 0, y: 0, width: 200, height: unsized.height)
        view.layoutIfNeeded()
        let narrow = view.systemLayoutSizeFitting(
            CGSize(width: 200, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        #expect(narrow.height != unsized.height)
    }

    @Test @MainActor func repeatedNotebookApplyDoesNotInvalidateTheTimeline() {
        var invalidations = 0
        ToolTimelineRowPresentationHelpers.enclosingLayoutInvalidationHookForTesting = {
            invalidations += 1
        }
        defer { ToolTimelineRowPresentationHelpers.enclosingLayoutInvalidationHookForTesting = nil }

        let config = expanded(
            tool: "background_job",
            args: ["command": .string("echo ready")],
            output: "Backgrounded as job bash-32"
        )
        let row = ToolTimelineRowContentView(configuration: config)
        _ = row.systemLayoutSizeFitting(
            CGSize(width: 360, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let afterInstall = invalidations
        #expect(afterInstall > 0)
        row.configuration = config
        #expect(invalidations == afterInstall)
    }

    private func foregroundColors(in text: NSAttributedString?) -> Set<UIColor> {
        guard let text, text.length > 0 else { return [] }
        var colors: Set<UIColor> = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let color = value as? UIColor { colors.insert(color) }
        }
        return colors
    }

    private func paintedText(in view: UIView) -> String {
        var parts: [String] = []
        if let label = view as? UILabel, let text = label.text { parts.append(text) }
        if let textView = view as? UITextView {
            parts.append(textView.text ?? textView.attributedText?.string ?? "")
        }
        for subview in view.subviews {
            parts.append(paintedText(in: subview))
        }
        return parts.joined(separator: "\n")
    }

    private func firstView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(of: type, in: subview) { return match }
        }
        return nil
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

extension NotebookCellPlan {
    /// Everything the cell paints as text: source, output, and its caption.
    var paintedText: String {
        let output: String
        switch self.output {
        case .none: output = ""
        case .stdout(let text), .rich(let text): output = text
        }
        return (sources.map(\.code) + [output, availabilityNote ?? ""]).joined(separator: "\n")
    }
}
