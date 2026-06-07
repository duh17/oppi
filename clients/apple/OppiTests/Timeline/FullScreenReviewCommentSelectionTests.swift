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

    @Test func codeBodyInstallsResponderMenuFallback() throws {
        let controller = makeController(
            content: .code(content: "let answer = 42", language: "swift", filePath: "Answer.swift", startLine: 1)
        )
        let textView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        } as? FullScreenReviewCommentTextView)

        #expect(textView.reviewCommentSelectionRouter != nil)
        #expect(textView.reviewCommentSourceContext?.surface == .fullScreenCode)
    }

    @Test func selectedCodeShowsCommentBarAndOpensInlineComposer() async throws {
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

        let barAppeared = await waitForMainActorCondition {
            self.hasVisibleView(identifier: "review-comment.selection-bar", in: controller.view)
        }
        #expect(barAppeared, "Selecting code in full-screen read mode should show the comment bar")

        let commentBar = try #require(timelineAllViews(in: controller.view).first {
            $0.accessibilityIdentifier == "review-comment.selection-bar"
        } as? UIControl)
        commentBar.sendActions(for: .touchUpInside)

        let composerAppeared = await waitForMainActorCondition {
            self.hasVisibleView(identifier: "review-comment.inline-composer", in: controller.view)
        }
        #expect(composerAppeared, "Tapping the comment bar should open the inline comment composer")
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

    @Test func fullScreenMarkdownUsesRichRenderingForLargeDocuments() throws {
        let content = [
            "# Heading",
            "",
            "**Bold intro** with `inline code`.",
            "",
            String(repeating: "Body paragraph with enough text to cross the old fallback threshold.\n\n", count: 320),
        ].joined(separator: "\n")
        #expect(content.count > AssistantMarkdownContentView.Configuration.defaultPlainTextFallbackThreshold)

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

        let markdownView = try #require(timelineFirstView(ofType: AssistantMarkdownContentView.self, in: controller.view))
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

    @Test func diffFullScreenDoesNotSupportWrapText() async throws {
        FullScreenReaderPreferencesStore.shared.setPreferences(
            FullScreenReaderPreferences(wrapsText: true),
            for: .diff
        )
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff) }
        let longLine = "let message = \"" + String(repeating: "wrap-me-", count: 24) + "\""
        let controller = makeController(
            content: .diff(
                oldText: "",
                newText: longLine,
                filePath: "LongLine.swift",
                precomputedLines: [DiffLine(kind: .added, text: longLine)]
            )
        )
        let diffView = try #require(timelineAllTextViews(in: controller.view).first {
            timelineRenderedText(of: $0).contains("wrap-me-")
        })

        #expect(!FullScreenReaderContentFamily.diff.supportsWrapping)
        #expect(FullScreenReaderPreferencesStore.shared.preferences(for: .diff).wrapsText == false)
        let stayedUnwrapped = await waitForMainActorCondition {
            diffView.textContainer.lineBreakMode == .byClipping
                && firstParagraphLineBreakMode(in: diffView) == .byClipping
        }
        #expect(stayedUnwrapped)
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

    @Test func sourceBodyInstallsResponderMenuFallback() throws {
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
        let menu = textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        )
        #expect(menu == nil)
    }

    private func makeController(content: FullScreenCodeContent) -> FullScreenCodeViewController {
        let controller = FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSessionId: "session-1",
            reviewCommentSourceLabel: "Full Screen"
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller
    }

    private func firstParagraphLineBreakMode(in textView: UITextView) -> NSLineBreakMode? {
        let attributedText = textView.attributedText ?? NSAttributedString()
        guard attributedText.length > 0 else { return nil }
        var result: NSLineBreakMode?
        attributedText.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, _, stop in
            if let style = value as? NSParagraphStyle {
                result = style.lineBreakMode
                stop.pointee = true
            }
        }
        return result
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
