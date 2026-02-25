import Foundation
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("ToolTimelineRowContentView Mode Dispatch")
struct ToolTimelineRowModeDispatchTests {
    private static let testPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    private struct ExpectedVisibility {
        let expanded: Bool
        let command: Bool
        let output: Bool
    }

    private struct DispatchCase {
        let name: String
        let toolNamePrefix: String
        let content: ToolPresentationBuilder.ToolExpandedContent
        let expected: ExpectedVisibility
    }

    @Test func expandedModesRouteToExpectedContainers() throws {
        let cases: [DispatchCase] = [
            DispatchCase(
                name: "bash",
                toolNamePrefix: "$",
                content: .bash(command: "echo hi", output: "hi", unwrapped: true),
                expected: .init(expanded: false, command: true, output: true)
            ),
            DispatchCase(
                name: "diff",
                toolNamePrefix: "edit",
                content: .diff(lines: [
                    DiffLine(kind: .removed, text: "let x = 1"),
                    DiffLine(kind: .added, text: "let x = 2"),
                ], path: "src/main.swift"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "code",
                toolNamePrefix: "read",
                content: .code(text: "struct App {}", language: .swift, startLine: 1, filePath: "App.swift"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "markdown",
                toolNamePrefix: "read",
                content: .markdown(text: "# Header\n\nBody"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "todoCard",
                toolNamePrefix: "todo",
                content: .todoCard(output: "{\"id\":\"TODO-1\",\"title\":\"Test\"}"),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "plot",
                toolNamePrefix: "plot",
                content: .plot(
                    spec: PlotChartSpec(
                        title: "Pace",
                        rows: [
                            .init(id: 0, values: ["x": .number(0), "pace": .number(295)]),
                            .init(id: 1, values: ["x": .number(1), "pace": .number(292)]),
                        ],
                        marks: [
                            .init(
                                id: "pace-line",
                                type: .line,
                                x: "x",
                                y: "pace"
                            ),
                        ],
                        xAxis: .init(label: "Distance", invert: false),
                        yAxis: .init(label: "Pace", invert: true),
                        interaction: .init(xSelection: true, xRangeSelection: false, scrollableX: false),
                        preferredHeight: 200
                    ),
                    fallbackText: "pace chart"
                ),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "readMedia",
                toolNamePrefix: "read",
                content: .readMedia(
                    output: "Read image file [image/png]\n\ndata:image/png;base64,\(Self.testPNGBase64)",
                    filePath: "fixtures/image.png",
                    startLine: 1
                ),
                expected: .init(expanded: true, command: false, output: false)
            ),
            DispatchCase(
                name: "text",
                toolNamePrefix: "remember",
                content: .text(text: "remembered notes", language: nil),
                expected: .init(expanded: true, command: false, output: false)
            ),
        ]

        for testCase in cases {
            let view = ToolTimelineRowContentView(configuration: makeToolConfiguration(
                toolNamePrefix: testCase.toolNamePrefix,
                expandedContent: testCase.content,
                isExpanded: true
            ))

            _ = fittedSize(for: view, width: 360)

            let expandedContainer = try #require(privateView(named: "expandedContainer", in: view))
            let commandContainer = try #require(privateView(named: "commandContainer", in: view))
            let outputContainer = try #require(privateView(named: "outputContainer", in: view))

            #expect(
                expandedContainer.isHidden == !testCase.expected.expanded,
                "Mode \(testCase.name): expanded container visibility mismatch"
            )
            #expect(
                commandContainer.isHidden == !testCase.expected.command,
                "Mode \(testCase.name): command container visibility mismatch"
            )
            #expect(
                outputContainer.isHidden == !testCase.expected.output,
                "Mode \(testCase.name): output container visibility mismatch"
            )
        }
    }

    @Test func expandedTodoItemBodyUsesMarkdownWhileKeepingMetadataRows() throws {
        let output = """
        {
          "id": "TODO-md-1",
          "title": "Render todo body as markdown",
          "status": "open",
          "created_at": "2026-02-24T09:00:00.000Z",
          "tags": ["ios", "live-activity"],
          "body": "## Summary\\n- Render markdown body\\n- Keep tags visible"
        }
        """

        let view = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "todo",
            expandedContent: .todoCard(output: output),
            isExpanded: true
        ))

        _ = fittedSize(for: view, width: 360)

        let hosted = try #require(privateHostedExpandedView(in: view))
        let markdownView = firstView(ofType: AssistantMarkdownContentView.self, in: hosted)
        #expect(markdownView != nil)

        let labels = allLabels(in: hosted).map(renderedText(of:))
        #expect(labels.contains(where: { $0.contains("TODO-md-1") }))
        #expect(labels.contains(where: { $0.contains("tags: ios, live-activity") }))
    }

    @Test func reproducesFatalAccessConflictWhenResettingOutputScrollOnReconfigure() throws {
        let longOutput = Array(repeating: "line", count: 300).joined(separator: "\n")
        let initial = makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: "tail -f log", output: longOutput, unwrapped: true),
            isExpanded: true
        )
        let cleared = makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: nil, output: nil, unwrapped: true),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: initial)
        _ = fittedSize(for: view, width: 360)

        let outputScrollView = try #require(privateScrollView(named: "outputScrollView", in: view))
        outputScrollView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)

        // Reconfiguring to empty output triggers resetOutputState(), which
        // programmatically resets contentOffset and synchronously calls
        // scrollViewDidScroll(). Current code passes outputShouldAutoFollow
        // as inout into resetOutputState, which can trigger a Swift exclusivity trap.
        view.configuration = cleared

        _ = fittedSize(for: view, width: 360)
    }

    // Regression: cell reuse from markdown mode to diff mode left stale
    // markdown content competing with the diff label for the shared
    // contentLayoutGuide height, causing Auto Layout to zero out the label.
    //
    // The invariant: when switching to label-based modes (diff, code, text),
    // the markdown view must have its content cleared so it no longer
    // contributes conflicting intrinsic size to the shared content guide.
    @Test func cellReuseFromMarkdownToDiffClearsStaleMarkdownContent() throws {
        // Phase 1: configure as expanded markdown (read .md tool)
        let markdownConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .markdown(text: "# Big Header\n\nLots of **markdown** content.\n\n- Item A\n- Item B\n- Item C"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: markdownConfig)
        _ = fittedSize(for: view, width: 360)

        // Verify markdown view has content after phase 1
        let markdownView = try #require(
            privateView(named: "expandedMarkdownView", in: view) as? AssistantMarkdownContentView
        )
        let markdownStack = try #require(markdownStackView(in: markdownView))
        #expect(
            markdownStack.arrangedSubviews.count > 0,
            "Markdown view should have content after markdown config"
        )

        // Phase 2: reconfigure same view as expanded diff (edit tool — simulates cell reuse)
        let diffConfig = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .context, text: "import Foundation"),
                DiffLine(kind: .removed, text: "let old = false"),
                DiffLine(kind: .removed, text: "let stale = true"),
                DiffLine(kind: .added, text: "let new = true"),
                DiffLine(kind: .context, text: "// end"),
            ], path: "Core/Model.swift"),
            isExpanded: true
        )

        view.configuration = diffConfig
        _ = fittedSize(for: view, width: 360)

        // The diff label must have attributed text
        let expandedLabel = try #require(privateView(named: "expandedLabel", in: view) as? UILabel)
        let attributedText = try #require(expandedLabel.attributedText)
        #expect(attributedText.length > 0)
        #expect(attributedText.string.contains("let new = true"))

        // CRITICAL: stale markdown content must be cleared to prevent
        // constraint conflicts with the diff label in the shared
        // contentLayoutGuide. Both views pin to all four edges at
        // required priority — if they report different intrinsic heights,
        // Auto Layout breaks one constraint, potentially zeroing the label.
        #expect(
            markdownStack.arrangedSubviews.isEmpty,
            "Stale markdown content must be cleared when switching to diff mode"
        )
    }

    // Same invariant for markdown → code mode (read .md → read .swift reuse)
    @Test func cellReuseFromMarkdownToCodeClearsStaleMarkdownContent() throws {
        let markdownConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .markdown(text: "# Title\n\nBody paragraph."),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: markdownConfig)
        _ = fittedSize(for: view, width: 360)

        let markdownView = try #require(
            privateView(named: "expandedMarkdownView", in: view) as? AssistantMarkdownContentView
        )
        let markdownStack = try #require(markdownStackView(in: markdownView))
        #expect(markdownStack.arrangedSubviews.count > 0)

        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: "struct App {\n    var name: String\n}",
                language: .swift,
                startLine: 1,
                filePath: "App.swift"
            ),
            isExpanded: true
        )

        view.configuration = codeConfig
        _ = fittedSize(for: view, width: 360)

        let expandedLabel = try #require(privateView(named: "expandedLabel", in: view) as? UILabel)
        let attributedText = try #require(expandedLabel.attributedText)
        #expect(attributedText.string.contains("struct App"))

        #expect(
            markdownStack.arrangedSubviews.isEmpty,
            "Stale markdown content must be cleared when switching to code mode"
        )
    }

    // Verify the hosted view path (todo, plot) also clears stale markdown
    @Test func cellReuseFromMarkdownToHostedViewClearsStaleMarkdownContent() throws {
        let markdownConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .markdown(text: "# Docs\n\nExplanation here."),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: markdownConfig)
        _ = fittedSize(for: view, width: 360)

        let markdownView = try #require(
            privateView(named: "expandedMarkdownView", in: view) as? AssistantMarkdownContentView
        )
        let markdownStack = try #require(markdownStackView(in: markdownView))
        #expect(markdownStack.arrangedSubviews.count > 0)

        let todoConfig = makeToolConfiguration(
            toolNamePrefix: "todo",
            expandedContent: .todoCard(output: "{\"id\":\"TODO-1\",\"title\":\"Test\",\"status\":\"open\"}"),
            isExpanded: true
        )

        view.configuration = todoConfig
        _ = fittedSize(for: view, width: 360)

        #expect(
            markdownStack.arrangedSubviews.isEmpty,
            "Stale markdown content must be cleared when switching to hosted view mode"
        )
    }

    @Test func expandedDiffInitialSizingBeforeLayoutPassStaysCompact() {
        let config = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let oldValue = false"),
                DiffLine(kind: .added, text: "let oldValue = true"),
            ], path: "Timeline/ChatTimelineCollectionView.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let firstPassSize = fittedSizeWithoutPrelayout(for: view, width: 300)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(firstPassSize.height < 300, "Initial diff sizing should stay compact; got \(firstPassSize.height)")
    }

    @Test func expandedCodeInitialSizingBeforeLayoutPassStaysCompact() {
        let config = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: "let title = \"tool expansion\"",
                language: .swift,
                startLine: 824,
                filePath: "Timeline/ChatTimelineCollectionView.swift"
            ),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let firstPassSize = fittedSizeWithoutPrelayout(for: view, width: 300)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(firstPassSize.height < 300, "Initial code sizing should stay compact; got \(firstPassSize.height)")
    }

    // MARK: - Cell Reuse: remember / recall constraint bugs

    @Test func cellReuseFromCodeToRememberMarkdownResetsLabelWidthPriority() throws {
        // Bug: cell previously in code mode has expandedLabelWidthConstraint at
        // .required priority. Reusing for remember (markdown) hides the label
        // but leaves the constraint at .required, forcing contentLayoutGuide
        // wider than intended and causing scroll/layout problems.
        let longCodeLine = String(repeating: "0123456789abcdef", count: 32)
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: longCodeLine,
                language: .swift,
                startLine: 1,
                filePath: "LongFile.swift"
            ),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))
        #expect(widthConstraint.priority == .required, "Code mode should set required width")
        #expect(widthConstraint.constant > 1, "Code mode should have positive width delta")

        // Now reuse the cell for remember (markdown content)
        let rememberConfig = makeToolConfiguration(
            toolNamePrefix: "remember",
            expandedContent: .markdown(text: "# Discovery\n\nSome important text"),
            isExpanded: true
        )
        view.configuration = rememberConfig
        _ = fittedSize(for: view, width: 360)

        // After reuse, the label is hidden in markdown mode. Its width
        // constraint must drop below .required to prevent it from
        // dominating contentLayoutGuide width.
        #expect(
            widthConstraint.priority < .required,
            "After reuse to markdown, label width priority should be below required; got \(widthConstraint.priority.rawValue)"
        )
    }

    @Test func cellReuseFromDiffToRecallTextResetsLabelWidthPriority() throws {
        // Similar to above but diff → recall (text mode)
        let longDiffLine = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 20)
        let diffConfig = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: longDiffLine),
                DiffLine(kind: .added, text: longDiffLine + "-updated"),
            ], path: "File.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: diffConfig)
        _ = fittedSize(for: view, width: 360)

        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))
        #expect(widthConstraint.priority == .required, "Diff mode should set required width")

        // Reuse for recall (text mode)
        let recallConfig = makeToolConfiguration(
            toolNamePrefix: "recall",
            expandedContent: .text(text: "5 matches found\n\nResult 1: architecture doc", language: nil),
            isExpanded: true
        )
        view.configuration = recallConfig
        _ = fittedSize(for: view, width: 360)

        // Text mode uses .defaultHigh priority for wrapped layout
        #expect(
            widthConstraint.priority < .required,
            "After reuse to text, label width priority should be below required; got \(widthConstraint.priority.rawValue)"
        )
    }

    @Test func cellReuseFromCodeToRememberMarkdownExpandedContainerIsVisible() throws {
        // Ensure the expanded container is actually visible after reuse
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "A.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        let expandedContainer = try #require(privateView(named: "expandedContainer", in: view))
        #expect(!expandedContainer.isHidden)

        // Reuse for remember (markdown)
        let rememberConfig = makeToolConfiguration(
            toolNamePrefix: "remember",
            expandedContent: .markdown(text: "Important discovery"),
            isExpanded: true
        )
        view.configuration = rememberConfig
        _ = fittedSize(for: view, width: 360)

        #expect(!expandedContainer.isHidden, "Expanded container should remain visible for remember")

        let markdownView = try #require(privateView(named: "expandedMarkdownView", in: view))
        #expect(!markdownView.isHidden, "Markdown view should be visible for remember")

        let label = try #require(privateView(named: "expandedLabel", in: view))
        #expect(label.isHidden, "Label should be hidden in markdown mode")
    }

    @Test func cellReuseFromCodeToHostedTodoResetsLabelWidthPriority() throws {
        // Code → todo (hosted view) also needs label width reset
        let longCodeLine = String(repeating: "0123456789abcdef", count: 32)
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: longCodeLine, language: .swift, startLine: 1, filePath: "L.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))
        #expect(widthConstraint.priority == .required)

        // Reuse for todo (hosted view)
        let todoConfig = makeToolConfiguration(
            toolNamePrefix: "todo",
            expandedContent: .todoCard(output: "{\"id\":\"TODO-1\",\"title\":\"Test\"}"),
            isExpanded: true
        )
        view.configuration = todoConfig
        _ = fittedSize(for: view, width: 360)

        #expect(
            widthConstraint.priority < .required,
            "After reuse to hosted view, label width priority should be below required; got \(widthConstraint.priority.rawValue)"
        )
    }

    @Test func expandedMarkdownDoesNotEnableHorizontalScroll() throws {
        // When expanded in markdown mode, the scroll view should NOT allow
        // horizontal scrolling. A stale .required width constraint on the
        // hidden label can force content wider and enable horizontal scroll.
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: String(repeating: "x", count: 500),
                language: .swift, startLine: 1, filePath: "F.swift"
            ),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        let scrollView = try #require(privateScrollView(named: "expandedScrollView", in: view))
        #expect(scrollView.alwaysBounceHorizontal)

        // Reuse for remember markdown
        let mdConfig = makeToolConfiguration(
            toolNamePrefix: "remember",
            expandedContent: .markdown(text: "Short note"),
            isExpanded: true
        )
        view.configuration = mdConfig
        _ = fittedSize(for: view, width: 360)

        #expect(!scrollView.alwaysBounceHorizontal, "Markdown mode should not bounce horizontally")
        #expect(!scrollView.showsHorizontalScrollIndicator, "Markdown mode should not show horizontal indicator")
    }

    @Test func cellReuseMarkdownGestureInterceptionDisabledForTextSelection() throws {
        // remember expanded in markdown mode should disable gesture interception
        // so users can select text via standard UITextView interactions.
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "A.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        // Code mode should have gesture interception enabled
        #expect(view.expandedTapCopyGestureEnabledForTesting)

        // Reuse for remember (markdown — needs text selection)
        let mdConfig = makeToolConfiguration(
            toolNamePrefix: "remember",
            expandedContent: .markdown(text: "# Note\n\nSome text to select"),
            isExpanded: true
        )
        view.configuration = mdConfig
        _ = fittedSize(for: view, width: 360)

        #expect(
            !view.expandedTapCopyGestureEnabledForTesting,
            "Markdown mode should disable tap-copy gesture for text selection"
        )
    }

    @Test func expandedCodeApplySetsUnwrappedWidthImmediately() throws {
        let longCodeLine = String(repeating: "0123456789abcdef", count: 32)
        let config = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: longCodeLine,
                language: .swift,
                startLine: 824,
                filePath: "Timeline/ChatTimelineCollectionView.swift"
            ),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))

        #expect(widthConstraint.priority == .required)
        #expect(
            widthConstraint.constant > 1,
            "Expanded code should set a positive unwrapped width delta during apply; got \(widthConstraint.constant)"
        )
    }

    @Test func expandedDiffApplySetsUnwrappedWidthImmediately() throws {
        let longDiffLine = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 20)
        let config = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: longDiffLine),
                DiffLine(kind: .added, text: longDiffLine + "-updated"),
            ], path: "Timeline/ChatTimelineCollectionView.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))

        #expect(widthConstraint.priority == .required)
        #expect(
            widthConstraint.constant > 1,
            "Expanded diff should set a positive unwrapped width delta during apply; got \(widthConstraint.constant)"
        )
    }
}

private func makeToolConfiguration(
    title: String = "tool title",
    toolNamePrefix: String = "read",
    expandedContent: ToolPresentationBuilder.ToolExpandedContent? = nil,
    isExpanded: Bool = false
) -> ToolTimelineRowConfiguration {
    ToolTimelineRowConfiguration(
        title: title,
        preview: nil,
        expandedContent: expandedContent,
        copyCommandText: "echo hi",
        copyOutputText: "hi",
        languageBadge: nil,
        trailing: nil,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: toolNamePrefix,
        toolNameColor: .systemBlue,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: nil,
        collapsedImageMimeType: nil,
        isExpanded: isExpanded,
        isDone: true,
        isError: false,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )
}

@MainActor
private func privateView(named name: String, in view: ToolTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? UIView
}

@MainActor
private func privateScrollView(named name: String, in view: ToolTimelineRowContentView) -> UIScrollView? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? UIScrollView
}

@MainActor
private func privateConstraint(named name: String, in view: ToolTimelineRowContentView) -> NSLayoutConstraint? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? NSLayoutConstraint
}

@MainActor
private func privateHostedExpandedView(in view: ToolTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == "expandedReadMediaContentView" }?.value as? UIView
}

@MainActor
private func firstView<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
    if let match = root as? T {
        return match
    }

    for child in root.subviews {
        if let found = firstView(ofType: type, in: child) {
            return found
        }
    }

    return nil
}

@MainActor
private func allLabels(in root: UIView) -> [UILabel] {
    var result: [UILabel] = []

    if let label = root as? UILabel {
        result.append(label)
    }

    for child in root.subviews {
        result.append(contentsOf: allLabels(in: child))
    }

    return result
}

@MainActor
private func renderedText(of label: UILabel) -> String {
    label.attributedText?.string ?? label.text ?? ""
}

@MainActor
private func fittedSize(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 2_000))
    container.backgroundColor = .black

    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)

    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    container.setNeedsLayout()
    container.layoutIfNeeded()

    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}

/// Extract the internal stackView from AssistantMarkdownContentView via Mirror.
/// Non-empty arrangedSubviews means the markdown view has content that
/// contributes intrinsic size to the shared contentLayoutGuide.
@MainActor
private func markdownStackView(in markdownView: AssistantMarkdownContentView) -> UIStackView? {
    Mirror(reflecting: markdownView).children.first { $0.label == "stackView" }?.value as? UIStackView
}

@MainActor
private func fittedSizeWithoutPrelayout(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 2_000))
    container.backgroundColor = .black

    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)

    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}
