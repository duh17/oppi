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

            let expandedContainer = view.expandedContainer
            // bash containers are inside BashToolRowView; access directly
            let commandContainer: UIView = view.bashToolRowView.commandContainer
            let outputContainer: UIView = view.bashToolRowView.outputContainer

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
        #expect(markdownPolicy.enablesTapCopyGesture)
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

        let markdownScrollView = markdownView.expandedScrollView
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

        let codeScrollView = codeView.expandedScrollView
        #expect(codeScrollView.isScrollEnabled)

        let bashWrapped = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: "echo hi", output: "line", unwrapped: false),
            isExpanded: true
        ))
        _ = fittedSize(for: bashWrapped, width: 360)
        // outputScrollView is inside BashToolRowView; access directly
        let wrappedOutputScroll = bashWrapped.bashToolRowView.outputScrollView
        #expect(!wrappedOutputScroll.isScrollEnabled)

        let bashUnwrapped = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "$",
            expandedContent: .bash(command: "echo hi", output: String(repeating: "x", count: 400), unwrapped: true),
            isExpanded: true
        ))
        _ = fittedSize(for: bashUnwrapped, width: 360)
        let unwrappedOutputScroll = bashUnwrapped.bashToolRowView.outputScrollView
        #expect(unwrappedOutputScroll.isScrollEnabled)
    }

    @Test func expandedViewportDoubleTapActivationMatchesFullScreenSupport() throws {
        let markdownView = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .markdown(text: "# Header\n\nBody"),
            isExpanded: true
        ))
        _ = fittedSize(for: markdownView, width: 360)
        let markdownScrollView = markdownView.expandedScrollView
        let markdownDoubleTap = try #require(markdownScrollView.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first {
            $0.numberOfTapsRequired == 2
        })
        #expect(markdownDoubleTap.isEnabled)

        let textView = ToolTimelineRowContentView(configuration: makeToolConfiguration(
            toolNamePrefix: "recall",
            expandedContent: .text(text: "Saved to journal: 2026-03-07.md", language: nil),
            isExpanded: true
        ))
        _ = fittedSize(for: textView, width: 360)
        let textScrollView = textView.expandedScrollView
        let textDoubleTap = try #require(textScrollView.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first {
            $0.numberOfTapsRequired == 2
        })
        #expect(textDoubleTap.isEnabled)

        let plotView = ToolTimelineRowContentView(configuration: makeToolConfiguration(
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
        ))
        _ = fittedSize(for: plotView, width: 360)
        let plotScrollView = plotView.expandedScrollView
        let plotDoubleTap = try #require(plotScrollView.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first {
            $0.numberOfTapsRequired == 2
        })
        #expect(!plotDoubleTap.isEnabled)
    }

    @Test func expandedMarkdownDisablesInlineTextSelectionWhenFullScreenIsPreferred() throws {
        let markdownConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .markdown(text: "# Header\n\nBody with [link](https://example.com)"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: markdownConfig)
        _ = fittedSize(for: view, width: 360)

        let markdownView = view.expandedToolRowView.expandedMarkdownView
        let innerTextViews = timelineAllTextViews(in: markdownView)
        #expect(!innerTextViews.isEmpty, "Expected markdown text views")

        for textView in innerTextViews {
            #expect(!textView.isSelectable)
        }
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

        let expanded = codeView.expandedScrollView
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

        // outputScrollView is inside BashToolRowView; access directly
        let output = bashView.bashToolRowView.outputScrollView
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

        let expandedLabel = view.expandedLabel
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

        let expandedLabel = view.expandedLabel
        let rendered = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        #expect(rendered.contains("EXT-1"))

        let expandedScrollView = view.expandedScrollView
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

        // outputScrollView is inside BashToolRowView; access directly
        let outputScrollView = view.bashToolRowView.outputScrollView
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
        let markdownView = view.expandedToolRowView.expandedMarkdownView
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

        // The diff text view must have attributed text.
        let expandedLabel = view.expandedLabel
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

        let markdownView = view.expandedToolRowView.expandedMarkdownView
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

        let expandedLabel = view.expandedLabel
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

        let markdownView = view.expandedToolRowView.expandedMarkdownView
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

    @Test func deferredCodeHighlightAppliesEvenIfContainerIsStillHidden() async throws {
        ToolRowRenderCache.evictAll()

        let text = (1...24)
            .map { index in
                "let line\(index) = \"" + String(repeating: "abcdefghij", count: 18) + "\""
            }
            .joined(separator: "\n")
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: text,
            language: .swift,
            startLine: 1,
            isStreaming: false
        )

        // Use ExpandedToolRowView directly to test deferred highlight.
        // Apply code to set up internal state (signature, mode, rendered text).
        let expandedView = ExpandedToolRowView()
        _ = expandedView.apply(
            input: ExpandedRenderInput(
                mode: .code(text: text, language: .swift, startLine: 1),
                isStreaming: false,
                outputColor: .white
            ),
            wasExpandedVisible: false
        )

        // Verify a deferred highlight was scheduled
        #expect(expandedView.expandedCodeDeferredHighlightSignature == signature)

        let deadline = Date().addingTimeInterval(1.5)
        while ToolRowRenderCache.get(signature: signature) == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        drainMainQueue()

        let attributed = try #require(expandedView.expandedLabel.attributedText)
        #expect(attributed.string.contains("│"))
        #expect(ToolRowRenderCache.get(signature: signature) != nil)
    }

    @Test func deferredCodeHighlightReappliesAfterTransientModeMismatch() async throws {
        ToolRowRenderCache.evictAll()
        ExpandedToolRowView.deferredCodeHighlightDelayForTesting = .milliseconds(120)
        defer { ExpandedToolRowView.deferredCodeHighlightDelayForTesting = nil }

        let text = (1...24)
            .map { index in
                "let line\(index) = \"" + String(repeating: "abcdefghij", count: 18) + "\""
            }
            .joined(separator: "\n")
        let signature = ToolTimelineRowRenderMetrics.codeSignature(
            displayText: text,
            language: .swift,
            startLine: 1,
            isStreaming: false
        )
        let configuration = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: text, language: .swift, startLine: 1, filePath: "Large.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: configuration)
        _ = fittedSize(for: view, width: 360)

        let expandedLabel = view.expandedToolRowView.expandedLabel
        let initialRendered = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        #expect(initialRendered == text)
        #expect(!initialRendered.contains("│"))

        // Simulate a transient mode mismatch while deferred highlighting is in
        // flight by switching to a different mode (text), which changes
        // expandedViewportMode away from .code.
        let textConfig = makeToolConfiguration(
            toolNamePrefix: "remember",
            expandedContent: .text(text: "transient", language: nil),
            isExpanded: true
        )
        view.configuration = textConfig
        _ = fittedSize(for: view, width: 360)

        let deadline = Date().addingTimeInterval(2.0)
        while ToolRowRenderCache.get(signature: signature) == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        while view.expandedCodeDeferredHighlightTask != nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        drainMainQueue()

        #expect(ToolRowRenderCache.get(signature: signature) != nil)

        // Reapplying the original configuration should consume the warmed cache
        // instead of getting stuck forever on the plain-text first paint.
        view.configuration = configuration
        _ = fittedSize(for: view, width: 360)
        drainMainQueue()

        let rendered = expandedLabel.attributedText?.string ?? expandedLabel.text ?? ""
        #expect(rendered.contains("│"))
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

        let widthConstraint = view.expandedToolRowView.expandedLabelWidthConstraint!
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

        let widthConstraint = view.expandedToolRowView.expandedLabelWidthConstraint!
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

        let widthConstraint = view.expandedToolRowView.expandedLabelWidthConstraint!
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

        let expandedContainer = view.expandedContainer
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

        let markdownView = view.expandedToolRowView.expandedMarkdownView
        #expect(!markdownView.isHidden, "Markdown view should be visible for extension markdown")

        let label = view.expandedLabel
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

        let widthConstraint = view.expandedToolRowView.expandedLabelWidthConstraint!
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

        let scrollView = view.expandedScrollView
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

        let scrollView = view.expandedScrollView
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

        let markdownView = view.expandedToolRowView.expandedMarkdownView
        let innerScrollViews = timelineAllScrollViews(in: markdownView)
        #expect(!innerScrollViews.isEmpty, "Expected markdown text/cell scroll views")

        for inner in innerScrollViews {
            #expect(!inner.alwaysBounceVertical)
            #expect(!inner.bounces)
        }
    }

    @Test func cellReuseMarkdownKeepsGestureInterceptionForFullScreenActivation() throws {
        // Inline expanded markdown should keep double-tap full-screen activation.
        let codeConfig = makeToolConfiguration(
            toolNamePrefix: "read",
            expandedContent: .code(text: "let x = 1", language: .swift, startLine: 1, filePath: "A.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: codeConfig)
        _ = fittedSize(for: view, width: 360)

        #expect(view.expandedTapCopyGestureEnabledForTesting)

        let mdConfig = makeToolConfiguration(
            toolNamePrefix: "extensions.notes",
            expandedContent: .markdown(text: "# Note\n\nSome text to select"),
            isExpanded: true
        )
        view.configuration = mdConfig
        _ = fittedSize(for: view, width: 360)

        #expect(
            view.expandedTapCopyGestureEnabledForTesting,
            "Markdown mode should keep tap interception for full-screen activation"
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

        let expandedScrollView = view.expandedScrollView
        let visualOffset = expandedScrollView.contentOffset.y + expandedScrollView.adjustedContentInset.top
        #expect(visualOffset < 1.0, "Done text tools should open at top; got visual offset \(visualOffset)")

        let shouldAutoFollow = view.expandedShouldAutoFollow
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

        let shouldAutoFollow = view.expandedShouldAutoFollow
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

        let expandedScrollView = view.expandedScrollView
        ToolTimelineRowUIHelpers.scrollToBottom(expandedScrollView, animated: false)
        drainMainQueue(passes: 2)

        view.configuration = doneConfig
        _ = fittedSize(for: view, width: 360)
        drainMainQueue(passes: 6)

        let visualOffset = expandedScrollView.contentOffset.y + expandedScrollView.adjustedContentInset.top
        #expect(visualOffset < 1.0, "Done text reuse should reset to top; got visual offset \(visualOffset)")

        let shouldAutoFollow = view.expandedShouldAutoFollow
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
        let widthConstraint = view.expandedToolRowView.expandedLabelWidthConstraint!

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
        let widthConstraint = view.expandedToolRowView.expandedLabelWidthConstraint!

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

        let viewportConstraint = view.expandedToolRowView.expandedViewportHeightConstraint!
        #expect(viewportConstraint.isActive)
        #expect(
            viewportConstraint.constant < 120,
            "Remember expanded viewport should be compact after reuse; got \(viewportConstraint.constant)"
        )

        #expect(
            privateView(named: "expandFloatingButton", in: view) == nil,
            "Remember expanded row should not install a floating full-screen button"
        )

        let firstPassSize = fittedSizeWithoutPrelayout(for: view, width: 360)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(
            firstPassSize.height < 260,
            "Remember first-pass expanded sizing should stay compact after reuse; got \(firstPassSize.height)"
        )
    }

    // MARK: - Streaming guard: code mode

    // During streaming, code mode should use plain text (no syntax
    // highlighting or line numbers) to avoid main-thread hangs.
    @Test func expandedCodeStreamingUsesPlainText() throws {
        let code = "struct App {\n    var name: String\n}"
        let config = makeToolConfiguration(
            toolNamePrefix: "write",
            expandedContent: .code(text: code, language: .swift, startLine: 1, filePath: "App.swift"),
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 360)

        let label = view.expandedLabel
        let rendered = label.attributedText?.string ?? label.text ?? ""
        #expect(rendered.contains("struct App"))
        // No line number gutter during streaming (cheap path)
        #expect(!rendered.contains("│"), "Streaming code should not have line number separators")
    }

    // After completion, code mode should render full syntax-highlighted
    // attributed text with line numbers.
    @Test func expandedCodeDoneUsesFullRender() throws {
        let code = "struct App {\n    var name: String\n}"
        let config = makeToolConfiguration(
            toolNamePrefix: "write",
            expandedContent: .code(text: code, language: .swift, startLine: 1, filePath: "App.swift"),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 360)

        let label = view.expandedLabel
        let rendered = label.attributedText?.string ?? label.text ?? ""
        #expect(rendered.contains("struct App"))
        // Line number gutter present when done (full quality path)
        #expect(rendered.contains("│"), "Done code should have line number separators")
    }

    // Streaming -> done transition must re-render (signature includes
    // isStreaming, so the change triggers a full quality render).
    @Test func expandedCodeStreamingToDoneTransitionReRenders() throws {
        let code = "let x = 42\nlet y = 99"
        let streaming = makeToolConfiguration(
            toolNamePrefix: "write",
            expandedContent: .code(text: code, language: .swift, startLine: 1, filePath: "F.swift"),
            isExpanded: true,
            isDone: false
        )
        let done = makeToolConfiguration(
            toolNamePrefix: "write",
            expandedContent: .code(text: code, language: .swift, startLine: 1, filePath: "F.swift"),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: streaming)
        _ = fittedSize(for: view, width: 360)

        let label = view.expandedLabel
        let streamingRendered = label.attributedText?.string ?? label.text ?? ""
        #expect(!streamingRendered.contains("│"), "Streaming should not have line numbers")

        // Transition to done with identical content
        view.configuration = done
        _ = fittedSize(for: view, width: 360)

        let doneRendered = label.attributedText?.string ?? label.text ?? ""
        #expect(doneRendered.contains("let x = 42"))
        #expect(doneRendered.contains("│"), "Done should add line number gutter")
    }

    // MARK: - Streaming guard: diff mode

    // During streaming, diff mode should use plain text markers (no syntax
    // highlighting, no colored backgrounds, no line numbers).
    @Test func expandedDiffStreamingUsesPlainText() throws {
        let config = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let old = false"),
                DiffLine(kind: .added, text: "let old = true"),
            ], path: "Model.swift"),
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 360)

        let label = view.expandedLabel
        let rendered = label.attributedText?.string ?? label.text ?? ""
        #expect(rendered.contains("- let old = false"), "Streaming diff should show - prefix")
        #expect(rendered.contains("+ let old = true"), "Streaming diff should show + prefix")
        // No rich gutter prefix during streaming (cheap path)
        #expect(!rendered.contains("▎"), "Streaming diff should not have rich gutter markers")
    }

    // After completion, diff mode should render full attributed diff with
    // colored backgrounds and syntax highlighting.
    @Test func expandedDiffDoneUsesFullRender() throws {
        let config = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let old = false"),
                DiffLine(kind: .added, text: "let old = true"),
            ], path: "Model.swift"),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 360)

        let label = view.expandedLabel
        let rendered = label.attributedText?.string ?? label.text ?? ""
        #expect(rendered.contains("let old = false"))
        #expect(rendered.contains("let old = true"))
        // Full rich gutter when done
        #expect(rendered.contains("▎"), "Done diff should have rich gutter markers")
    }

    // Streaming -> done transition for diff mode.
    @Test func expandedDiffStreamingToDoneTransitionReRenders() throws {
        let lines = [
            DiffLine(kind: .context, text: "import Foundation"),
            DiffLine(kind: .removed, text: "let a = 1"),
            DiffLine(kind: .added, text: "let a = 2"),
        ]
        let streaming = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: lines, path: "A.swift"),
            isExpanded: true,
            isDone: false
        )
        let done = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: lines, path: "A.swift"),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: streaming)
        _ = fittedSize(for: view, width: 360)

        let label = view.expandedLabel
        let streamingRendered = label.attributedText?.string ?? label.text ?? ""
        #expect(!streamingRendered.contains("▎"), "Streaming diff should not have gutter markers")

        view.configuration = done
        _ = fittedSize(for: view, width: 360)

        let doneRendered = label.attributedText?.string ?? label.text ?? ""
        #expect(doneRendered.contains("let a = 2"))
        #expect(doneRendered.contains("▎"), "Done diff should add gutter markers")
    }

    // MARK: - Streaming guard: auto-follow behavior

    // Code mode should auto-follow during streaming and stop on done.
    @Test func expandedCodeStreamingEnablesAutoFollow() throws {
        let code = (1...200).map { "let line\($0) = \($0)" }.joined(separator: "\n")

        let streaming = makeToolConfiguration(
            toolNamePrefix: "write",
            expandedContent: .code(text: code, language: .swift, startLine: 1, filePath: "Big.swift"),
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: streaming)
        _ = fittedSize(for: view, width: 360)

        let autoFollow = view.expandedShouldAutoFollow
        #expect(autoFollow, "Streaming code should enable auto-follow")
    }

    @Test func expandedCodeDoneDisablesAutoFollow() throws {
        let code = (1...200).map { "let line\($0) = \($0)" }.joined(separator: "\n")

        let done = makeToolConfiguration(
            toolNamePrefix: "write",
            expandedContent: .code(text: code, language: .swift, startLine: 1, filePath: "Big.swift"),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: done)
        _ = fittedSize(for: view, width: 360)

        let autoFollow = view.expandedShouldAutoFollow
        #expect(!autoFollow, "Done code should disable auto-follow")
    }

    // Diff mode should auto-follow during streaming and stop on done.
    @Test func expandedDiffStreamingEnablesAutoFollow() throws {
        let lines = (1...200).map { DiffLine(kind: .added, text: "line \($0)") }

        let streaming = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: lines, path: "Big.swift"),
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: streaming)
        _ = fittedSize(for: view, width: 360)

        let autoFollow = view.expandedShouldAutoFollow
        #expect(autoFollow, "Streaming diff should enable auto-follow")
    }

    @Test func expandedDiffDoneDisablesAutoFollow() throws {
        let lines = (1...200).map { DiffLine(kind: .added, text: "line \($0)") }

        let done = makeToolConfiguration(
            toolNamePrefix: "edit",
            expandedContent: .diff(lines: lines, path: "Big.swift"),
            isExpanded: true,
            isDone: true
        )

        let view = ToolTimelineRowContentView(configuration: done)
        _ = fittedSize(for: view, width: 360)

        let autoFollow = view.expandedShouldAutoFollow
        #expect(!autoFollow, "Done diff should disable auto-follow")
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
