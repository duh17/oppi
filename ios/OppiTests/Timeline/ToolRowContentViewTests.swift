import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("ToolTimelineRowContentView")
struct ToolTimelineRowContentViewTests {

    @MainActor
    @Test func emptyCollapsedBodyProducesFiniteCompactHeight() {
        let config = makeTimelineToolConfiguration(isExpanded: false)
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func collapsedTitleStaysSingleLineForConsistency() throws {
        let config = makeTimelineToolConfiguration(
            title: "todo Refine compaction row preview behavior for consistency across timeline",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 320)

        let labels = timelineAllLabels(in: view)
        let titleLabel = try #require(labels.first {
            timelineRenderedText(of: $0).contains("todo Refine compaction row preview behavior")
        })

        #expect(titleLabel.numberOfLines == 1)
    }

    @MainActor
    @Test func trailingByteCountAlignsWithCollapsedTitleRow() throws {
        let config = makeTimelineToolConfiguration(
            title: "$ pwd",
            trailing: "29B",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let labels = timelineAllLabels(in: view)
        let titleLabel = try #require(labels.first { timelineRenderedText(of: $0) == "$ pwd" })
        let trailingLabel = try #require(labels.first { timelineRenderedText(of: $0) == "29B" })

        let titleRect = titleLabel.convert(titleLabel.bounds, to: view)
        let trailingRect = trailingLabel.convert(trailingLabel.bounds, to: view)

        #expect(abs(trailingRect.minY - titleRect.minY) <= 2)
        #expect(abs(trailingRect.midY - titleRect.midY) <= 3)
    }

    @MainActor
    @Test func dollarPrefixRendersToolIconCenteredWithTitleRow() throws {
        let config = makeTimelineToolConfiguration(
            title: "cd /Users/example/workspace/oppi",
            trailing: nil,
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let labels = timelineAllLabels(in: view)
        let titleLabel = try #require(labels.first {
            timelineRenderedText(of: $0).contains("cd /Users/example/workspace/oppi")
        })
        let titleRect = titleLabel.convert(titleLabel.bounds, to: view)

        let imageViews = timelineAllImageViews(in: view).filter { !$0.isHidden && $0.image != nil }
        let toolIconRect = imageViews
            .map { $0.convert($0.bounds, to: view) }
            .first { rect in
                rect.maxX <= titleRect.minX && rect.width <= 13
            }

        let iconRect = try #require(toolIconRect)
        #expect(abs(iconRect.midY - titleRect.midY) <= 3)
    }

    @MainActor
    @Test func languageBadgeRendersIconInHeaderTrailingArea() throws {
        let config = makeTimelineToolConfiguration(
            title: "read Runtime/TimelineReducer.swift:220-329",
            languageBadge: "Swift",
            toolNamePrefix: "read",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        // Language badge is now an SF Symbol icon (UIImageView), not a text label.
        let imageViews = timelineAllImageViews(in: view)
        let visibleBadge = imageViews.first { !$0.isHidden && $0.image != nil }
        #expect(visibleBadge != nil)
    }

    @MainActor
    @Test func expandedReadMarkdownAddsPinchGestureForFullScreenReader() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- item"),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let recognizers = timelineAllGestureRecognizers(in: view)
        let hasPinch = recognizers.contains { $0 is UIPinchGestureRecognizer }
        #expect(hasPinch)
    }

    @MainActor
    @Test func expandedReadMarkdownDisablesRowTapCopyToAllowTextSelection() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- item"),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(!view.expandedTapCopyGestureEnabledForTesting)
    }

    @MainActor
    @Test func expandedReadSwiftKeepsRowDoubleTapForFullScreen() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: "struct Test {}",
                language: .swift,
                startLine: 1,
                filePath: "Test.swift"
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
    }

    @MainActor
    @Test func expandedWriteMarkdownAlsoDisablesRowTapCopyToAllowTextSelection() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- write markdown"),
            toolNamePrefix: "write",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(!view.expandedTapCopyGestureEnabledForTesting)
    }

    @MainActor
    @Test func expandedRememberMarkdownAlsoDisablesRowTapCopyToAllowTextSelection() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "remembered note"),
            toolNamePrefix: "remember",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(!view.expandedTapCopyGestureEnabledForTesting)
    }

    @MainActor
    @Test func expandedWriteSwiftKeepsRowDoubleTapForFullScreen() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: "struct Written {}",
                language: .swift,
                startLine: 1,
                filePath: "Written.swift"
            ),
            toolNamePrefix: "write",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
    }

    @MainActor
    @Test func commandContextMenuUsesCopyThenCopyOutput() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyCommandText: "echo hi",
            copyOutputText: "hi",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .command))
        #expect(timelineActionTitles(in: menu) == ["Copy", "Copy Output"])
    }

    @MainActor
    @Test func outputContextMenuUsesCopyThenCopyCommand() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyCommandText: "echo hi",
            copyOutputText: "hi",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .output))
        #expect(timelineActionTitles(in: menu) == ["Copy", "Copy Command"])
    }

    @MainActor
    @Test func expandedContextMenuPrependsOpenFullScreenBeforeCopy() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- item"),
            copyCommandText: "read docs/notes.md",
            copyOutputText: "# Notes\n\n- item",
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .expanded))
        #expect(timelineActionTitles(in: menu) == ["Open Full Screen", "Copy", "Copy Command"])
    }

    @MainActor
    @Test func shortExpandedReadMarkdownHidesFullScreenFloatingButton() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- item"),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let expandButton = try #require(timelineAllViews(in: view)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "tool.expand-full-screen" })

        #expect(expandButton.isHidden)
    }

    @MainActor
    @Test func overflowingExpandedReadMarkdownShowsFullScreenFloatingButton() throws {
        let markdown = "# Notes\n\n" + Array(repeating: "- item", count: 900).joined(separator: "\n")
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: markdown),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let expandButton = try #require(timelineAllViews(in: view)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "tool.expand-full-screen" })

        #expect(!expandButton.isHidden)
    }

    @MainActor
    @Test func emptyExpandedBodyProducesFiniteCompactHeight() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: nil, output: nil, unwrapped: true),
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func transitionFromExpandedContentToEmptyBodyStaysFinite() {
        let expanded = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            isExpanded: true
        )
        let emptyExpanded = makeTimelineToolConfiguration(
            expandedContent: .bash(command: nil, output: nil, unwrapped: true),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: expanded)
        _ = fittedTimelineSize(for: view, width: 370)

        view.configuration = emptyExpanded
        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func reapplyingSameExpandedDiffReusesAttributedTextInstance() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let value = 1"),
                DiffLine(kind: .added, text: "let value = 2"),
                DiffLine(kind: .context, text: "let unchanged = true"),
            ], path: "src/main.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let initialLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("let value = 2")
        })
        let initialAttributed = try #require(initialLabel.attributedText)

        view.configuration = config
        _ = fittedTimelineSize(for: view, width: 370)

        let updatedLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("let value = 2")
        })
        let updatedAttributed = try #require(updatedLabel.attributedText)

        #expect(initialAttributed === updatedAttributed)
    }

    @MainActor
    @Test func reapplyingSameExpandedTodoCardUsesUIKitNativeViewWhenSwiftUIHotPathDisabled() throws {
        let output = """
        {
          "id": "TODO-a27df231",
          "title": "Control tower Live Activity",
          "status": "in_progress",
          "body": "- Capture stall\n- Validate fix"
        }
        """

        let config = makeTimelineToolConfiguration(
            expandedContent: .todoCard(output: output),
            toolNamePrefix: "todo",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        // UIKit-first hot-path policy: no hosted SwiftUI view by default.
        let initialHosted = timelineAllViews(in: view).first {
            String(describing: type(of: $0)).contains("UIHosting")
        }
        #expect(initialHosted == nil)

        let initialLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("TODO-a27df231")
        })
        let initialRendered = timelineRenderedText(of: initialLabel)

        view.configuration = config
        _ = fittedTimelineSize(for: view, width: 370)

        let updatedHosted = timelineAllViews(in: view).first {
            String(describing: type(of: $0)).contains("UIHosting")
        }
        #expect(updatedHosted == nil)

        let updatedLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("TODO-a27df231")
        })
        #expect(timelineRenderedText(of: updatedLabel) == initialRendered)
    }

    @MainActor
    @Test func expandedReadMediaUsesUIKitNativeViewWhenSwiftUIHotPathDisabled() throws {
        let output = "Read image file [image/png]\n\ndata:image/png;base64,\(Self.testPNGBase64)"

        let config = makeTimelineToolConfiguration(
            expandedContent: .readMedia(output: output, filePath: "fixtures/image.png", startLine: 1),
            toolNamePrefix: "read",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let hosted = timelineAllViews(in: view).first {
            String(describing: type(of: $0)).contains("UIHosting")
        }
        #expect(hosted == nil)

        let mediaLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("Images (1)")
        })
        #expect(!timelineRenderedText(of: mediaLabel).isEmpty)
    }

    @MainActor
    @Test func repeatedExpandedTodoReconfigureStaysWithinBudget() {
        let output = """
        {
          "id": "TODO-a27df231",
          "title": "Control tower Live Activity",
          "status": "in_progress",
          "body": "- Capture stall\n- Validate fix"
        }
        """

        let config = makeTimelineToolConfiguration(
            expandedContent: .todoCard(output: output),
            toolNamePrefix: "todo",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let start = ContinuousClock.now
        for _ in 0..<120 {
            view.configuration = config
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(600), "120 identical todo reconfigures took \(elapsed)")
    }

    @MainActor
    @Test func expandedOutputUsesCappedViewportHeight() {
        let longOutput = Array(repeating: "line", count: 600).joined(separator: "\n")
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: longOutput, unwrapped: true),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 300)
        #expect(size.height < 760)
    }

    @MainActor
    @Test func expandedOutputCanUseUnwrappedTerminalLayout() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(
                command: "tail -16 build.log",
                output: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
                unwrapped: true
            ),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 280)

        let outputLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("0123456789abcdefghijklmnopqrstuvwxyz")
        })
        #expect(outputLabel.lineBreakMode == .byClipping)

        let horizontalScroll = timelineAllScrollViews(in: view).first { $0.showsHorizontalScrollIndicator }
        #expect(horizontalScroll != nil)
    }

    @MainActor
    @Test func expandedMarkdownReadUsesNativeMarkdownViewWithCodeBlockSubview() {
        let markdown = """
        # Header

        Wrapped prose paragraph that should render as markdown text.

        ```swift
        let reallyLongLine = \"this code line should not soft wrap inside markdown code block rendering\"
        ```
        """

        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: markdown),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 300)

        let markdownView = timelineFirstView(ofType: AssistantMarkdownContentView.self, in: view)
        #expect(markdownView != nil)

        let codeBlockView = timelineFirstView(ofType: NativeCodeBlockView.self, in: view)
        #expect(codeBlockView != nil)
    }

    @MainActor
    @Test func expandedMarkdownInitialSizingBeforeLayoutPassAvoidsViewportMaxJump() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "Oppi repo normalized per request."),
            toolNamePrefix: "remember",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let firstPassSize = fittedTimelineSizeWithoutPrelayout(for: view, width: 300)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(
            firstPassSize.height < 260,
            "Initial markdown sizing should stay compact; got \(firstPassSize.height)"
        )
    }

    @MainActor
    @Test func expandedPlainTextInitialSizingBeforeLayoutPassAvoidsViewportMaxJump() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .text(
                text: "remember text: Oppi iOS bash tool-row header updated, tags: [6 items]",
                language: nil
            ),
            toolNamePrefix: "remember",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let firstPassSize = fittedTimelineSizeWithoutPrelayout(for: view, width: 300)

        #expect(firstPassSize.height.isFinite)
        #expect(firstPassSize.height > 0)
        #expect(
            firstPassSize.height < 260,
            "Initial wrapped text sizing should stay compact; got \(firstPassSize.height)"
        )
    }

    @MainActor
    @Test func expandedMarkdownReadPreservesTailContentPastGenericTruncationLimit() {
        let longParagraph = String(repeating: "markdown-content-", count: 160)
        let markdown = """
        # Header

        \(longParagraph)

        ## Tail Marker
        Tail content should remain visible in markdown mode.
        """

        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: markdown),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 300)

        let rendered = timelineAllTextViews(in: view)
            .map { $0.attributedText?.string ?? $0.text ?? "" }
            .joined(separator: "\n")

        #expect(rendered.contains("Tail Marker"))
        #expect(!rendered.contains("output truncated for display"))
    }

    @MainActor
    @Test func expandedOutputDisplayTruncatesLargePayloads() throws {
        let longOutput = String(repeating: "x", count: 12_000)
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: nil, output: longOutput, unwrapped: true),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let renderedTexts = timelineAllLabels(in: view).map { timelineRenderedText(of: $0) }
        let longest = try #require(renderedTexts.max(by: { $0.count < $1.count }))

        #expect(longest.count < longOutput.count)
        #expect(longest.contains("output truncated for display"))
        #expect(longest.hasPrefix(String(repeating: "x", count: 128)))
    }

    @MainActor
    @Test func expandedDiffIncreasesBodyHeight() {
        let collapsed = makeTimelineToolConfiguration(isExpanded: false)
        let expanded = makeTimelineToolConfiguration(
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let value = 1"),
                DiffLine(kind: .added, text: "let value = 2"),
                DiffLine(kind: .context, text: "let unchanged = true"),
            ], path: "src/main.swift"),
            isExpanded: true
        )

        let collapsedView = ToolTimelineRowContentView(configuration: collapsed)
        let expandedView = ToolTimelineRowContentView(configuration: expanded)

        let collapsedSize = fittedTimelineSize(for: collapsedView, width: 370)
        let expandedSize = fittedTimelineSize(for: expandedView, width: 370)

        #expect(expandedSize.height > collapsedSize.height)
    }

    @MainActor
    @Test func expandedDiffShowsGutterBarsAndPrefixes() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let value = 1"),
                DiffLine(kind: .added, text: "let value = 2"),
            ], path: "src/main.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        // Diff text is rendered into a UILabel (expandedLabel) inside the scroll view.
        let rendered = timelineAllLabels(in: view)
            .compactMap { $0.attributedText?.string ?? $0.text }
            .joined(separator: "\n")

        // Gutter bar with prefix (▎+ / ▎−) should be present.
        #expect(rendered.contains("▎+"))
        #expect(rendered.contains("▎−"))
        #expect(rendered.contains("let value"))
    }

    @MainActor
    @Test func expandedEmptyDiffShowsNoTextualChangesMessage() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .diff(lines: [], path: "src/main.swift"),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let rendered = timelineAllLabels(in: view)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")

        #expect(rendered.contains("No textual changes"))
    }

    @MainActor
    @Test func errorOutputPresentationStripsANSIEscapeCodes() {
        let input = "\u{001B}[31mFAIL\u{001B}[39m tests/workspace-crud.test.ts"

        let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
            input,
            isError: true
        )

        let rendered = presentation.attributedText?.string ?? presentation.plainText ?? ""
        #expect(rendered == "FAIL tests/workspace-crud.test.ts")
        #expect(!rendered.contains("[31m"))
        #expect(!rendered.contains("[39m"))
    }

    @MainActor
    @Test func errorOutputFallbackStillStripsANSIWhenHighlightingSkipped() {
        let input = "\u{001B}[31mFAIL\u{001B}[39m " + String(repeating: "x", count: 80)

        let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
            input,
            isError: true,
            maxHighlightBytes: 8
        )

        #expect(presentation.attributedText == nil)
        let rendered = presentation.plainText ?? ""
        #expect(rendered.hasPrefix("FAIL "))
        #expect(!rendered.contains("[31m"))
        #expect(!rendered.contains("[39m"))
    }

    @MainActor
    @Test func syntaxOutputPresentationHighlightsKnownLanguage() {
        let source = "guard value else { return }"

        let presentation = ToolRowTextRenderer.makeSyntaxOutputPresentation(
            source,
            language: .swift
        )

        #expect(presentation.plainText == nil)
        #expect(presentation.attributedText?.string == source)
    }

    @MainActor
    @Test func ansiHighlightedSeparatedOutputRemainsVisible() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(
                command: "echo hi",
                output: "\u{001B}[31mFAIL\u{001B}[39m tests/workspace-crud.test.ts",
                unwrapped: true
            ),
            isExpanded: true,
            isError: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let renderedTexts = timelineAllLabels(in: view)
            .map { label in
                label.attributedText?.string ?? label.text ?? ""
            }

        #expect(renderedTexts.contains { $0.contains("FAIL tests/workspace-crud.test.ts") })
    }

    // MARK: - Collapsed Image Preview Regression Tests

    // Minimal valid 1x1 red-pixel PNG for testing (82 bytes, base64).
    private static let testPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    @MainActor
    @Test func collapsedReadImageIsTallerThanPlainRead() {
        // Regression: bodyStack was hidden when only the image preview was
        // visible, because showBody didn't include showImagePreview.
        // The image preview container must make the row taller.
        let plain = makeTimelineToolConfiguration(
            title: "server.ts",
            toolNamePrefix: "read",
            isExpanded: false
        )
        let withImage = makeTimelineToolConfiguration(
            title: "icon.png",
            toolNamePrefix: "read",
            collapsedImageBase64: Self.testPNGBase64,
            collapsedImageMimeType: "image/png",
            isExpanded: false
        )

        let plainView = ToolTimelineRowContentView(configuration: plain)
        let imageView = ToolTimelineRowContentView(configuration: withImage)

        let plainSize = fittedTimelineSize(for: plainView, width: 370)
        let imageSize = fittedTimelineSize(for: imageView, width: 370)

        #expect(
            imageSize.height > plainSize.height,
            "Image preview row (\(imageSize.height)pt) must be taller than plain row (\(plainSize.height)pt)"
        )
    }

    @MainActor
    @Test func collapsedReadImageContainsVisibleImageView() throws {
        // The image preview container must contain a visible UIImageView
        // with scaleAspectFit content mode.
        let config = makeTimelineToolConfiguration(
            title: "icon.png",
            toolNamePrefix: "read",
            collapsedImageBase64: Self.testPNGBase64,
            collapsedImageMimeType: "image/png",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        // Find a non-hidden UIImageView with scaleAspectFit.
        // The status icon and tool icon use scaleAspectFit too, but they are
        // small (≤14pt). The image preview has a constraint of ≤200pt height
        // and sits inside a container with cornerRadius 6.
        let imageViews = timelineAllImageViews(in: view).filter {
            !$0.isHidden && $0.contentMode == .scaleAspectFit
        }
        // Filter to ones whose parent has cornerRadius == 6 (the imagePreviewContainer).
        let previewImageViews = imageViews.filter { iv in
            iv.superview?.layer.cornerRadius == 6
        }

        #expect(!previewImageViews.isEmpty, "Collapsed image row must have a visible image preview UIImageView")
    }

    @MainActor
    @Test func expandedReadImageHidesCollapsedPreview() {
        // When expanded, the collapsed image preview container must be hidden
        // to avoid doubling up with the expanded media renderer.
        let config = makeTimelineToolConfiguration(
            title: "icon.png",
            expandedContent: .text(text: "Read image file [image/png]", language: nil),
            toolNamePrefix: "read",
            collapsedImageBase64: Self.testPNGBase64,
            collapsedImageMimeType: "image/png",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        // The image preview container (cornerRadius == 6, contains aspectFit
        // UIImageView) must be hidden when expanded.
        let visiblePreviewContainers = timelineAllImageViews(in: view)
            .filter { !$0.isHidden && $0.contentMode == .scaleAspectFit }
            .filter { $0.superview?.layer.cornerRadius == 6 }
            .filter { !($0.superview?.isHidden ?? true) }

        #expect(
            visiblePreviewContainers.isEmpty,
            "Collapsed image preview must be hidden when expanded"
        )
    }

    @MainActor
    @Test func collapsedNonImageToolHasNoPreviewContainer() {
        // A bash tool (no image data) must not show any image preview container.
        let config = makeTimelineToolConfiguration(
            title: "echo hello",
            toolNamePrefix: "$",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        // No visible image preview containers (cornerRadius == 6 with
        // scaleAspectFit UIImageView) should exist.
        let visiblePreviewContainers = timelineAllImageViews(in: view)
            .filter { !$0.isHidden && $0.contentMode == .scaleAspectFit }
            .filter { $0.superview?.layer.cornerRadius == 6 && !($0.superview?.isHidden ?? true) }

        #expect(visiblePreviewContainers.isEmpty, "Non-image tools must not show image preview")
    }
}
