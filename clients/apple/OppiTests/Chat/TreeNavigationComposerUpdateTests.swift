import Testing
@testable import Oppi

@Suite("Tree navigation composer update")
struct TreeNavigationComposerUpdateTests {
    @Test("clears composer when navigate_tree returns nil editor text")
    func clearsComposerWhenEditorTextMissing() {
        let update = TreeNavigationComposerUpdate.from(editorText: nil, showComposer: true)
        #expect(update.inputText.isEmpty)
        #expect(update.shouldFocusComposer == false)
    }

    @Test("treats whitespace-only editor text as empty")
    func trimsWhitespaceOnlyEditorText() {
        let update = TreeNavigationComposerUpdate.from(editorText: "   \n\t  ", showComposer: false)
        #expect(update.inputText.isEmpty)
        #expect(update.shouldFocusComposer == false)
    }

    @Test("keeps editor text and requests focus when composer is hidden")
    func requestsFocusForNonEmptyTextWhenComposerHidden() {
        let update = TreeNavigationComposerUpdate.from(
            editorText: "  Continue from this branch  ",
            showComposer: false
        )

        #expect(update.inputText == "Continue from this branch")
        #expect(update.shouldFocusComposer == true)
    }

    @Test("keeps editor text without focus request when composer already visible")
    func doesNotRequestFocusWhenComposerVisible() {
        let update = TreeNavigationComposerUpdate.from(
            editorText: "Follow up",
            showComposer: true
        )

        #expect(update.inputText == "Follow up")
        #expect(update.shouldFocusComposer == false)
    }
}
