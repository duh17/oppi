import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("File browser π action routing")
struct FileBrowserPiActionTests {

    // MARK: - Router dispatch

    @Test func routerSetsDraftAndShowsQuickSession() {
        let nav = AppNavigation()
        nav.showOnboarding = false

        let router = SelectedTextPiActionRouter { request in
            nav.pendingQuickSessionDraft = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            nav.showQuickSession = true
        }

        let request = SelectedTextPiRequest(
            action: .explain,
            selectedText: "let x = 42",
            source: SelectedTextSourceContext(
                sessionId: "",
                surface: .fullScreenCode,
                filePath: "test.swift",
                languageHint: "swift"
            )
        )

        router.dispatch(request)

        #expect(nav.showQuickSession == true)
        #expect(nav.pendingQuickSessionDraft != nil)
        #expect(nav.pendingQuickSessionDraft!.contains("Explain this:"))
        #expect(nav.pendingQuickSessionDraft!.contains("let x = 42"))
    }

    @Test func addToPromptSetsCodeBlockDraft() {
        let nav = AppNavigation()
        let router = SelectedTextPiActionRouter { request in
            nav.pendingQuickSessionDraft = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            nav.showQuickSession = true
        }

        let request = SelectedTextPiRequest(
            action: .addToPrompt,
            selectedText: "func hello() {}",
            source: SelectedTextSourceContext(
                sessionId: "",
                surface: .fullScreenCode,
                filePath: "hello.swift",
                languageHint: "swift"
            )
        )

        router.dispatch(request)

        #expect(nav.pendingQuickSessionDraft == "```swift\nfunc hello() {}\n```")
    }

    @Test func markdownSurfaceFormatsAsQuote() {
        let nav = AppNavigation()
        let router = SelectedTextPiActionRouter { request in
            nav.pendingQuickSessionDraft = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            nav.showQuickSession = true
        }

        let request = SelectedTextPiRequest(
            action: .addToPrompt,
            selectedText: "Some markdown prose",
            source: SelectedTextSourceContext(
                sessionId: "",
                surface: .fullScreenMarkdown,
                filePath: "README.md"
            )
        )

        router.dispatch(request)

        #expect(nav.pendingQuickSessionDraft == "> Some markdown prose")
    }

    // MARK: - NativeCodeBodyView π menu via environment

    @Test func codeBodyShowsPiMenuWhenEnvironmentRouterSet() throws {
        let codeBody = NativeFullScreenCodeBody(
            content: "let answer = 42",
            language: "swift",
            startLine: 1,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: true,
            selectedTextPiRouter: SelectedTextPiActionRouter { _ in },
            selectedTextSourceContext: SelectedTextSourceContext(
                sessionId: "",
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

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
        #expect(piMenu.children.count == SelectedTextPiActionKind.allCases.count)
    }

    @Test func codeBodyNoPiMenuWhenRouterNil() throws {
        let codeBody = NativeFullScreenCodeBody(
            content: "let answer = 42",
            language: "swift",
            startLine: 1,
            palette: ThemeRuntimeState.currentThemeID().palette,
            alwaysBounceVertical: true,
            selectedTextPiRouter: nil,
            selectedTextSourceContext: nil
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

    // MARK: - Prompt formatting includes file metadata

    @Test func draftIncludesFilePathMetadata() {
        let nav = AppNavigation()
        let router = SelectedTextPiActionRouter { request in
            nav.pendingQuickSessionDraft = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            nav.showQuickSession = true
        }

        let request = SelectedTextPiRequest(
            action: .explain,
            selectedText: "complex code",
            source: SelectedTextSourceContext(
                sessionId: "",
                surface: .fullScreenCode,
                filePath: "src/utils/parser.ts",
                languageHint: "typescript"
            )
        )

        router.dispatch(request)

        let draft = nav.pendingQuickSessionDraft!
        #expect(draft.contains("File: src/utils/parser.ts"))
        #expect(draft.contains("Language: typescript"))
    }
}
