import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("File browser review comment selection")
struct FileBrowserReviewCommentSelectionTests {

    @Test func routerDispatchesReviewCommentRequestWithSource() throws {
        var captured: ReviewCommentSelectionRequest?
        let router = ReviewCommentSelectionRouter { request in
            captured = request
        }
        let source = ReviewCommentSourceContext(
            sessionId: "session-1",
            surface: .fullScreenCode,
            filePath: "test.swift",
            languageHint: "swift"
        )

        router.dispatch(ReviewCommentSelectionRequest(selectedText: "let x = 42", source: source))

        let request = try #require(captured)
        #expect(request.selectedText == "let x = 42")
        #expect(request.source == source)
    }

    @Test func codeBodyShowsCommentMenuWhenEnvironmentRouterSet() throws {
        let codeBody = NativeFullScreenCodeBody(
            content: "let answer = 42",
            language: "swift",
            startLine: 1,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: true,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSourceContext: ReviewCommentSourceContext(
                sessionId: "session-1",
                surface: .fullScreenCode,
                filePath: "test.swift",
                languageHint: "swift"
            )
        )
        codeBody.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        codeBody.setNeedsLayout()
        codeBody.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: codeBody).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        let menu = try #require(textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
    }

    @Test func codeBodyNoCommentMenuWhenRouterNil() throws {
        let codeBody = NativeFullScreenCodeBody(
            content: "let answer = 42",
            language: "swift",
            startLine: 1,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: true,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        codeBody.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        codeBody.setNeedsLayout()
        codeBody.layoutIfNeeded()

        let textView = try #require(timelineAllTextViews(in: codeBody).first {
            timelineRenderedText(of: $0).contains("let answer = 42")
        })

        let menu = textView.delegate?.textView?(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 3),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        )

        #expect(menu == nil)
    }
}
