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
