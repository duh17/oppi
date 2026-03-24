import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Full-screen selected text π actions")
struct FullScreenSelectedTextTests {
    @Test func codeBodyPrependsPiSubmenu() throws {
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

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
    }

    @Test func diffBodyPrependsPiSubmenu() throws {
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
            timelineRenderedText(of: $0).contains("let value = 2")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
    }

    @Test func markdownBodyPrependsPiSubmenu() throws {
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

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
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

    @Test func thinkingBodyPrependsPiSubmenu() throws {
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

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
    }

    @Test func terminalBodyPrependsPiSubmenu() throws {
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

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
    }

    @Test func sourceBodyPrependsPiSubmenu() throws {
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

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
    }

    @Test func liveSourceBodyPrependsPiSubmenu() throws {
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

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
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
        let titleView = try #require(contentController.navigationItem.titleView)
        let copyButton = try #require(contentController.navigationItem.rightBarButtonItems?.first)

        stream.update(
            text: "streaming source\nnext chunk",
            filePath: "Draft.swift",
            isDone: false,
            finalContent: nil
        )

        #expect(contentController.navigationItem.titleView === titleView)
        #expect(contentController.navigationItem.rightBarButtonItems?.first === copyButton)
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
            selectedTextPiRouter: SelectedTextPiActionRouter { _ in },
            selectedTextSessionId: "session-1",
            selectedTextSourceLabel: "Full Screen"
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller
    }
}
