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
                name: "extensionText",
                toolNamePrefix: "extensions.notes",
                content: .text(text: "{\"id\":\"EXT-1\",\"title\":\"Test\"}", language: nil),
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
                toolNamePrefix: "extensions.notes",
                content: .text(text: "extension notes", language: nil),
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

    @Test func interactionPolicyMatrixMatchesModeExpectations() {
        let markdownPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .markdown(text: "# Header")
        )
        #expect(!markdownPolicy.enablesTapCopyGesture)
        #expect(markdownPolicy.enablesPinchGesture)
        #expect(!markdownPolicy.allowsHorizontalScroll)
        #expect(markdownPolicy.supportsFullScreenPreview)

        let codePolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "Test.swift")
        )
        #expect(codePolicy.enablesTapCopyGesture)
        #expect(codePolicy.enablesPinchGesture)
        #expect(codePolicy.allowsHorizontalScroll)
        #expect(codePolicy.supportsFullScreenPreview)

        let wrappedBashPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .bash(command: "echo hi", output: "hi", unwrapped: false)
        )
        #expect(!wrappedBashPolicy.allowsHorizontalScroll)

        let unwrappedBashPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .bash(command: "echo hi", output: "hi", unwrapped: true)
        )
        #expect(unwrappedBashPolicy.allowsHorizontalScroll)

        let extensionTextPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .text(text: "Extension result", language: nil)
        )
        #expect(extensionTextPolicy.enablesTapCopyGesture)
        #expect(extensionTextPolicy.enablesPinchGesture)
        #expect(!extensionTextPolicy.allowsHorizontalScroll)
        #expect(extensionTextPolicy.supportsFullScreenPreview)

        let extensionJSONPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .text(text: "{\"id\":\"EXT-1\"}", language: .json)
        )
        #expect(extensionJSONPolicy.enablesTapCopyGesture)
        #expect(extensionJSONPolicy.enablesPinchGesture)
        #expect(!extensionJSONPolicy.allowsHorizontalScroll)
        #expect(extensionJSONPolicy.supportsFullScreenPreview)

        let hostedPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .readMedia(output: "data:image/png;base64,abc", filePath: "a.png", startLine: 1)
        )
        #expect(!hostedPolicy.enablesTapCopyGesture)
        #expect(!hostedPolicy.enablesPinchGesture)
        #expect(!hostedPolicy.allowsHorizontalScroll)
        #expect(!hostedPolicy.supportsFullScreenPreview)
    }

    @Test func expandedModeRouterAndInteractionPolicyStayInLockstep() {
        struct PolicyCase {
            let content: ToolPresentationBuilder.ToolExpandedContent
            let expectedMode: RoutedExpandedMode
            let expectsFullScreen: Bool
            let expectsHorizontalScroll: Bool
        }

        let cases: [PolicyCase] = [
            .init(content: .bash(command: "echo hi", output: "hi", unwrapped: false), expectedMode: .bash, expectsFullScreen: true, expectsHorizontalScroll: false),
            .init(content: .bash(command: "echo hi", output: "hi", unwrapped: true), expectedMode: .bash, expectsFullScreen: true, expectsHorizontalScroll: true),
            .init(content: .diff(lines: [DiffLine(kind: .added, text: "x")], path: "a.swift"), expectedMode: .diff, expectsFullScreen: true, expectsHorizontalScroll: true),
            .init(content: .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "A.swift"), expectedMode: .code, expectsFullScreen: true, expectsHorizontalScroll: true),
            .init(content: .markdown(text: "# H"), expectedMode: .markdown, expectsFullScreen: true, expectsHorizontalScroll: false),
            .init(
                content: .plot(
                    spec: PlotChartSpec(
                        title: nil,
                        rows: [.init(id: 0, values: ["x": .number(0), "y": .number(1)])],
                        marks: [.init(id: "m0", type: .line, x: "x", y: "y")],
                        xAxis: .init(label: "x", invert: false),
                        yAxis: .init(label: "y", invert: false),
                        interaction: .init(xSelection: false, xRangeSelection: false, scrollableX: false),
                        preferredHeight: 180
                    ),
                    fallbackText: nil
                ),
                expectedMode: .plot,
                expectsFullScreen: false,
                expectsHorizontalScroll: false
            ),
            .init(content: .readMedia(output: "data:image/png;base64,abc", filePath: "a.png", startLine: 1), expectedMode: .readMedia, expectsFullScreen: false, expectsHorizontalScroll: false),
            .init(content: .text(text: "extension output", language: nil), expectedMode: .text, expectsFullScreen: true, expectsHorizontalScroll: false),
        ]

        for testCase in cases {
            let routed = route(testCase.content)
            #expect(routed == testCase.expectedMode)

            let policy = ToolTimelineRowInteractionPolicy.forExpandedContent(testCase.content)
            #expect(policy.supportsFullScreenPreview == testCase.expectsFullScreen)
            #expect(policy.allowsHorizontalScroll == testCase.expectsHorizontalScroll)
        }
    }

    @Test func scrollAxisOwnershipUsesHorizontalOnlyInnerScrolls() throws {
        let markdownView = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
            expandedContent: .markdown(text: "# Header\n\nBody"),
            isExpanded: true
        ))
        _ = fittedSize(for: markdownView, width: 360)

        let markdownScrollView = try #require(privateScrollView(named: "expandedScrollView", in: markdownView))
        #expect(!markdownScrollView.isScrollEnabled)

        let codeView = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: "let value = 1\n" + String(repeating: "0123456789abcdef", count: 16),
                language: .swift,
                startLine: 1,
                filePath: "Sample.swift"
            ),
            isExpanded: true
        ))
        _ = fittedSize(for: codeView, width: 360)

        let codeScrollView = try #require(privateScrollView(named: "expandedScrollView", in: codeView))
        #expect(codeScrollView.isScrollEnabled)

        let bashWrapped = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: "echo hi", output: "line", unwrapped: false),
            isExpanded: true
        ))
        _ = fittedSize(for: bashWrapped, width: 360)
        let wrappedOutputScroll = try #require(privateScrollView(named: "outputScrollView", in: bashWrapped))
        #expect(!wrappedOutputScroll.isScrollEnabled)

        let bashUnwrapped = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: "echo hi", output: String(repeating: "x", count: 400), unwrapped: true),
            isExpanded: true
        ))
        _ = fittedSize(for: bashUnwrapped, width: 360)
        let unwrappedOutputScroll = try #require(privateScrollView(named: "outputScrollView", in: bashUnwrapped))
        #expect(unwrappedOutputScroll.isScrollEnabled)
    }

    @Test func horizontalPanPassthroughRejectsVerticalIntent() {
        #expect(HorizontalPanPassthroughScrollView.shouldBeginHorizontalPan(with: CGPoint(x: 180, y: 20)))
        #expect(HorizontalPanPassthroughScrollView.shouldBeginHorizontalPan(with: CGPoint(x: 70, y: 55)))
        #expect(!HorizontalPanPassthroughScrollView.shouldBeginHorizontalPan(with: CGPoint(x: 20, y: 180)))
        #expect(!HorizontalPanPassthroughScrollView.shouldBeginHorizontalPan(with: CGPoint(x: 45, y: 44)))
    }

    @Test func expandedBuiltInHorizontalViewportsUsePanPassthroughScrollViews() throws {
        let codeView = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: String(repeating: "0123456789abcdef", count: 20),
                language: .swift,
                startLine: 1,
                filePath: "Sample.swift"
            ),
            isExpanded: true
        ))
        _ = fittedSize(for: codeView, width: 360)

        let expanded = try #require(privateScrollView(named: "expandedScrollView", in: codeView))
        #expect(expanded is HorizontalPanPassthroughScrollView)

        let bashView = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(
                command: "echo hi",
                output: String(repeating: "line-with-very-long-token ", count: 80),
                unwrapped: true
            ),
            isExpanded: true
        ))
        _ = fittedSize(for: bashView, width: 360)

        let output = try #require(privateScrollView(named: "outputScrollView", in: bashView))
        #expect(output is HorizontalPanPassthroughScrollView)
    }

    @Test func expandedExtensionTextUsesWrappedLabelRendering() throws {
        let output = """
        extension result line 1
        extension result line 2
        extension result line 3
        """

        let view = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
            expandedContent: .text(text: output, language: nil),
            isExpanded: true
        ))

        _ = fittedSize(for: view, width: 360)

        let expandedLabel = try #require(privateView(named: "expandedLabel", in: view) as? UILabel)
        let rendered = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        #expect(rendered.contains("extension result line 1"))
        #expect(rendered.contains("extension result line 3"))
    }

    @Test func expandedExtensionJSONUsesWrappedLabelRendering() throws {
        let output = "{\"assigned\":[{\"id\":\"EXT-1\",\"title\":\"Test\"}]}"

        let view = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: .text(text: output, language: .json),
            isExpanded: true
        ))

        _ = fittedSize(for: view, width: 360)

        let expandedLabel = try #require(privateView(named: "expandedLabel", in: view) as? UILabel)
        let rendered = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        #expect(rendered.contains("EXT-1"))

        let expandedScrollView = try #require(privateScrollView(named: "expandedScrollView", in: view))
        #expect(!expandedScrollView.alwaysBounceHorizontal)
        #expect(!expandedScrollView.showsHorizontalScrollIndicator)
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
            !markdownStack.arrangedSubviews.isEmpty,
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
        #expect(!markdownStack.arrangedSubviews.isEmpty)

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

    // Verify the hosted view path also clears stale markdown
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
        #expect(!markdownStack.arrangedSubviews.isEmpty)

        let plotConfig = makeToolConfiguration(
            toolNamePrefix: "plot",
            expandedContent: .plot(
                spec: PlotChartSpec(
                    title: nil,
                    rows: [.init(id: 0, values: ["x": .number(0), "y": .number(1)])],
                    marks: [.init(id: "m0", type: .line, x: "x", y: "y")],
                    xAxis: .init(label: "x", invert: false),
                    yAxis: .init(label: "y", invert: false),
                    interaction: .init(xSelection: false, xRangeSelection: false, scrollableX: false),
                    preferredHeight: 180
                ),
                fallbackText: nil
            ),
            isExpanded: true
        )

        view.configuration = plotConfig
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

    // MARK: - Cell Reuse: extension markdown/text constraint bugs

    @Test func cellReuseFromCodeToExtensionMarkdownResetsLabelWidthPriority() throws {
        // Bug: cell previously in code mode has expandedLabelWidthConstraint at
        // .required priority. Reusing for extension markdown hides the label
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

        // Now reuse the cell for extension markdown content.
        let extensionMarkdownConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
            expandedContent: .markdown(text: "# Discovery\n\nSome important text"),
            isExpanded: true
        )
        view.configuration = extensionMarkdownConfig
        _ = fittedSize(for: view, width: 360)

        // After reuse, the label is hidden in markdown mode. Its width
        // constraint must drop below .required to prevent it from
        // dominating contentLayoutGuide width.
        #expect(
            widthConstraint.priority < .required,
            "After reuse to markdown, label width priority should be below required; got \(widthConstraint.priority.rawValue)"
        )
    }

    @Test func cellReuseFromDiffToExtensionTextResetsLabelWidthPriority() throws {
        // Similar to above but diff → extension text mode.
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

        // Reuse for extension text mode.
        let extensionTextConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: .text(text: "5 matches found\n\nResult 1: architecture doc", language: nil),
            isExpanded: true
        )
        view.configuration = extensionTextConfig
        _ = fittedSize(for: view, width: 360)

        // Text mode uses .defaultHigh priority for wrapped layout.
        #expect(
            widthConstraint.priority < .required,
            "After reuse to text, label width priority should be below required; got \(widthConstraint.priority.rawValue)"
        )
    }

    @Test func cellReuseFromCodeToExtensionJSONResetsLabelWidthPriority() throws {
        let longCodeLine = String(repeating: "0123456789abcdef", count: 32)
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: longCodeLine, language: .swift, startLine: 1, filePath: "Long.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        let widthConstraint = try #require(privateConstraint(named: "expandedLabelWidthConstraint", in: view))
        #expect(widthConstraint.priority == .required)

        let extensionJSONConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: .text(text: "{\"assigned\":[{\"id\":\"EXT-1\"}]}", language: .json),
            isExpanded: true
        )
        view.configuration = extensionJSONConfig
        _ = fittedSize(for: view, width: 360)

        #expect(
            widthConstraint.priority < .required,
            "After reuse to json text, label width priority should be below required; got \(widthConstraint.priority.rawValue)"
        )
    }

    @Test func cellReuseFromCodeToExtensionMarkdownExpandedContainerIsVisible() throws {
        // Ensure the expanded container is actually visible after reuse.
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "A.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        let expandedContainer = try #require(privateView(named: "expandedContainer", in: view))
        #expect(!expandedContainer.isHidden)

        // Reuse for extension markdown.
        let extensionMarkdownConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
            expandedContent: .markdown(text: "Important discovery"),
            isExpanded: true
        )
        view.configuration = extensionMarkdownConfig
        _ = fittedSize(for: view, width: 360)

        #expect(!expandedContainer.isHidden, "Expanded container should remain visible for extension markdown")

        let markdownView = try #require(privateView(named: "expandedMarkdownView", in: view))
        #expect(!markdownView.isHidden, "Markdown view should be visible for extension markdown")

        let label = try #require(privateView(named: "expandedLabel", in: view))
        #expect(label.isHidden, "Label should be hidden in markdown mode")
    }

    @Test func cellReuseFromCodeToHostedPlotResetsLabelWidthPriority() throws {
        // Code → plot (hosted view) also needs label width reset
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

        // Reuse for plot (hosted view)
        let plotConfig = makeToolConfiguration(
            toolNamePrefix: "plot",
            expandedContent: .plot(
                spec: PlotChartSpec(
                    title: nil,
                    rows: [.init(id: 0, values: ["x": .number(0), "y": .number(1)])],
                    marks: [.init(id: "m0", type: .line, x: "x", y: "y")],
                    xAxis: .init(label: "x", invert: false),
                    yAxis: .init(label: "y", invert: false),
                    interaction: .init(xSelection: false, xRangeSelection: false, scrollableX: false),
                    preferredHeight: 180
                ),
                fallbackText: nil
            ),
            isExpanded: true
        )
        view.configuration = plotConfig
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

        // Reuse for extension markdown.
        let mdConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
            expandedContent: .markdown(text: "Short note"),
            isExpanded: true
        )
        view.configuration = mdConfig
        _ = fittedSize(for: view, width: 360)

        #expect(!scrollView.alwaysBounceHorizontal, "Markdown mode should not bounce horizontally")
        #expect(!scrollView.showsHorizontalScrollIndicator, "Markdown mode should not show horizontal indicator")
    }

    @Test func expandedMarkdownDisablesVerticalBounceToAvoidOuterScrollLock() throws {
        let mdConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .markdown(text: String(repeating: "line\n", count: 600)),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: mdConfig)
        _ = fittedSize(for: view, width: 360)

        let scrollView = try #require(privateScrollView(named: "expandedScrollView", in: view))
        #expect(!scrollView.alwaysBounceVertical)
        #expect(!scrollView.bounces, "Markdown expanded scroll should not rubber-band vertically")
    }

    @Test func expandedExtensionMarkdownInnerTextViewsDisableBounce() throws {
        let extensionMarkdownConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
            expandedContent: .markdown(text: String(repeating: "extension line\n", count: 180)),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: extensionMarkdownConfig)
        _ = fittedSize(for: view, width: 360)

        let markdownView = try #require(privateView(named: "expandedMarkdownView", in: view))
        let innerScrollViews = timelineAllScrollViews(in: markdownView)
        #expect(!innerScrollViews.isEmpty, "Expected markdown text/cell scroll views")

        for inner in innerScrollViews {
            #expect(!inner.alwaysBounceVertical)
            #expect(!inner.bounces)
        }
    }

    @Test func cellReuseMarkdownGestureInterceptionDisabledForTextSelection() throws {
        // Extension markdown mode should disable gesture interception so users
        // can select text via standard UITextView interactions.
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "A.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        // Code mode should have gesture interception enabled.
        #expect(view.expandedTapCopyGestureEnabledForTesting)

        // Reuse for extension markdown (needs text selection).
        let mdConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
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

    @Test func expandedDoneTextDoesNotAutoFollowToBottomOnFirstRender() throws {
        let longText = (1...600)
            .map { "[\($0)] extension result line with enough text to overflow viewport" }
            .joined(separator: "\n")

        let collapsed = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: nil,
            isExpanded: false,
            isDone: true
        )
        let expanded = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: .text(text: longText, language: nil),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: collapsed)
        _ = fittedSize(for: view, width: 360)

        view.configuration = expanded
        _ = fittedSize(for: view, width: 360)
        drainMainQueue()

        let expandedScrollView = try #require(privateScrollView(named: "expandedScrollView", in: view))
        let visualOffset = expandedScrollView.contentOffset.y + expandedScrollView.adjustedContentInset.top
        #expect(visualOffset < 1.0, "Done text tools should open at top; got visual offset \(visualOffset)")

        let shouldAutoFollow = try #require(privateBool(named: "expandedShouldAutoFollow", in: view) as Bool?)
        #expect(!shouldAutoFollow, "Done text tools should not auto-follow after first render")
    }

    @Test func expandedStreamingTextKeepsAutoFollowEnabledOnFirstRender() throws {
        let longText = (1...600)
            .map { "[\($0)] streaming line with enough text to overflow viewport" }
            .joined(separator: "\n")

        let collapsed = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: nil,
            isExpanded: false,
            isDone: false
        )
        let expanded = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: .text(text: longText, language: nil),
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: collapsed)
        _ = fittedSize(for: view, width: 360)

        view.configuration = expanded
        _ = fittedSize(for: view, width: 360)
        drainMainQueue()

        let shouldAutoFollow = try #require(privateBool(named: "expandedShouldAutoFollow", in: view) as Bool?)
        #expect(shouldAutoFollow, "Streaming text should keep auto-follow enabled")
    }

    @Test func cellReuseFromStreamingTextToDoneTextResetsExpandedOffsetToTop() throws {
        let streamingText = (1...700)
            .map { "[\($0)] streaming text segment with enough payload to overflow viewport" }
            .joined(separator: "\n")
        let doneText = (1...700)
            .map { "[\($0)] finalized text segment with enough payload to overflow viewport" }
            .joined(separator: "\n")

        let streamingConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: .text(text: streamingText, language: nil),
            isExpanded: true,
            isDone: false
        )
        let doneConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.lookup",
            expandedContent: .text(text: doneText, language: nil),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: streamingConfig)
        _ = fittedSize(for: view, width: 360)
        drainMainQueue(passes: 6)

        let expandedScrollView = try #require(privateScrollView(named: "expandedScrollView", in: view))
        ToolTimelineRowUIHelpers.scrollToBottom(expandedScrollView, animated: false)
        drainMainQueue(passes: 2)

        view.configuration = doneConfig
        _ = fittedSize(for: view, width: 360)
        drainMainQueue(passes: 6)

        let visualOffset = expandedScrollView.contentOffset.y + expandedScrollView.adjustedContentInset.top
        #expect(visualOffset < 1.0, "Done text reuse should reset to top; got visual offset \(visualOffset)")

        let shouldAutoFollow = try #require(privateBool(named: "expandedShouldAutoFollow", in: view) as Bool?)
        #expect(!shouldAutoFollow, "Done text reuse should disable auto-follow")
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

    @Test func cellReuseFromLargeCodeToRememberTextFirstExpandedPassStaysCompact() throws {
        let repeatedToken = String(repeating: "0123456789abcdef", count: 4)
        let largeCode = (0..<420)
            .map { "let line\($0) = \"\(repeatedToken)\"" }
            .joined(separator: "\n")

        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(
                text: largeCode,
                language: .swift,
                startLine: 1,
                filePath: "Large.swift"
            ),
            isExpanded: true,
            isDone: false
        )

        let collapsedRemember = makeToolConfiguration(
            toolNamePrefix: "remember",
            expandedContent: nil,
            isExpanded: false,
            isDone: true
        )

        let expandedRemember = makeToolConfiguration(
            toolNamePrefix: "remember",
            expandedContent: .text(text: "Saved to journal: 2026-02-28-mac-studio.md", language: nil),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        view.configuration = collapsedRemember
        _ = fittedSize(for: view, width: 360)

        view.configuration = expandedRemember

        let viewportConstraint = try #require(
            privateConstraint(named: "expandedViewportHeightConstraint", in: view)
        )
        #expect(viewportConstraint.isActive)
        #expect(
            viewportConstraint.constant < 120,
            "Remember expanded viewport should be compact after reuse; got \(viewportConstraint.constant)"
        )

        let expandButton = try #require(privateView(named: "expandFloatingButton", in: view) as? UIButton)
        #expect(
            expandButton.isHidden,
            "Remember expanded row should not show floating full-screen button for short text"
        )

        let firstPassSize = fittedSizeWithoutPrelayout(for: view, width: 360)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(
            firstPassSize.height < 260,
            "Remember first-pass expanded sizing should stay compact after reuse; got \(firstPassSize.height)"
        )
    }
}

private enum RoutedExpandedMode: Equatable {
    case bash
    case diff
    case code
    case markdown
    case plot
    case readMedia
    case text
}

@MainActor
private func route(_ content: ToolPresentationBuilder.ToolExpandedContent) -> RoutedExpandedMode {
    ToolTimelineRowExpandedModeRouter.route(
        expandedContent: content,
        renderBash: { _, _, _ in .bash },
        renderDiff: { _, _ in .diff },
        renderCode: { _, _, _ in .code },
        renderMarkdown: { _ in .markdown },
        renderPlot: { _, _ in .plot },
        renderReadMedia: { _, _, _ in .readMedia },
        renderText: { _, _ in .text }
    )
}

private func makeToolConfiguration(
    title: String = "tool title",
    toolNamePrefix: String = "read",
    expandedContent: ToolPresentationBuilder.ToolExpandedContent? = nil,
    isExpanded: Bool = false,
    isDone: Bool = true
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
        isDone: isDone,
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
private func privateBool(named name: String, in view: ToolTimelineRowContentView) -> Bool? {
    Mirror(reflecting: view).children.first { $0.label == name }?.value as? Bool
}

@MainActor
private func drainMainQueue(passes: Int = 3) {
    for _ in 0..<max(1, passes) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
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
