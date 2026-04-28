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
            title: "extensions.backlog Refine compaction row preview behavior for consistency across timeline",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 320)

        let labels = timelineAllLabels(in: view)
        let titleLabel = try #require(labels.first {
            timelineRenderedText(of: $0).contains("extensions.backlog Refine compaction row preview behavior")
        })

        #expect(titleLabel.numberOfLines == 1)
    }

    @MainActor
    @Test func expandedFileToolTitleCanWrapToShowFullPath() throws {
        let longPath = "clients/apple/Oppi/Features/Chat/Support/WorkspaceReviewFileDetailView.swift"
        let config = makeTimelineToolConfiguration(
            title: longPath,
            expandedContent: .code(
                text: "struct WorkspaceReviewFileDetailView {}",
                language: .swift,
                startLine: 1,
                filePath: longPath
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 320)

        let labels = timelineAllLabels(in: view)
        let titleLabel = try #require(labels.first {
            timelineRenderedText(of: $0).contains("WorkspaceReviewFileDetailView.swift")
        })

        #expect(titleLabel.numberOfLines == 0)
        #expect(titleLabel.lineBreakMode == NSLineBreakMode.byCharWrapping)
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
    @Test func expandedReadMarkdownKeepsRowDoubleTapForFullScreen() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- item"),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
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
    @Test func expandedWriteMarkdownKeepsRowDoubleTapForFullScreen() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- write markdown"),
            toolNamePrefix: "write",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
    }

    @MainActor
    @Test func expandedExtensionMarkdownKeepsRowDoubleTapForFullScreen() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "extension note"),
            toolNamePrefix: "extensions.notes",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
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
    @Test func selectedTextCommandEditMenuPrependsPiSubmenuAndDisablesTapCopy() throws {
        let router = SelectedTextPiActionRouter { _ in }
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyCommandText: "echo hi",
            copyOutputText: "hi",
            isExpanded: true,
            selectedTextPiRouter: router,
            selectedTextSessionId: "session-1"
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let commandLabel = try #require(timelineAllTextViews(in: view).first { timelineRenderedText(of: $0) == "echo hi" })
        let menu = try #require(view.textView(
            commandLabel,
            editMenuForTextIn: NSRange(location: 0, length: 4),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
        #expect(timelineActionTitles(in: piMenu) == ["Comment", "Explain", "Do it", "Fix", "Refactor", "Add to Prompt", "New Session"])
        let copyMenuAction = try #require(menu.children.dropFirst().first as? UIAction)
        #expect(copyMenuAction.title == "Copy")
        #expect(commandLabel.isSelectable)
    }

    @MainActor
    @Test func selectedTextExpandedMarkdownKeepsInlineFullScreenActivation() throws {
        let router = SelectedTextPiActionRouter { _ in }
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "Alpha beta gamma"),
            toolNamePrefix: "read",
            isExpanded: true,
            selectedTextPiRouter: router,
            selectedTextSessionId: "session-1"
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let markdownView = try #require(timelineFirstView(ofType: AssistantMarkdownContentView.self, in: view))
        let textView = try #require(timelineFirstTextView(in: markdownView))
        let menu = markdownView.textView(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        )

        #expect(menu == nil)
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
    @Test func outputContextMenuIncludesFullScreenBeforeCopyAndCopyCommand() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyCommandText: "echo hi",
            copyOutputText: "hi",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .output))
        #expect(timelineActionTitles(in: menu) == ["Open Full Screen", "Copy", "Copy Command"])
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
    @Test func expandedContextMenuIncludesFullScreenForExtensionMarkdown() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\nLong-lived extension content"),
            copyCommandText: "extensions.notes save",
            copyOutputText: "# Notes\n\nLong-lived extension content",
            toolNamePrefix: "extensions.notes",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .expanded))
        #expect(timelineActionTitles(in: menu) == ["Open Full Screen", "Copy", "Copy Command"])
    }

    @MainActor
    @Test func expandedContextMenuIncludesFullScreenForExtensionText() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .text(text: "Extension hit #1\nExtension hit #2", language: nil),
            copyCommandText: "extensions.lookup architecture",
            copyOutputText: "Extension hit #1\nExtension hit #2",
            toolNamePrefix: "extensions.lookup",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .expanded))
        #expect(timelineActionTitles(in: menu) == ["Open Full Screen", "Copy", "Copy Command"])
    }

    @MainActor
    @Test func expandedToolRowsDoNotInstallFloatingFullScreenButton() {
        let shortConfig = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- item"),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let overflowingConfig = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n" + Array(repeating: "- item", count: 900).joined(separator: "\n")),
            toolNamePrefix: "read",
            isExpanded: true
        )

        let shortView = ToolTimelineRowContentView(configuration: shortConfig)
        _ = fittedTimelineSize(for: shortView, width: 370)

        let overflowingView = ToolTimelineRowContentView(configuration: overflowingConfig)
        _ = fittedTimelineSize(for: overflowingView, width: 370)

        let buttonInShortView = timelineAllViews(in: shortView)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "tool.expand-full-screen" }
        let buttonInOverflowingView = timelineAllViews(in: overflowingView)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "tool.expand-full-screen" }

        #expect(buttonInShortView == nil)
        #expect(buttonInOverflowingView == nil)
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
    @Test func reapplyingSameExpandedDiffKeepsRenderedContentStable() throws {
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

        let initialLabel = try #require(timelineAllTextViews(in: view).first {
            timelineRenderedText(of: $0).contains("let value = 2")
        })
        let initialAttributed = try #require(initialLabel.attributedText)

        view.configuration = config
        _ = fittedTimelineSize(for: view, width: 370)

        let updatedLabel = try #require(timelineAllTextViews(in: view).first {
            timelineRenderedText(of: $0).contains("let value = 2")
        })
        let updatedAttributed = try #require(updatedLabel.attributedText)

        #expect(initialAttributed.length == updatedAttributed.length)
        #expect(initialAttributed.string == updatedAttributed.string)
    }

    @MainActor
    @Test func reapplyingSameExpandedExtensionTextReusesRenderedLabelContent() throws {
        let output = """
        EXT-a27df231
        Control tower Live Activity
        in_progress
        """

        let config = makeTimelineToolConfiguration(
            expandedContent: .text(text: output, language: nil),
            toolNamePrefix: "extensions.backlog",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let initialLabel = try #require(timelineAllTextViews(in: view).first {
            timelineRenderedText(of: $0).contains("EXT-a27df231")
        })
        let initialRendered = timelineRenderedText(of: initialLabel)

        view.configuration = config
        _ = fittedTimelineSize(for: view, width: 370)

        let updatedLabel = try #require(timelineAllTextViews(in: view).first {
            timelineRenderedText(of: $0).contains("EXT-a27df231")
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

        let hasInlineImageView = timelineAllViews(in: view).contains {
            String(describing: type(of: $0)).contains("NativeExpandedInlineImageView")
        }
        #expect(hasInlineImageView)

        let hasCollapsedPreviewHint = timelineAllTextRenderViews(in: view).contains {
            timelineRenderedText(of: $0).contains("collapsed preview")
        }
        #expect(!hasCollapsedPreviewHint)
    }

    @MainActor
    @Test func expandedReadMediaDoesNotRenderDuplicateImageCards() {
        let output = "Read image file [image/png]\n\ndata:image/png;base64,\(Self.testPNGBase64)"

        let config = makeTimelineToolConfiguration(
            expandedContent: .readMedia(output: output, filePath: "fixtures/image.png", startLine: 1),
            toolNamePrefix: "read",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let hasExpandedImageCard = timelineAllViews(in: view).contains {
            String(describing: type(of: $0)).contains("TappableImageCard")
        }
        #expect(!hasExpandedImageCard)
    }

    @MainActor
    @Test func expandedReadMediaPromotesRawSVGSourceToInlinePreview() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 180\"><rect width=\"320\" height=\"180\" fill=\"red\"/></svg>"
        let config = makeTimelineToolConfiguration(
            expandedContent: .readMedia(output: svg, filePath: "fixtures/image.svg", startLine: 1),
            toolNamePrefix: "read",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let hasInlineImageView = timelineAllViews(in: view).contains {
            $0 is NativeExpandedInlineImageView
        }
        #expect(hasInlineImageView)

        let renderedText = timelineAllLabels(in: view).map(timelineRenderedText(of:)).joined(separator: "\n")
        #expect(!renderedText.contains("<svg"))
    }

    @MainActor
    @Test func expandedReadMediaViewportGrowsForTallImages() async throws {
        let portraitSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 600\"><rect width=\"200\" height=\"600\" fill=\"red\"/></svg>"
        let landscapeSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 600 200\"><rect width=\"600\" height=\"200\" fill=\"blue\"/></svg>"

        let portraitView = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .readMedia(output: portraitSVG, filePath: "fixtures/portrait.svg", startLine: 1),
            toolNamePrefix: "read",
            isExpanded: true
        ))
        let landscapeView = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
            expandedContent: .readMedia(output: landscapeSVG, filePath: "fixtures/landscape.svg", startLine: 1),
            toolNamePrefix: "read",
            isExpanded: true
        ))

        let portraitContainer = UIView(frame: CGRect(x: 0, y: 0, width: 370, height: 800))
        let landscapeContainer = UIView(frame: CGRect(x: 0, y: 0, width: 370, height: 800))
        for (container, view) in [(portraitContainer, portraitView), (landscapeContainer, landscapeView)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
            ])
            container.setNeedsLayout()
            container.layoutIfNeeded()
        }

        let portraitViewport = try #require(
            Mirror(reflecting: portraitView).children.first { $0.label == "expandedViewportHeightConstraint" }?.value as? NSLayoutConstraint
        )
        let landscapeViewport = try #require(
            Mirror(reflecting: landscapeView).children.first { $0.label == "expandedViewportHeightConstraint" }?.value as? NSLayoutConstraint
        )

        let updated = await waitForTimelineCondition(timeoutMs: 1_500) {
            await MainActor.run {
                portraitContainer.setNeedsLayout()
                landscapeContainer.setNeedsLayout()
                portraitContainer.layoutIfNeeded()
                landscapeContainer.layoutIfNeeded()
                return portraitViewport.constant > landscapeViewport.constant + 120
            }
        }

        #expect(updated)
        #expect(portraitViewport.constant > 300)
        #expect(landscapeViewport.constant < 260)
    }

    @MainActor
    @Test func inlineSVGPreviewAppliesAspectRatioConstraintAfterAsyncDecode() async throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 180\"><rect width=\"320\" height=\"180\" fill=\"red\"/></svg>"
        let view = NativeExpandedInlineImageView(maxPixelSize: 1_600)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        view.apply(base64: Data(svg.utf8).base64EncodedString(), mimeType: "image/svg+xml")

        let appliedConstraint = await waitForTimelineCondition(timeoutMs: 1_500) {
            await MainActor.run {
                view.constraints.contains {
                    $0.firstAttribute == .height
                        && $0.secondItem === view
                        && $0.secondAttribute == .width
                        && abs($0.multiplier - (180.0 / 320.0)) < 0.001
                }
            }
        }

        #expect(appliedConstraint, "Expected SVG preview height to track the viewBox aspect ratio")
    }

    @MainActor
    @Test func repeatedExpandedExtensionTextReconfigureStaysWithinBudget() {
        let output = """
        EXT-a27df231
        Control tower Live Activity
        in_progress
        """

        let config = makeTimelineToolConfiguration(
            expandedContent: .text(text: output, language: nil),
            toolNamePrefix: "extensions.backlog",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let start = ContinuousClock.now
        for _ in 0..<120 {
            view.configuration = config
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(600), "120 identical extension reconfigures took \(elapsed)")
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

        let outputLabel = try #require(timelineAllTextViews(in: view).first {
            timelineRenderedText(of: $0).contains("0123456789abcdefghijklmnopqrstuvwxyz")
        })
        #expect(outputLabel.textContainer.lineBreakMode == .byClipping)

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
            toolNamePrefix: "extensions.notes",
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
                text: "extension text: Oppi iOS bash tool-row header updated, tags: [6 items]",
                language: nil
            ),
            toolNamePrefix: "extensions.notes",
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
    @Test func expandedOutputDisplayKeepsLargePayloadsIntact() throws {
        let longOutput = String(repeating: "x", count: 12_000)
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: nil, output: longOutput, unwrapped: true),
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let renderedTexts = timelineAllTextRenderViews(in: view).map { timelineRenderedText(of: $0) }
        let longest = try #require(renderedTexts.max(by: { $0.count < $1.count }))

        #expect(longest.contains(longOutput))
        #expect(!longest.contains("output truncated for display"))
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

        // Diff text is rendered into the expanded UITextView inside the viewport.
        let rendered = timelineAllTextViews(in: view)
            .compactMap { $0.attributedText?.string ?? $0.text }
            .joined(separator: "\n")

        // Gutter with prefix ( + /  - ) should be present.
        #expect(rendered.contains(" + "))
        #expect(rendered.contains(" - "))
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

        let rendered = timelineAllTextRenderViews(in: view)
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

        let renderedTexts = timelineAllTextRenderViews(in: view)
            .map { timelineRenderedText(of: $0) }

        #expect(renderedTexts.contains { $0.contains("FAIL tests/workspace-crud.test.ts") })
    }

    // MARK: - Collapsed Image Row Presentation

    // Minimal valid 1x1 red-pixel PNG for testing (82 bytes, base64).
    private static let testPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    @MainActor
    @Test func collapsedReadImageMatchesPlainReadHeight() {
        let plain = makeTimelineToolConfiguration(
            title: "server.ts",
            toolNamePrefix: "read",
            isExpanded: false
        )
        let imageLikeRead = makeTimelineToolConfiguration(
            title: "icon.png",
            languageBadge: FileType.image.displayLabel,
            toolNamePrefix: "read",
            isExpanded: false
        )

        let plainView = ToolTimelineRowContentView(configuration: plain)
        let imageView = ToolTimelineRowContentView(configuration: imageLikeRead)

        let plainSize = fittedTimelineSize(for: plainView, width: 370)
        let imageSize = fittedTimelineSize(for: imageView, width: 370)

        #expect(abs(imageSize.height - plainSize.height) < 24)
    }

    @MainActor
    @Test func collapsedReadImageDoesNotRenderInlinePreview() {
        let config = makeTimelineToolConfiguration(
            title: "icon.png",
            languageBadge: FileType.image.displayLabel,
            toolNamePrefix: "read",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        let previewImageViews = timelineAllImageViews(in: view)
            .filter { !$0.isHidden && $0.image != nil && $0.contentMode == .scaleAspectFit }
            .filter { $0.superview?.layer.cornerRadius == 6 }
            .filter { !($0.superview?.isHidden ?? true) }

        #expect(previewImageViews.isEmpty)
    }

    @MainActor
    @Test func imageBadgeUsesPhotoIcon() {
        #expect(ToolTimelineRowUIHelpers.languageBadgeImage(for: FileType.image.displayLabel) != nil)
    }

    // Disabled: test seam properties removed — needs update
    #if false
    @MainActor
    @Test(.disabled("test seam properties removed")) func collapsedNonImageToolHasNoPreviewContainer() {
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

    // MARK: - Full-Screen Gesture Contract
    //
    // Every expanded tool type that supports full screen must have:
    //   1. Double-tap gesture enabled on its active container
    //   2. Pinch gesture enabled on its active container
    //   3. "Open Full Screen" in its context menu
    //   4. canShowFullScreenContent == true
    //
    // Tool types that do NOT support full screen (plot, readMedia) must
    // have canShowFullScreenContent == false.

    // Disabled: tests below reference removed test-seam properties
    // (outputDoubleTapGestureEnabledForTesting, canShowFullScreenContentForTesting, etc.)
    // Re-enable once the production code re-exposes these or tests are rewritten.

    @MainActor
    @Test(.disabled("test seam properties removed — needs update"))
    func bashExpandedHasFullScreenDoubleTapOnOutputContainer() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "ls", output: "/usr\n/bin", unwrapped: true),
            copyOutputText: "/usr\n/bin",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.outputDoubleTapGestureEnabledForTesting)
        #expect(view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func bashExpandedHasPinchGestureOnOutputContainer() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "ls", output: "/usr\n/bin", unwrapped: true),
            copyOutputText: "/usr\n/bin",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.outputPinchGestureEnabledForTesting)
    }

    @MainActor
    @Test func bashExpandedContextMenuIncludesOpenFullScreen() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "ls", output: "/usr\n/bin", unwrapped: true),
            copyCommandText: "ls",
            copyOutputText: "/usr\n/bin",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .output))
        let titles = timelineActionTitles(in: menu)
        #expect(titles.contains("Open Full Screen"))
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func readCodeExpandedHasFullScreenGestures() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: "struct Test {}",
                language: .swift,
                startLine: 1,
                filePath: "Test.swift"
            ),
            copyOutputText: "struct Test {}",
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
        #expect(view.expandedPinchGestureEnabledForTesting)
        #expect(view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test func expandedVoiceMessageDoesNotDuplicateVoiceMessageTitleInsideCard() throws {
        let config = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: "Got it. I’m reinstalling the iPhone app now, and I’ll launch it as part of the install so it comes back up cleanly.",
                attachmentId: "att-voice-1",
                mimeType: "audio/wav",
                durationSeconds: 4.2,
                delivery: nil
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let voiceMessageLabels = timelineAllLabels(in: view).filter {
            timelineRenderedText(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) == "Voice message"
        }
        #expect(voiceMessageLabels.count == 1)
    }

    @MainActor
    @Test func expandedVoiceMessageKeepsPlaybackButtonInHeaderTrailingArea() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .voiceMessage(
                text: "Got it. I’m reinstalling the iPhone app now, and I’ll launch it as part of the install so it comes back up cleanly.",
                attachmentId: "att-voice-1",
                mimeType: "audio/wav",
                durationSeconds: 4.2,
                delivery: nil
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedTimelineSize(for: view, width: 370)

        let button = try #require(privateButton(named: "audioPlaybackButton", in: view))
        #expect(!button.isHidden)

        let titleLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) == "Voice message"
        })
        let buttonRect = button.convert(button.bounds, to: view)
        let titleRect = titleLabel.convert(titleLabel.bounds, to: view)
        #expect(buttonRect.minX > titleRect.maxX)
    }

    @MainActor
    @Test func streamingVoiceSpeakTextDoesNotReserveGiantBodySpace() {
        let transcript = "Fixed and installed. Empty voice transcripts no longer reserve that giant expanded body; the row collapses to the header unless there is actual transcript text to show."
        let config = ToolPresentationBuilder.build(
            itemID: "voice-streaming-text",
            tool: "voice_speak",
            argsSummary: "text: \(transcript)",
            outputPreview: transcript,
            isError: false,
            isDone: false,
            context: emptyContext(expandedItemIDs: ["voice-streaming-text"])
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.height < 240)
    }

    @MainActor
    @Test func expandedVoiceMessageWrappedTranscriptDoesNotReserveGiantBodySpace() {
        let transcript = "Fixed and installed. Empty voice transcripts no longer reserve that giant expanded body; the row collapses to the header unless there is actual transcript text to show."
        let config = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: transcript,
                attachmentId: "att-wrapped-voice",
                mimeType: "audio/wav",
                durationSeconds: 4.0,
                delivery: .directSpeak
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.height < 240)
    }

    @MainActor
    @Test func expandedVoiceMessageWithEmptyTranscriptDoesNotReserveBodySpace() {
        let config = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: "",
                attachmentId: "att-empty-voice",
                mimeType: "audio/wav",
                durationSeconds: 1.0,
                delivery: .directSpeak
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.height < 90)
    }

    @MainActor
    @Test func streamingVoiceMessageWithNoTranscriptOrAttachmentDoesNotReserveViewport() {
        let config = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: "",
                attachmentId: "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                delivery: .directSpeak
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true,
            isDone: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedTimelineSize(for: view, width: 370)

        #expect(size.height < 90)
        #expect(view.expandedContainer.isHidden)
    }

    @MainActor
    @Test func streamingVoiceMessageHeightTransitionsFromEmptyToTranscriptWithoutViewportJump() {
        let empty = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: "",
                attachmentId: "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                delivery: .directSpeak
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true,
            isDone: false
        )
        let withTranscript = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: "Direct voice is streaming now. The card should grow to the transcript, not jump to a generic streaming viewport.",
                attachmentId: "",
                mimeType: "audio/wav",
                durationSeconds: nil,
                delivery: .directSpeak
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true,
            isDone: false
        )

        let view = ToolTimelineRowContentView(configuration: empty)
        let emptySize = fittedTimelineSize(for: view, width: 370)

        view.configuration = withTranscript
        let transcriptSize = fittedTimelineSize(for: view, width: 370)

        #expect(emptySize.height < 90)
        #expect(transcriptSize.height > emptySize.height)
        #expect(transcriptSize.height < 220)
    }

    @MainActor
    @Test func voiceMessageFirstExpandFitsTranscriptHeight() throws {
        let transcript = "Direct voice is working now, and this transcript should be visible immediately without waiting for a second expand pass."
        let collapsed = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: transcript,
                attachmentId: "att-voice-first-height",
                mimeType: "audio/wav",
                durationSeconds: 2.0,
                delivery: .directSpeak
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: false
        )
        var expanded = collapsed
        expanded.isExpanded = true

        let view = ToolTimelineRowContentView(configuration: collapsed)
        view.frame = CGRect(x: 0, y: 0, width: 370, height: 1)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        view.configuration = expanded
        let firstExpandSize = fittedTimelineSize(for: view, width: 370)
        let voiceView = try #require(timelineFirstView(ofType: NativeVoiceMessageView.self, in: view))

        #expect(firstExpandSize.height >= 104)
        #expect(voiceView.bounds.width >= 320)
    }

    @MainActor
    @Test func voiceMessageTranscriptAppearsOnFirstExpandFromCollapsedState() throws {
        let transcript = "Direct voice is working now, and this transcript should be visible immediately."
        let collapsed = makeTimelineToolConfiguration(
            title: "Voice message",
            expandedContent: .voiceMessage(
                text: transcript,
                attachmentId: "att-voice-first-expand",
                mimeType: "audio/wav",
                durationSeconds: 2.0,
                delivery: .directSpeak
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: false
        )
        var expanded = collapsed
        expanded.isExpanded = true

        let view = ToolTimelineRowContentView(configuration: collapsed)
        _ = fittedTimelineSize(for: view, width: 370)

        view.configuration = expanded
        _ = fittedTimelineSize(for: view, width: 370)

        let rendered = timelineAllLabels(in: view)
            .filter { !$0.isHidden }
            .map(timelineRenderedText(of:))
            .joined(separator: "\n")
        #expect(rendered.contains("this transcript should be visible immediately"))
    }

    @MainActor
    @Test func expandedVoiceMessageShowsReadableTranscriptWithoutDuplicateTitle() throws {
        let transcript = "Got it. I’m reinstalling the iPhone app now, and I’ll launch it as part of the install so it comes back up cleanly."
        let config = makeTimelineToolConfiguration(
            expandedContent: .voiceMessage(
                text: transcript,
                attachmentId: "att-voice-1",
                mimeType: "audio/wav",
                durationSeconds: 4.2,
                delivery: nil
            ),
            toolNamePrefix: "voice_speak",
            toolNameColor: .systemPurple,
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedTimelineSize(for: view, width: 370)
        let transcriptLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("reinstalling the iPhone app now")
        })
        let voiceMessageLabels = timelineAllLabels(in: view).filter {
            timelineRenderedText(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) == "Voice message"
        }

        #expect(!transcriptLabel.isHidden)
        #expect(transcriptLabel.numberOfLines == 0)
        #expect(transcriptLabel.font == AppFont.messageBody)
        #expect(size.height < 200)
        #expect(voiceMessageLabels.count == 1)
    }

    @MainActor
    @Test func readCodeExpandedContextMenuIncludesOpenFullScreen() throws {
        let config = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: "struct Test {}",
                language: .swift,
                startLine: 1,
                filePath: "Test.swift"
            ),
            copyCommandText: "read Test.swift",
            copyOutputText: "struct Test {}",
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let menu = try #require(view.contextMenu(for: .expanded))
        let titles = timelineActionTitles(in: menu)
        #expect(titles.contains("Open Full Screen"))
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func editDiffExpandedHasFullScreenGestures() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .diff(lines: [
                DiffLine(kind: .removed, text: "let x = 1"),
                DiffLine(kind: .added, text: "let x = 2"),
            ], path: "main.swift"),
            copyOutputText: "- let x = 1\n+ let x = 2",
            toolNamePrefix: "edit",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
        #expect(view.expandedPinchGestureEnabledForTesting)
        #expect(view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func markdownExpandedHasPinchButNotDoubleTapCopy() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Notes\n\n- item"),
            copyOutputText: "# Notes\n\n- item",
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        // Markdown disables double-tap copy to allow text selection,
        // but still supports full screen via pinch and context menu.
        #expect(!view.expandedTapCopyGestureEnabledForTesting)
        #expect(view.expandedPinchGestureEnabledForTesting)
        #expect(view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func extensionTextExpandedHasFullScreenGestures() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .text(text: "recall result #1\nrecall result #2", language: nil),
            copyOutputText: "recall result #1\nrecall result #2",
            toolNamePrefix: "extensions.recall",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandedTapCopyGestureEnabledForTesting)
        #expect(view.expandedPinchGestureEnabledForTesting)
        #expect(view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func readMediaExpandedDoesNotSupportFullScreen() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .readMedia(
                output: "data:image/png;base64,iVBORw0KGgo=",
                filePath: "icon.png",
                startLine: 1
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(!view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func collapsedToolDoesNotSupportFullScreen() {
        let config = makeTimelineToolConfiguration(
            copyOutputText: "some output",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(!view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func bashWithNoOutputDoesNotSupportFullScreen() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "true", output: nil, unwrapped: true),
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(!view.canShowFullScreenContentForTesting)
    }

    @MainActor
    @Test(.disabled("test seam properties removed")) func shortBashOutputHidesFloatingButton() {
        let config = makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyOutputText: "hi",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 370)

        #expect(view.expandFloatingButtonHiddenForTesting)
    }
    #endif
}
