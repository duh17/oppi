import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Full-screen review comment selection")
struct FullScreenReviewCommentSelectionTests {
    @Test func codeBodyPrependsCommentAction() throws {
        let controller = makeController(
            content: .code(content: "let answer = 42", language: "swift", filePath: "Answer.swift", startLine: 1)
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @Test func anchoredCodeBodyUsesOneContinuousEnclosureAndScrollsToRequestedLines() async throws {
        let anchor = try #require(SourceLineAnchor(startLine: 32, endLine: 35))
        let source = (1...80).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let controller = makeController(
            content: .code(content: source, language: "swift", filePath: "Anchor.swift", startLine: 1),
            lineAnchor: anchor
        )
        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenCodeBody)

        let focused = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            guard let rect = body.debugLineAnchorFirstHighlightRectForTesting else { return false }
            return body.debugLineAnchorHighlightRectCountForTesting == 1
                && body.debugLineAnchorGutterMarkerCountForTesting == 1
                && body.debugLineAnchorHighlightHasVisibleGeometryForTesting
                && (body.debugLineAnchorScrollOffsetForTesting.y > 0 || rect.midY < body.debugLineAnchorViewportHeightForTesting * 0.5)
        }

        #expect(focused)
        #expect(body.debugLineAnchorExistingRangeForTesting == 32...35)
        #expect(body.debugLineAnchorHighlightRectCountForTesting == 1)
        #expect(body.debugLineAnchorGutterMarkerCountForTesting == 1)
        #expect(body.debugLineAnchorHighlightHasVisibleGeometryForTesting)
        let firstRect = try #require(body.debugLineAnchorFirstHighlightRectForTesting)
        #expect(
            body.debugLineAnchorScrollOffsetForTesting.y > 0,
            "offset=\(body.debugLineAnchorScrollOffsetForTesting.y) viewport=\(body.debugLineAnchorViewportHeightForTesting) content=\(body.debugLineAnchorContentHeightForTesting) rect=\(firstRect)"
        )
        let visibleFirstRectMidY = firstRect.midY - body.debugLineAnchorScrollOffsetForTesting.y
        #expect(
            visibleFirstRectMidY < body.debugLineAnchorViewportHeightForTesting * 0.5,
            "offset=\(body.debugLineAnchorScrollOffsetForTesting.y) viewport=\(body.debugLineAnchorViewportHeightForTesting) content=\(body.debugLineAnchorContentHeightForTesting) rect=\(firstRect)"
        )
    }

    @Test func anchoredSingleCodeLineUsesOneRoundedEnclosure() async throws {
        let anchor = try #require(SourceLineAnchor(startLine: 32, endLine: 32))
        let source = (1...80).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let controller = makeController(
            content: .code(content: source, language: "swift", filePath: "Anchor.swift", startLine: 1),
            lineAnchor: anchor
        )
        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenCodeBody)

        let ready = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            return body.debugLineAnchorHighlightRectCountForTesting == 1
                && body.debugLineAnchorGutterMarkerCountForTesting == 1
                && body.debugLineAnchorHighlightHasVisibleGeometryForTesting
                && body.debugLineAnchorFirstHighlightRectForTesting != nil
        }

        #expect(ready)
        #expect(body.debugLineAnchorExistingRangeForTesting == 32...32)
        #expect(body.debugLineAnchorHighlightRectCountForTesting == 1)
        #expect(body.debugLineAnchorGutterMarkerCountForTesting == 1)
        #expect(body.debugLineAnchorHighlightHasVisibleGeometryForTesting)
    }

    @Test func anchoredMarkdownReaderUsesOneEnclosureForOverlappingBlocks() async throws {
        let anchor = try #require(SourceLineAnchor(startLine: 6, endLine: 12))
        let body = NativeFullScreenMarkdownBody(
            content: "# Intro\n\nBefore\n\n## Focus\n\nFirst focused block\n\nSecond focused block\n\nAfter",
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            sourceFilePath: "Anchor.md",
            lineAnchor: anchor
        )
        let host = attachToHost(body)
        defer { host.removeFromSuperview() }
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let focused = await waitForMainActorCondition(timeout: .seconds(2)) {
            body.debugLayoutVisibleMarkdownCellsForTesting()
            let visibleCellCount = body.debugLineAnchorVisibleHighlightedCellCountForTesting
            return body.debugLineAnchorHighlightedSegmentCountForTesting >= 2
                && visibleCellCount >= 2
                && body.debugLineAnchorVisibleHighlightEnclosureCountForTesting == 1
                && body.debugLineAnchorVisibleHighlightGeometryCountForTesting == 1
                && body.debugLineAnchorVisibleHighlightAreaForTesting > 0
                && body.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting
                && body.debugLineAnchorVisibleHighlightOverlaysFrontmostForTesting
        }

        #expect(focused)
        #expect(body.debugLineAnchorExistingRangeForTesting == 6...11)
        #expect(body.debugLineAnchorHighlightedSegmentCountForTesting >= 2)
        #expect(body.debugLineAnchorVisibleHighlightedCellCountForTesting >= 2)
        #expect(body.debugLineAnchorVisibleHighlightEnclosureCountForTesting == 1)
        #expect(body.debugLineAnchorVisibleHighlightGeometryCountForTesting == 1)
        #expect(body.debugLineAnchorVisibleHighlightAreaForTesting > 0)
        #expect(body.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting)
        #expect(body.debugLineAnchorVisibleHighlightOverlaysFrontmostForTesting)
    }

    @Test func anchoredGraphvizBodyCarriesLineAnchorToCodeRenderer() async throws {
        let anchor = try #require(SourceLineAnchor(startLine: 12, endLine: 14))
        let source = (1...40).map { "node\($0) -> node\($0 + 1)" }.joined(separator: "\n")
        let controller = makeController(
            content: .graphviz(content: source, filePath: "graph.dot"),
            lineAnchor: anchor
        )
        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenCodeBody)

        let highlighted = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            return body.debugLineAnchorExistingRangeForTesting == 12...14
                && body.debugLineAnchorHighlightRectCountForTesting == 1
                && body.debugLineAnchorGutterMarkerCountForTesting == 1
                && body.debugLineAnchorHighlightHasVisibleGeometryForTesting
        }

        #expect(highlighted)
        #expect(body.debugLineAnchorExistingRangeForTesting == 12...14)
        #expect(body.debugLineAnchorGutterMarkerCountForTesting == 1)
    }

    @Test func markdownSourceTogglePreservesTheExactLineFocus() async throws {
        let anchor = try #require(SourceLineAnchor(startLine: 10, endLine: 12))
        let source = (1...30).map { "Source line \($0)" }.joined(separator: "\n")
        let controller = makeController(
            content: .markdown(content: source, filePath: "Anchor.md"),
            lineAnchor: anchor
        )

        let reader = try #require(controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody)
        let readerReady = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            return reader.debugLineAnchorHighlightedSegmentCountForTesting > 0
        }
        #expect(readerReady)

        controller.toggleSourceForTesting()
        let sourceBody = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            return controller.installedBodyViewForTesting is NativeFullScreenSourceBody
        }
        #expect(sourceBody)
        let sourceView = try #require(controller.installedBodyViewForTesting as? NativeFullScreenSourceBody)
        let sourceFocused = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            return sourceView.debugLineAnchorHighlightRectCountForTesting == 1
                && sourceView.debugLineAnchorVisibleHighlightGeometryForTesting
                && sourceView.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting
        }
        #expect(sourceFocused)
        #expect(sourceView.debugLineAnchorExistingRangeForTesting == 10...12)
        #expect(sourceView.debugLineAnchorVisibleHighlightGeometryForTesting)
        #expect(sourceView.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting)
    }

    @Test func outOfRangeLineAnchorNoticeCallbackIsDeliveredOnceAcrossBodyRebuilds() async throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }

        let anchor = try #require(SourceLineAnchor(startLine: 99, endLine: 100))
        var notices: [String] = []
        let controller = FullScreenCodeViewController(
            content: .code(
                content: "let onlyLine = true",
                language: "swift",
                filePath: "Short.swift",
                startLine: 1
            ),
            lineAnchor: anchor,
            lineAnchorNotice: { message in
                notices.append(message)
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let delivered = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.lineAnchorNoticeDeliveredForTesting
        }
        #expect(delivered)
        #expect(notices.count == 1)
        #expect(notices.first?.contains("Opened at the end") == true)

        let rebuiltTheme: ThemeID = ThemeRuntimeState.currentThemeID() == .light ? .dark : .light
        controller.applyThemeIfNeeded(rebuiltTheme)
        for _ in 0..<10 { await Task.yield() }
        #expect(notices.count == 1, "Out-of-range notice must remain one-shot after a body rebuild")
    }

    @Test func anchoredSourceBodyHighlightsTheEmptyLineAfterATrailingNewline() async throws {
        let anchor = try #require(SourceLineAnchor(startLine: 2, endLine: 2))
        let body = NativeFullScreenSourceBody(
            content: "one\n",
            isStreaming: false,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            lineAnchor: anchor
        )
        let host = attachToHost(body)
        defer { host.removeFromSuperview() }

        let focused = await waitForMainActorCondition(timeout: .seconds(2)) {
            body.layoutIfNeeded()
            return body.debugLineAnchorHighlightRectCountForTesting == 1
                && body.debugLineAnchorVisibleHighlightGeometryForTesting
        }
        #expect(focused)
        #expect(body.debugLineAnchorVisibleHighlightGeometryForTesting)
        let rect = try #require(body.debugLineAnchorFirstHighlightRectForTesting)
        #expect(rect.minY > 20, "The trailing empty line must be below the first source line: \(rect)")
    }

    @Test func anchoredSourceHighlightStaysAttachedDuringManualScroll() async throws {
        let anchor = try #require(SourceLineAnchor(startLine: 40, endLine: 43))
        let content = (1...140).map { "Source line \($0)" }.joined(separator: "\n")
        let body = NativeFullScreenSourceBody(
            content: content,
            isStreaming: false,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            lineAnchor: anchor
        )
        let hostController = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        hostController.loadViewIfNeeded()
        body.translatesAutoresizingMaskIntoConstraints = false
        hostController.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: hostController.view.trailingAnchor),
            body.topAnchor.constraint(equalTo: hostController.view.topAnchor),
            body.bottomAnchor.constraint(equalTo: hostController.view.bottomAnchor),
        ])
        hostController.view.setNeedsLayout()
        hostController.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: body).first as? FullScreenReviewCommentTextView)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let measuredContentHeight = textView.layoutManager.usedRect(for: textView.textContainer).maxY
            + textView.textContainerInset.bottom
        // A detached UIKit test host reports the viewport as contentSize even
        // after TextKit lays out the full source. Seed the measured height so
        // this exercises a real contentOffset scroll rather than rubber-banding.
        textView.contentSize = CGSize(
            width: textView.contentSize.width,
            height: max(textView.bounds.height + 120, measuredContentHeight)
        )

        let initiallyFocused = await waitForMainActorCondition(timeout: .seconds(2)) {
            hostController.view.layoutIfNeeded()
            body.layoutIfNeeded()
            return body.debugLineAnchorHighlightRectCountForTesting == 1
                && body.debugLineAnchorVisibleHighlightGeometryForTesting
                && body.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting
        }
        #expect(initiallyFocused)
        #expect(body.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting)

        let beforeOffset = textView.contentOffset.y
        let beforeRect = try #require(body.debugLineAnchorFirstHighlightRectForTesting)
        let minimumOffset = -textView.adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            textView.contentSize.height
                - textView.bounds.height
                + textView.adjustedContentInset.bottom
        )
        let manualOffset = min(max(beforeOffset + 36, minimumOffset), maximumOffset)
        #expect(
            manualOffset > beforeOffset,
            "Fixture must leave room for a user scroll: content=\(textView.contentSize) bounds=\(textView.bounds) insets=\(textView.adjustedContentInset)"
        )

        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: manualOffset), animated: false)
        body.scrollViewDidScroll(textView)
        body.layoutIfNeeded()

        let afterOffset = textView.contentOffset.y
        let afterRect = try #require(body.debugLineAnchorFirstHighlightRectForTesting)
        #expect(abs(afterOffset - manualOffset) <= 0.5)
        #expect(
            abs((afterRect.midY - beforeRect.midY) + (afterOffset - beforeOffset)) <= 1,
            "Highlight must track manual scrolling: before=\(beforeRect) after=\(afterRect) offsets=\(beforeOffset)->\(afterOffset)"
        )
        #expect(body.debugLineAnchorHighlightRectCountForTesting == 1)
        #expect(body.debugLineAnchorVisibleHighlightGeometryForTesting)
        #expect(body.debugLineAnchorVisibleHighlightAlignedWithTargetForTesting)
        print(
            "[line-anchor] source-manual-scroll: offset=\(beforeOffset)->\(afterOffset) "
                + "firstMidY=\(beforeRect.midY)->\(afterRect.midY) "
                + "enclosure=\(String(describing: body.debugLineAnchorHighlightEnclosureRectForTesting)) "
                + "visibleGeometry=\(body.debugLineAnchorVisibleHighlightGeometryForTesting)"
        )

        // Updating the enclosure must not re-run initial focus or fight the
        // user's chosen offset.
        #expect(abs(textView.contentOffset.y - manualOffset) <= 0.5)
    }

    @Test func anchoredCodeThemeChangePreservesUserViewportWithoutRefocusing() async throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        ThemeRuntimeState.setThemeID(.dark)

        let anchor = try #require(SourceLineAnchor(startLine: 120, endLine: 125))
        let content = (1...300).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let controller = makeController(
            content: .code(content: content, language: "swift", filePath: "Theme.swift", startLine: 1),
            lineAnchor: anchor
        )
        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenCodeBody)
        let focused = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            return body.debugLineAnchorScrollOffsetForTesting.y > 0
        }
        #expect(focused)

        let scrollView = try #require(timelineAllScrollViews(in: body).first {
            !($0 is UITextView) && $0.contentSize.height > $0.bounds.height
        })
        scrollView.setContentOffset(CGPoint(x: 0, y: 42), animated: false)
        let expectedOffset = scrollView.contentOffset.y

        controller.applyThemeIfNeeded(.light)
        let preserved = await waitForMainActorCondition(timeout: .seconds(2)) {
            controller.view.layoutIfNeeded()
            guard let updatedScrollView = timelineAllScrollViews(in: controller.view).first(where: {
                !($0 is UITextView) && $0.contentSize.height > $0.bounds.height
            }) else {
                return false
            }
            return abs(updatedScrollView.contentOffset.y - expectedOffset) <= 1
        }
        #expect(preserved)
    }

    @Test func codeBodyConfiguresSelectionCommentContext() throws {
        let controller = makeController(
            content: .code(content: "let answer = 42", language: "swift", filePath: "Answer.swift", startLine: 1)
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        } as? FullScreenReviewCommentTextView)

        #expect(textView.reviewCommentSelectionRouter != nil)
        #expect(textView.reviewCommentSourceContext?.surface == .fullScreenCode)
    }

    @Test func selectedCodeUsesSystemMenuActionAndNoStandaloneCommentBar() async throws {
        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { _, _ in
                Issue.record("Full-screen code should use the inline review composer")
            },
            inlineSave: { _, _ in true }
        )
        let controller = FullScreenCodeViewController(
            content: .code(content: "let answer = 42\nlet done = true", language: nil, filePath: "Answer.swift", startLine: 1),
            reviewCommentSelectionContext: ReviewCommentSelectionContext(
                dispatcher: router,
                sessionId: "session-1",
                sourceLabel: "Full Screen",
                filePath: "Answer.swift",
                languageHint: "swift"
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        } as? FullScreenReviewCommentTextView)
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: 0, length: 3)
        controller.view.layoutIfNeeded()

        #expect(!hasVisibleView(identifier: "review-comment.selection-bar", in: controller.view))

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")

        let button = UIButton(type: .system)
        button.addAction(commentAction, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)

        let composerAppeared = await waitForMainActorCondition {
            self.hasVisibleView(identifier: "review-comment.inline-composer", in: controller.view)
        }
        #expect(composerAppeared, "The native menu Comment action should open the inline comment composer")
    }

    @Test func markdownCodeBlockInFullScreenUsesInlineComposer() async throws {
        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { _, _ in
                Issue.record("Full-screen markdown code blocks should use the inline review composer")
            },
            inlineSave: { _, _ in true }
        )
        let body = NativeFullScreenMarkdownBody(
            content: "Intro\n\n```swift\nlet one = 1\nlet two = 2\n```\n\nDone",
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: router,
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenMarkdown,
                filePath: "CHANGELOG.md",
                languageHint: "markdown"
            )
        )
        let hostController = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        hostController.loadViewIfNeeded()
        body.translatesAutoresizingMaskIntoConstraints = false
        hostController.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: hostController.view.trailingAnchor),
            body.topAnchor.constraint(equalTo: hostController.view.topAnchor),
            body.bottomAnchor.constraint(equalTo: hostController.view.bottomAnchor),
        ])
        hostController.view.setNeedsLayout()
        hostController.view.layoutIfNeeded()
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("let two = 2")
        })
        let rendered = timelineRenderedText(of: textView) as NSString
        let selectedRange = rendered.range(of: "let two = 2")
        #expect(selectedRange.location != NSNotFound)
        textView.becomeFirstResponder()
        textView.selectedRange = selectedRange

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: selectedRange,
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")

        let button = UIButton(type: .system)
        button.addAction(commentAction, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)

        let composerAppeared = await waitForMainActorCondition {
            self.hasVisibleView(identifier: "review-comment.inline-composer", in: hostController.view)
        }
        #expect(composerAppeared, "Commenting in a full-screen markdown code block should keep the reader open and show the inline composer")
    }

    @Test func markdownTableInFullScreenUsesInlineComposer() async throws {
        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { _, _ in
                Issue.record("Full-screen markdown tables should use the inline review composer")
            },
            inlineSave: { _, _ in true }
        )
        let body = NativeFullScreenMarkdownBody(
            content: "| Item | Status |\n| --- | --- |\n| Destination | Needs review |",
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: router,
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenMarkdown,
                filePath: "CHANGELOG.md",
                languageHint: "markdown"
            )
        )
        let hostController = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        hostController.loadViewIfNeeded()
        body.translatesAutoresizingMaskIntoConstraints = false
        hostController.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: hostController.view.trailingAnchor),
            body.topAnchor.constraint(equalTo: hostController.view.topAnchor),
            body.bottomAnchor.constraint(equalTo: hostController.view.bottomAnchor),
        ])
        hostController.view.setNeedsLayout()
        hostController.view.layoutIfNeeded()
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("Needs review")
        })
        let rendered = timelineRenderedText(of: textView) as NSString
        let selectedRange = rendered.range(of: "Needs review")
        #expect(selectedRange.location != NSNotFound)
        textView.becomeFirstResponder()
        textView.selectedRange = selectedRange

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: selectedRange,
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")

        let button = UIButton(type: .system)
        button.addAction(commentAction, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)

        let composerAppeared = await waitForMainActorCondition {
            self.hasVisibleView(identifier: "review-comment.inline-composer", in: hostController.view)
        }
        #expect(composerAppeared, "Commenting in a full-screen markdown table should keep the reader open and show the inline composer")
    }

    @Test func markdownNestedBlockSurfacesMatchContainingSurfaceDestination() throws {
        let content = """
        ```swift
        let nested = true
        ```

        | Item | Status |
        | --- | --- |
        | Destination | Needs review |
        """

        var assistantRequests: [ReviewCommentSelectionRequest] = []
        let assistantView = makeMarkdownContentView(
            content: content,
            surface: .assistantProse,
            captured: { assistantRequests.append($0) }
        )
        let assistantHost = attachToHost(assistantView)
        _ = assistantHost
        try dispatchCommentAction(
            textView: try #require(timelineAllTextViews(in: assistantView).first { timelineRenderedText(of: $0).contains("let nested = true") }),
            selectedText: "let nested = true"
        )
        try dispatchCommentAction(
            textView: try #require(timelineAllTextViews(in: assistantView).first { timelineRenderedText(of: $0).contains("Needs review") }),
            selectedText: "Needs review"
        )
        #expect(assistantRequests.map(\.source.surface) == [.assistantCodeBlock, .assistantTable])

        var expandedRequests: [ReviewCommentSelectionRequest] = []
        let expandedView = makeMarkdownContentView(
            content: content,
            surface: .toolExpandedText,
            captured: { expandedRequests.append($0) }
        )
        let expandedHost = attachToHost(expandedView)
        _ = expandedHost
        try dispatchCommentAction(
            textView: try #require(timelineAllTextViews(in: expandedView).first { timelineRenderedText(of: $0).contains("let nested = true") }),
            selectedText: "let nested = true"
        )
        try dispatchCommentAction(
            textView: try #require(timelineAllTextViews(in: expandedView).first { timelineRenderedText(of: $0).contains("Needs review") }),
            selectedText: "Needs review"
        )
        #expect(expandedRequests.map(\.source.surface) == [.toolExpandedText, .toolExpandedText])
    }

    @Test func inlineCommentComposerStaysAboveKeyboardWhenAnchorIsBehindKeyboard() throws {
        let hostController = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        hostController.loadViewIfNeeded()
        hostController.view.frame = window.bounds
        let keyboardFrame = CGRect(
            x: window.bounds.minX,
            y: window.bounds.maxY - 320,
            width: window.bounds.width,
            height: 320
        )
        hostController.view.setNeedsLayout()
        hostController.view.layoutIfNeeded()

        let sourceView = UIView(frame: window.bounds)
        hostController.view.addSubview(sourceView)
        let composer = ReviewCommentInlineDraftView(
            request: ReviewCommentSelectionRequest(
                selectedText: "server path",
                source: ReviewCommentSourceContext(sessionId: "session-1", surface: .fullScreenMarkdown)
            ),
            router: ReviewCommentSelectionRouter(dispatch: { _ in }, inlineSave: { _, _ in true }),
            quickComments: [],
            sourceView: sourceView,
            anchorRect: CGRect(x: 24, y: window.bounds.maxY - 96, width: 1, height: 24)
        )
        composer.present(in: hostController.view)

        let convertedKeyboardFrame = hostController.view.convert(keyboardFrame, from: nil)
        composer.setKeyboardFrameInHostForTesting(convertedKeyboardFrame)
        hostController.view.layoutIfNeeded()

        let keyboardTopInHost = convertedKeyboardFrame.minY
        #expect(composer.frame.maxY <= keyboardTopInHost - 10, "Inline composer must stay above a docked iPad keyboard")
    }

    @Test func nativeFullscreenEditMenuSuppressesFallbackPresentationForSameSelection() throws {
        let textView = FullScreenReviewCommentTextView()
        textView.text = "let answer = 42\nlet done = true"
        textView.configureReviewCommentSelection(
            router: ReviewCommentSelectionRouter { _ in },
            sourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "Answer.swift"
            )
        )
        textView.selectedRange = NSRange(location: 0, length: 3)
        #expect(textView.shouldPresentFallbackEditMenuForTesting())

        let menu = try #require(buildFullScreenReviewCommentMenu(
            textView: textView,
            range: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }],
            router: textView.reviewCommentSelectionRouter,
            sourceContext: textView.reviewCommentSourceContext
        ))
        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
        #expect(!textView.shouldPresentFallbackEditMenuForTesting())

        textView.selectedRange = NSRange(location: 4, length: 6)
        #expect(textView.shouldPresentFallbackEditMenuForTesting())
    }

    @Test func fullScreenReviewCommentTextViewPreservesSelectionWhenApplyingAttributedText() throws {
        let textView = FullScreenReviewCommentTextView()
        textView.text = "let answer = 42\nlet done = true"
        textView.selectedRange = NSRange(location: 4, length: 6)

        textView.setAttributedTextPreservingSelection(NSAttributedString(string: textView.text))

        #expect(textView.selectedRange == NSRange(location: 4, length: 6))
    }

    @Test func reviewSelectionTipReservesSpaceAndUsesCompactInstructionCopy() throws {
        FeatureEducationTipPresentationCoordinator.shared.resetForTesting()
        FullScreenReviewCommentTextView.forcesReviewSelectionTipForTesting = true
        defer {
            FullScreenReviewCommentTextView.forcesReviewSelectionTipForTesting = false
            FeatureEducationTipPresentationCoordinator.shared.resetForTesting()
        }

        let textView = FullScreenReviewCommentTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 400), textContainer: nil)
        let baseInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        textView.textContainerInset = baseInset
        textView.text = "let answer = 42\nlet done = true"

        textView.configureReviewCommentSelection(
            router: ReviewCommentSelectionRouter { _ in },
            sourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "Answer.swift"
            )
        )
        textView.layoutIfNeeded()

        let tipView = try #require(timelineAllViews(in: textView).first {
            $0.accessibilityIdentifier == "feature-tip.review-selection.tip"
        })
        #expect(tipView.accessibilityLabel?.contains("Select text, then tap Comment") == true)
        #expect(textView.textContainerInset.top > baseInset.top + 50)
    }

    @Test func codeGutterKeepsWrappedContinuationRowsBlank() throws {
        let longLine = "let message = \"" + String(repeating: "wrap-me-", count: 28) + "\""
        let body = NativeFullScreenCodeBody(
            content: longLine + "\nlet done = true",
            language: "swift",
            startLine: 10,
            palette: ThemeID.dark.palette,
            readerPreferences: FullScreenReaderPreferences(wrapsText: true),
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 300))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let codeView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("wrap-me-")
        })
        let diagnostics = body.codeGutterAlignmentDiagnosticsForTesting()

        #expect(codeView.textContainer.lineBreakMode == .byCharWrapping)
        #expect(diagnostics.rowCount == 2)
        #expect(diagnostics.maxRowDelta <= 0.5)
        #expect(diagnostics.firstLogicalLineGap > diagnostics.lineHeight * 2)
    }

    @Test func diffBodyKeepsSelectableTextWhileRichRenderBuilds() throws {
        let controller = makeController(
            content: .diff(
                oldText: "let value = 1",
                newText: "let value = 2",
                filePath: "Value.swift",
                precomputedLines: [
                    DiffLine(kind: .removed, text: "let value = 1"),
                    DiffLine(kind: .added, text: "let value = 2"),
                ]
            )
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("+ let value = 2")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @Test func markdownBodyUsesItsProvidedOLEDPaletteWhenRuntimeThemeIsStale() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        ThemeRuntimeState.setThemeID(.light)

        let body = NativeFullScreenMarkdownBody(
            content: "# OLED heading\n\nBody",
            stream: nil,
            themeID: .oled,
            palette: ThemeID.oled.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = attachToHost(body)
        _ = host
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let headingTextView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("OLED heading")
        })
        let headingRange = (timelineRenderedText(of: headingTextView) as NSString).range(of: "OLED heading")
        let headingColor = try #require(
            headingTextView.attributedText?.attribute(.foregroundColor, at: headingRange.location, effectiveRange: nil) as? UIColor
        )

        #expect(headingColor == UIColor(ThemeID.oled.palette.mdHeading))
    }

    @Test func fullScreenMarkdownUsesOwnerThemeWhenRuntimeThemeIsStale() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        ThemeRuntimeState.setThemeID(.light)

        let controller = FullScreenCodeViewController(
            content: .markdown(content: "# OLED heading\n\nBody", filePath: "Notes.md")
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.applyThemeIfNeeded(.oled)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let markdownBody = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: controller.view))
        markdownBody.debugLayoutVisibleMarkdownCellsForTesting()
        let headingTextView = try #require(timelineAllTextViews(in: markdownBody).first {
            timelineRenderedText(of: $0).contains("OLED heading")
        })
        let headingRange = (timelineRenderedText(of: headingTextView) as NSString).range(of: "OLED heading")
        let headingColor = try #require(
            headingTextView.attributedText?.attribute(.foregroundColor, at: headingRange.location, effectiveRange: nil) as? UIColor
        )

        #expect(headingColor == UIColor(ThemeID.oled.palette.mdHeading))
    }

    @Test func fullScreenMarkdownRetainsOwnerThemeAppliedBeforeViewLoad() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        ThemeRuntimeState.setThemeID(.light)

        let controller = FullScreenCodeViewController(
            content: .markdown(content: "# OLED heading\n\nBody", filePath: "Notes.md")
        )
        controller.applyThemeIfNeeded(.oled)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let markdownBody = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: controller.view))
        markdownBody.debugLayoutVisibleMarkdownCellsForTesting()
        let headingTextView = try #require(timelineAllTextViews(in: markdownBody).first {
            timelineRenderedText(of: $0).contains("OLED heading")
        })
        let headingRange = (timelineRenderedText(of: headingTextView) as NSString).range(of: "OLED heading")
        let headingColor = try #require(
            headingTextView.attributedText?.attribute(.foregroundColor, at: headingRange.location, effectiveRange: nil) as? UIColor
        )

        #expect(headingColor == UIColor(ThemeID.oled.palette.mdHeading))
    }

    @Test func markdownBodyKeepsAdjacentHeadingAndParagraphInSingleSelectionSurface() throws {
        let body = NativeFullScreenMarkdownBody(
            content: "# Selection heading\n\nParagraph text continues here.",
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = attachToHost(body)
        _ = host
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let matchingTextViews = timelineAllTextViews(in: body).filter {
            let text = timelineRenderedText(of: $0)
            return text.contains("Selection heading") || text.contains("Paragraph text continues here.")
        }

        #expect(matchingTextViews.count == 1, "Adjacent markdown prose must share one UITextView so native selection can cross block boundaries")
        let textView = try #require(matchingTextViews.first)
        let renderedText = timelineRenderedText(of: textView) as NSString
        let headingRange = renderedText.range(of: "Selection heading")
        let paragraphRange = renderedText.range(of: "Paragraph text continues here.")
        try #require(headingRange.location != NSNotFound)
        try #require(paragraphRange.location != NSNotFound)
        let crossBlockRange = NSRange(
            location: headingRange.location,
            length: NSMaxRange(paragraphRange) - headingRange.location
        )

        textView.selectedRange = crossBlockRange

        #expect(textView.selectedRange == crossBlockRange)
        #expect(crossBlockRange.length > headingRange.length)
    }

    @Test func markdownBodyPrependsCommentAction() throws {
        let controller = makeController(
            content: .markdown(content: "Alpha beta gamma", filePath: "Notes.md")
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("Alpha beta gamma")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @Test func codeBodyUsesStartLineForSelectedSourceLine() throws {
        var captured: ReviewCommentSelectionRequest?
        let body = NativeFullScreenCodeBody(
            content: "let first = 1\nlet second = 2\nlet third = 3",
            language: "swift",
            startLine: 40,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { captured = $0 },
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "Sources/App.swift",
                languageHint: "swift"
            )
        )
        let host = attachToHost(body)
        _ = host

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("let second = 2")
        })
        try dispatchCommentAction(textView: textView, selectedText: "let second = 2")

        let request = try #require(captured)
        #expect(request.selectedText == "let second = 2")
        #expect(request.source.filePath == "Sources/App.swift")
        #expect(request.source.lineRange == 41...41)
    }

    @Test func sourceBodyOffsetsSelectionFromProvidedSourceRange() throws {
        var captured: ReviewCommentSelectionRequest?
        let body = NativeFullScreenSourceBody(
            content: "alpha\nbeta\ngamma",
            isStreaming: false,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { captured = $0 },
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenSource,
                filePath: "notes.txt",
                lineRange: 20...22
            )
        )
        let host = attachToHost(body)
        _ = host

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("beta")
        })
        try dispatchCommentAction(textView: textView, selectedText: "beta")

        let request = try #require(captured)
        #expect(request.selectedText == "beta")
        #expect(request.source.filePath == "notes.txt")
        #expect(request.source.lineRange == 21...21)
    }

    @Test func diffBodyUsesSourceLineAttributesForAddedAndRemovedRows() async throws {
        var captured: [ReviewCommentSelectionRequest] = []
        let lines = [
            DiffLine(kind: .context, text: "let first = 1", oldLineNumber: 10, newLineNumber: 10),
            DiffLine(kind: .removed, text: "let value = 2", oldLineNumber: 11, newLineNumber: nil),
            DiffLine(kind: .added, text: "let value = 3", oldLineNumber: nil, newLineNumber: 11),
            DiffLine(kind: .context, text: "let last = 4", oldLineNumber: 12, newLineNumber: 12),
        ]
        let body = NativeFullScreenDiffBody(
            oldText: "",
            newText: "",
            filePath: "Sources/App.swift",
            precomputedLines: lines,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { captured.append($0) },
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenDiff,
                filePath: "Sources/App.swift"
            )
        )
        let host = attachToHost(body)
        _ = host

        let textView = try #require(timelineAllTextViews(in: body).first)
        let richDiffReady = await waitForMainActorCondition {
            let text = textView.attributedText?.string ?? ""
            let addedRange = (text as NSString).range(of: "let value = 3")
            guard addedRange.location != NSNotFound else { return false }
            return textView.attributedText?.attribute(
                reviewLineNumberAttributeKey,
                at: addedRange.location,
                effectiveRange: nil
            ) as? Int == 11
        }
        #expect(richDiffReady)

        try dispatchCommentAction(textView: textView, selectedText: "let value = 3")
        try dispatchCommentAction(textView: textView, selectedText: "let value = 2")

        #expect(captured.count == 2)
        if captured.count == 2 {
            #expect(captured[0].source.lineRange == 11...11)
            #expect(captured[1].source.lineRange == 11...11)
        }
        #expect(captured.allSatisfy { $0.source.filePath == "Sources/App.swift" })
    }

    @Test func markdownBodyUsesSourceLineForRenderedHeadingSelection() throws {
        var captured: ReviewCommentSelectionRequest?
        let body = makeMarkdownBody(
            content: "# Changelog\n\n## Changed\n\n- Server: Extension loading follows Pi resource loading.",
            captured: { captured = $0 }
        )
        let host = attachToHost(body)
        _ = host
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("Changed")
        })
        try dispatchCommentAction(textView: textView, selectedText: "Changed")

        let request = try #require(captured)
        #expect(request.selectedText == "Changed")
        #expect(request.source.filePath == "CHANGELOG.md")
        #expect(request.source.lineRange == 3...3)
    }

    @Test func markdownBodyUsesSourceLineForRenderedListSelection() throws {
        var captured: ReviewCommentSelectionRequest?
        let body = makeMarkdownBody(
            content: "# Changelog\n\n- first item\n- second item\n- third item",
            captured: { captured = $0 }
        )
        let host = attachToHost(body)
        _ = host
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("second item")
        })
        try dispatchCommentAction(textView: textView, selectedText: "second item")

        let request = try #require(captured)
        #expect(request.selectedText == "second item")
        #expect(request.source.lineRange == 4...4)
    }

    @Test func markdownBodyUsesSourceLineForRenderedCodeBlockSelection() throws {
        var captured: ReviewCommentSelectionRequest?
        let body = makeMarkdownBody(
            content: "Intro\n\n```swift\nlet one = 1\nlet two = 2\n```\n\nDone",
            captured: { captured = $0 }
        )
        let host = attachToHost(body)
        _ = host
        body.debugLayoutVisibleMarkdownCellsForTesting()

        let textView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("let two = 2")
        })
        try dispatchCommentAction(textView: textView, selectedText: "let two = 2")

        let request = try #require(captured)
        #expect(request.selectedText == "let two = 2")
        #expect(request.source.surface == .fullScreenMarkdown)
        #expect(request.source.filePath == "CHANGELOG.md")
        #expect(request.source.lineRange == 5...5)
    }

    @Test func fullScreenMarkdownUsesRichRenderingForLargeDocuments() throws {
        let content = [
            "# Heading",
            "",
            "**Bold intro** with `inline code`.",
            "",
            String(repeating: "Body paragraph with enough text to exercise large markdown rendering.\n\n", count: 320),
        ].joined(separator: "\n")
        #expect(content.count > 20_000)

        let controller = makeController(
            content: .markdown(content: content, filePath: "Notes.md")
        )
        let renderedText = timelineAllTextViews(in: controller.view)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")

        #expect(renderedText.contains("Heading"))
        #expect(renderedText.contains("Bold intro"))
        #expect(renderedText.contains("inline code"))
        #expect(!renderedText.contains("# Heading"))
        #expect(!renderedText.contains("**Bold intro**"))
        #expect(!renderedText.contains("`inline code`"))
    }

    @Test func fullScreenMarkdownVirtualizesLargeDocumentsWithoutChangingRenderingPath() throws {
        let repeatedSections = (0..<400).map { index in
            """
            ## Section \(index)

            **Strong text \(index)** links to [Node](https://nodejs.org/api/fs.html#section-\(index)) and includes `inline code`.

            ```js
            const section\(index) = \(index);
            ```
            """
        }.joined(separator: "\n\n")
        #expect(repeatedSections.utf8.count > 50_000)

        let body = NativeFullScreenMarkdownBody(
            content: repeatedSections,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()
        body.debugLayoutVisibleMarkdownCellsForTesting()

        #expect(body.debugRenderedSegmentCountForTesting > 700)
        #expect(body.debugVisibleCellCountForTesting < body.debugRenderedSegmentCountForTesting)

        let visibleText = timelineAllTextViews(in: body)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(visibleText.contains("Section 0"))
        #expect(visibleText.contains("Strong text 0"))
        #expect(!visibleText.contains("## Section 0"))
        #expect(!visibleText.contains("**Strong text 0**"))
        #expect(!visibleText.contains("[render note"))
    }

    @Test func liveMarkdownSourceUsesRichRenderingWhileStreaming() throws {
        let markdown = "# Streaming plan\n\n**Decision** with `inline code`."
        let stream = SourceTraceStream(
            text: markdown,
            filePath: nil,
            isDone: false,
            finalContent: .markdown(content: markdown, filePath: nil)
        )
        let controller = makeController(
            content: .liveSource(snapshot: stream.snapshot, stream: stream)
        )

        let markdownView = try #require(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: controller.view))
        markdownView.debugLayoutVisibleMarkdownCellsForTesting()
        let renderedText = timelineAllTextViews(in: markdownView)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")

        #expect(renderedText.contains("Streaming plan"))
        #expect(renderedText.contains("Decision"))
        #expect(renderedText.contains("inline code"))
        #expect(!renderedText.contains("# Streaming plan"))
        #expect(!renderedText.contains("**Decision**"))
        #expect(!renderedText.contains("`inline code`"))

        let nextMarkdown = markdown + "\n\n## Next section"
        stream.update(
            text: nextMarkdown,
            filePath: nil,
            isDone: false,
            finalContent: .markdown(content: nextMarkdown, filePath: nil)
        )
        controller.view.layoutIfNeeded()
        markdownView.debugLayoutVisibleMarkdownCellsForTesting()

        let updatedText = timelineAllTextViews(in: markdownView)
            .map { timelineRenderedText(of: $0) }
            .joined(separator: "\n")
        #expect(updatedText.contains("Next section"))
        #expect(!updatedText.contains("## Next section"))
    }

    @Test func thinkingBodyPrependsCommentAction() throws {
        let controller = makeController(
            content: .thinking(content: "Think harder")
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("Think harder")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @Test func terminalBodyPrependsCommentAction() throws {
        let controller = makeController(
            content: .terminal(content: "hello\nworld", command: "echo hello", stream: nil)
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("hello") && !$0.isHidden
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 5),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @Test func terminalBodyDefaultsToUnwrappedOutputAndCanToggleWrapping() throws {
        let longLine = String(repeating: "abcdefghij", count: 40)
        let body = NativeFullScreenTerminalBody(
            content: longLine,
            command: nil,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let outputView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0) == longLine
        })
        let outerScrollView = try #require(timelineAllScrollViews(in: body).first { !($0 is UITextView) })

        #expect(outputView.textContainer.lineBreakMode == .byClipping)
        #expect(outerScrollView.showsHorizontalScrollIndicator)

        body.setOutputWrapped(true)
        host.layoutIfNeeded()
        #expect(outputView.textContainer.lineBreakMode == .byCharWrapping)
        #expect(!outerScrollView.showsHorizontalScrollIndicator)

        body.setOutputWrapped(false)
        host.layoutIfNeeded()
        #expect(outputView.textContainer.lineBreakMode == .byClipping)
        #expect(outerScrollView.showsHorizontalScrollIndicator)
    }

    @Test func terminalFullScreenWrapButtonTogglesOutputMode() throws {
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: .terminal)
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .terminal) }
        let longLine = String(repeating: "0123456789", count: 40)
        let controller = makeController(
            content: .terminal(content: longLine, command: "printf", stream: nil)
        )
        let outputView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0) == longLine
        })

        #expect(controller.hasFloatingViewingOptionsButtonForTesting)
        #expect(outputView.textContainer.lineBreakMode == .byClipping)

        controller.setReaderWrappingForTesting(true)
        controller.view.layoutIfNeeded()

        #expect(outputView.textContainer.lineBreakMode == .byCharWrapping)
    }

    @Test func diffFullScreenSupportsWrapTextAndAlignsLineHeader() async throws {
        FullScreenReaderPreferencesStore.shared.setPreferences(
            FullScreenReaderPreferences(wrapsText: true),
            for: .diff
        )
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff) }
        let longLine = "let message = \"" + String(repeating: "wrap-me-", count: 28) + "\""
        let body = NativeFullScreenDiffBody(
            oldText: "",
            newText: longLine,
            filePath: "LongLine.swift",
            precomputedLines: [DiffLine(kind: .added, text: longLine, oldLineNumber: nil, newLineNumber: 220)],
            palette: ThemeID.dark.palette,
            readerPreferences: FullScreenReaderPreferences(wrapsText: true),
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 220, height: 420))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let diffView = try #require(timelineAllTextViews(in: body).first {
            timelineRenderedText(of: $0).contains("wrap-me-")
        })

        #expect(FullScreenReaderContentFamily.diff.supportsWrapping)
        #expect(FullScreenReaderPreferencesStore.shared.preferences(for: .diff).wrapsText)
        let wrappedAndAligned = await waitForMainActorCondition {
            host.layoutIfNeeded()
            guard let diagnostics = body.diffWrappingDiagnosticsForTesting(),
                  let secondFragmentX = diagnostics.secondFragmentX else { return false }
            return diffView.textContainer.lineBreakMode == .byCharWrapping
                && diagnostics.textContainerLineBreakMode == .byCharWrapping
                && diagnostics.paragraphLineBreakMode == .byCharWrapping
                && diagnostics.fragmentCount >= 2
                && abs(diagnostics.paragraphHeadIndent - diagnostics.expectedCodeColumnX) <= 0.5
                && abs(secondFragmentX - diagnostics.expectedCodeColumnX) <= 1.0
        }
        #expect(wrappedAndAligned)

        let diagnostics = try #require(body.diffWrappingDiagnosticsForTesting())
        #expect(diagnostics.firstFragmentX <= 0.5)
        #expect((diagnostics.secondFragmentX ?? 0) > diagnostics.firstFragmentX + 20)
    }

    @Test func viewingOptionsUsesBottomRightReaderButtonAndContinuousTextScale() throws {
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: .code)
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .code) }
        let controller = makeController(
            content: .code(content: "let answer = 42", language: "swift", filePath: "Answer.swift", startLine: 1)
        )

        let buttonFrame = try #require(controller.floatingViewingOptionsButtonFrameForTesting)
        #expect(buttonFrame.midX > controller.view.bounds.midX)
        #expect(buttonFrame.midY > controller.view.bounds.midY)
        #expect(abs(buttonFrame.width - FullScreenFloatingControlChrome.controlSize) <= 0.5)
        #expect(abs(buttonFrame.height - FullScreenFloatingControlChrome.controlSize) <= 0.5)
        #expect(
            abs(controller.view.bounds.maxY - buttonFrame.maxY - FullScreenFloatingControlChrome.bottomPadding) <= 0.5
        )

        let options = try #require(controller.makeViewingOptionsControllerForTesting())
        #expect(options.preferredContentSize.width == 340)

        let codeView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })
        let initialPointSize = try #require(codeView.font?.pointSize)
        controller.setReaderTextScaleForTesting(1.25)
        controller.view.layoutIfNeeded()
        let scaledPointSize = try #require(codeView.font?.pointSize)
        #expect(scaledPointSize > initialPointSize)
    }

    @Test func fullscreenThemeNotificationPreservesCodeViewportAndSelection() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }

        ThemeRuntimeState.setThemeID(.dark)
        let content = (0..<300).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let controller = makeController(
            content: .code(content: content, language: "swift", filePath: "Long.swift", startLine: 1)
        )
        let originalTextView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let value299")
        })
        controller.view.layoutIfNeeded()
        let originalScrollView = try #require(timelineAllScrollViews(in: controller.view).first {
            !($0 is UITextView) && $0.contentSize.height > $0.bounds.height
        })
        originalScrollView.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
        originalTextView.selectedRange = NSRange(location: 24, length: 12)
        let expectedOffset = originalScrollView.contentOffset
        let expectedSelection = originalTextView.selectedRange

        ThemeRuntimeState.setThemeID(.light)
        NotificationCenter.default.post(name: .oppiThemeDidChange, object: nil)
        controller.view.layoutIfNeeded()

        let updatedTextView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let value299")
        })
        let updatedScrollView = try #require(timelineAllScrollViews(in: controller.view).first {
            !($0 is UITextView) && $0.contentSize.height > $0.bounds.height
        })
        #expect(abs(updatedScrollView.contentOffset.y - expectedOffset.y) <= 1)
        #expect(updatedTextView.selectedRange == expectedSelection)
    }

    @Test func sourceBodyPrependsCommentAction() throws {
        let controller = makeController(
            content: .plainText(content: "raw source", filePath: "Notes.txt")
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("raw source")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @Test func sourceBodyConfiguresSelectionCommentContext() throws {
        let controller = makeController(
            content: .plainText(content: "raw source", filePath: "Notes.txt")
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("raw source")
        } as? FullScreenReviewCommentTextView)

        #expect(textView.reviewCommentSelectionRouter != nil)
        #expect(textView.reviewCommentSourceContext?.surface == .fullScreenSource)
    }

    @Test func liveSourceBodyPrependsCommentAction() throws {
        let stream = SourceTraceStream(
            text: "streaming source",
            filePath: "Draft.swift",
            isDone: false,
            finalContent: nil
        )
        let controller = makeController(
            content: .liveSource(snapshot: stream.snapshot, stream: stream)
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("streaming source")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 6),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let commentAction = try #require(menu.children.first as? UIAction)
        #expect(commentAction.title == "Comment")
    }

    @Test func fullScreenViewerInstallsResourceActionsBeforeReaderActions() throws {
        let controller = FullScreenCodeViewController(
            content: .markdown(content: "# Prompt", filePath: "Schedule.md"),
            navigationActions: [
                FullScreenViewerNavigationAction(
                    id: "edit",
                    title: "Edit",
                    accessibilityLabel: "Edit in Oppi Session",
                    handler: {}
                ),
            ]
        )
        controller.loadViewIfNeeded()

        let navigationController = try #require(controller.children.first as? UINavigationController)
        let contentController = try #require(navigationController.topViewController)
        let actions = try #require(contentController.navigationItem.rightBarButtonItems)

        #expect(actions.first?.title == "Edit")
        #expect(actions.first?.accessibilityLabel == "Edit in Oppi Session")
        #expect(actions.dropFirst().contains { $0.image == UIImage(systemName: "doc.on.doc") })
    }

    @Test func fullScreenTerminalCopyStripsANSI() throws {
        let formatted = "\u{001B}[1m$\u{001B}[0m oppi status\n\u{001B}[32mPaired\u{001B}[0m"
        let previousPasteboardValue = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previousPasteboardValue }

        let controller = FullScreenCodeViewController(
            content: .terminal(content: formatted, command: nil)
        )
        controller.loadViewIfNeeded()
        let navigationController = try #require(controller.children.first as? UINavigationController)
        let contentController = try #require(navigationController.topViewController)
        _ = try #require(contentController.navigationItem.rightBarButtonItems?.last)
        _ = controller.perform(Selector("copyTapped"))

        #expect(UIPasteboard.general.string == ANSIParser.strip(formatted))
    }

    @Test func fullScreenViewerUpdatesResourceActionState() throws {
        let controller = FullScreenCodeViewController(
            content: .markdown(content: "# Prompt", filePath: "Schedule.md"),
            navigationActions: [
                FullScreenViewerNavigationAction(
                    id: "edit",
                    title: "Edit",
                    accessibilityLabel: "Edit in Oppi Session",
                    handler: {}
                ),
            ]
        )
        controller.loadViewIfNeeded()
        let navigationController = try #require(controller.children.first as? UINavigationController)
        let contentController = try #require(navigationController.topViewController)

        controller.setNavigationActions([
            FullScreenViewerNavigationAction(
                id: "edit",
                title: "Starting…",
                accessibilityLabel: "Edit in Oppi Session",
                accessibilityValue: "Starting",
                isEnabled: false,
                handler: {}
            ),
        ])

        let edit = try #require(contentController.navigationItem.rightBarButtonItems?.first)
        #expect(edit.title == "Starting…")
        #expect(edit.accessibilityValue == "Starting")
        #expect(!edit.isEnabled)
    }

    @Test func liveSourceChunkUpdateKeepsNavigationChromeWhenMetadataIsUnchanged() throws {
        let stream = SourceTraceStream(
            text: "streaming source",
            filePath: "Draft.swift",
            isDone: false,
            finalContent: nil
        )
        let controller = makeController(
            content: .liveSource(snapshot: stream.snapshot, stream: stream)
        )
        let navigationController = try #require(controller.children.first as? UINavigationController)
        let contentController = try #require(navigationController.topViewController)
        let copyButton = try #require(contentController.navigationItem.rightBarButtonItems?.first)

        stream.update(
            text: "streaming source\nnext chunk",
            filePath: "Draft.swift",
            isDone: false,
            finalContent: nil
        )

        #expect(contentController.navigationItem.rightBarButtonItems?.first === copyButton)
    }

    @Test func routerForwardsFullscreenPresenterWhenCommentActionDispatches() throws {
        let presenter = UIViewController()
        var forwardedPresenter: UIViewController?
        let request = ReviewCommentSelectionRequest(
            selectedText: "selected text",
            source: ReviewCommentSourceContext(sessionId: "session-1", surface: .fullScreenMarkdown)
        )
        let router = ReviewCommentSelectionRouter(dispatchWithPresentation: { _, presentingViewController in
            forwardedPresenter = presentingViewController
        })

        router.dispatch(request, presentingViewController: presenter)

        #expect(forwardedPresenter === presenter)
    }

    @Test func expandedToolTextUsesInlineComposerButCollapsedToolOutputUsesChatComposer() {
        #expect(ReviewCommentSurfaceKind.toolExpandedText.usesInlineCommentWidget)
        #expect(!ReviewCommentSurfaceKind.toolOutput.usesInlineCommentWidget)
        #expect(!ReviewCommentSurfaceKind.toolCommand.usesInlineCommentWidget)
    }

    @Test func fullScreenSourceContextIgnoresTimelineSurfaceOverride() {
        let context = ReviewCommentSelectionContext(
            dispatcher: ReviewCommentSelectionRouter { _ in },
            sessionId: "session-1",
            sourceLabel: "Tool output",
            filePath: "output.log",
            sourceSurfaceOverride: .toolExpandedText
        )

        let expanded = context.sourceContext(surface: .fullScreenSource)
        let fullScreen = context.sourceContextIgnoringSurfaceOverride(surface: .fullScreenSource)

        #expect(expanded.surface == .toolExpandedText)
        #expect(fullScreen.surface == .fullScreenSource)
        #expect(fullScreen.filePath == "output.log")
    }

    @Test func nonChatFullScreenCodeStillAllowsSystemTextSelection() throws {
        let controller = FullScreenCodeViewController(
            content: .code(content: "let answer = 42", language: "swift", filePath: "Answer.swift", startLine: 1)
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        #expect(textView.isSelectable)
        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        // UITextView treats a nil edit-menu return as "no menu". Keep system actions.
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @Test func fallbackEditMenuPresentsSystemActionsWithoutReviewRouter() throws {
        let textView = FullScreenReviewCommentTextView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 200),
            textContainer: nil
        )
        textView.text = "let answer = 42"
        textView.configureReviewCommentSelection(router: nil, sourceContext: nil)
        textView.selectedRange = NSRange(location: 0, length: 3)

        #expect(textView.shouldPresentFallbackEditMenuForTesting())

        let menu = try #require(
            textView.fallbackEditMenuForTesting(
                suggestedActions: [UIAction(title: "Copy") { _ in }]
            )
        )
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @Test func fallbackEditMenuPrependsCommentWhenReviewRouterConfigured() throws {
        let textView = FullScreenReviewCommentTextView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 200),
            textContainer: nil
        )
        textView.text = "let answer = 42"
        textView.configureReviewCommentSelection(
            router: ReviewCommentSelectionRouter { _ in },
            sourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "Answer.swift"
            )
        )
        textView.selectedRange = NSRange(location: 0, length: 3)

        let menu = try #require(
            textView.fallbackEditMenuForTesting(
                suggestedActions: [UIAction(title: "Copy") { _ in }]
            )
        )
        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
    }

    @Test func fallbackEditMenuSynthesizesCopyWhenSuggestedActionsEmpty() throws {
        let textView = FullScreenReviewCommentTextView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 200),
            textContainer: nil
        )
        textView.text = "    indented"
        textView.configureReviewCommentSelection(
            router: ReviewCommentSelectionRouter { _ in },
            sourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "Answer.swift"
            )
        )
        // Include leading indentation in the selection.
        textView.selectedRange = NSRange(location: 0, length: 8)

        let menu = try #require(textView.fallbackEditMenuForTesting(suggestedActions: []))
        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])

        let copyAction = try #require(menu.children.compactMap { $0 as? UIAction }.first { $0.title == "Copy" })
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }
        let button = UIButton(type: .system)
        button.addAction(copyAction, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(UIPasteboard.general.string == "    inde")
    }

    @Test func nativeDelegateMenuSynthesizesCopyWhenSuggestedActionsEmpty() throws {
        let textView = FullScreenReviewCommentTextView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 200),
            textContainer: nil
        )
        textView.text = "    indented"
        textView.configureReviewCommentSelection(
            router: ReviewCommentSelectionRouter { _ in },
            sourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "Answer.swift"
            )
        )
        textView.selectedRange = NSRange(location: 0, length: 8)

        let menu = try #require(buildFullScreenReviewCommentMenu(
            textView: textView,
            range: NSRange(location: 0, length: 8),
            suggestedActions: [],
            router: textView.reviewCommentSelectionRouter,
            sourceContext: textView.reviewCommentSourceContext
        ))
        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])

        let copyAction = try #require(menu.children.compactMap { $0 as? UIAction }.first { $0.title == "Copy" })
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }
        let button = UIButton(type: .system)
        button.addAction(copyAction, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        #expect(UIPasteboard.general.string == "    inde")
    }

    @Test func nativeNilCommentMenuStillSuppressesFallbackForSameSelection() throws {
        let textView = FullScreenReviewCommentTextView()
        textView.text = "let answer = 42"
        textView.configureReviewCommentSelection(router: nil, sourceContext: nil)
        textView.selectedRange = NSRange(location: 0, length: 3)
        #expect(textView.shouldPresentFallbackEditMenuForTesting())

        let menu = try #require(buildFullScreenReviewCommentMenu(
            textView: textView,
            range: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }],
            router: nil,
            sourceContext: nil
        ))
        #expect(timelineActionTitles(in: menu) == ["Copy"])
        #expect(!textView.shouldPresentFallbackEditMenuForTesting())
    }

    private func makeController(
        content: FullScreenCodeContent,
        lineAnchor: SourceLineAnchor? = nil
    ) -> FullScreenCodeViewController {
        let controller = FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSessionId: "session-1",
            reviewCommentSourceLabel: "Full Screen",
            lineAnchor: lineAnchor
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller
    }

    private func makeMarkdownBody(
        content: String,
        captured: @escaping (ReviewCommentSelectionRequest) -> Void
    ) -> NativeFullScreenMarkdownBody {
        NativeFullScreenMarkdownBody(
            content: content,
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { captured($0) },
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenMarkdown,
                filePath: "CHANGELOG.md",
                languageHint: "markdown"
            )
        )
    }

    private func makeMarkdownContentView(
        content: String,
        surface: ReviewCommentSurfaceKind,
        captured: @escaping (ReviewCommentSelectionRequest) -> Void
    ) -> AssistantMarkdownContentView {
        let view = AssistantMarkdownContentView()
        view.apply(configuration: .make(
            content: content,
            isStreaming: false,
            themeID: ThemeID.dark,
            textSelectionEnabled: true,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { captured($0) },
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: surface,
                sourceLabel: "Markdown",
                filePath: "CHANGELOG.md",
                languageHint: "markdown"
            )
        ))
        return view
    }

    private func attachToHost(_ body: UIView) -> UIView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.topAnchor.constraint(equalTo: host.topAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.setNeedsLayout()
        host.layoutIfNeeded()
        return host
    }

    private func dispatchCommentAction(textView: UITextView, selectedText: String) throws {
        let rendered = timelineRenderedText(of: textView) as NSString
        let selectedRange = rendered.range(of: selectedText)
        #expect(selectedRange.location != NSNotFound)
        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: selectedRange,
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))
        let commentAction = try #require(menu.children.first as? UIAction)
        let button = UIButton(type: .system)
        button.addAction(commentAction, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
    }

    private func hasVisibleView(identifier: String, in root: UIView) -> Bool {
        timelineAllViews(in: root).contains {
            $0.accessibilityIdentifier == identifier
                && !$0.isHidden
                && $0.alpha > 0.01
                && $0.window != nil
        }
    }

}
