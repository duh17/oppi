import Testing
@testable import Oppi

@Suite("Tree navigation view update")
struct TreeNavigationViewUpdateTests {
    @Test("keeps the selected tree node as the scroll target")
    func keepsSelectedTreeNodeAsScrollTarget() {
        let update = TreeNavigationViewUpdate.from(
            targetId: "entry-42",
            editorText: nil,
            showComposer: true
        )

        #expect(update.scrollTargetID == "entry-42")
        #expect(update.inputText.isEmpty)
        #expect(update.shouldFocusComposer == false)
    }

    @Test("treats whitespace-only editor text as empty")
    func trimsWhitespaceOnlyEditorText() {
        let update = TreeNavigationViewUpdate.from(
            targetId: "entry-42",
            editorText: "   \n\t  ",
            showComposer: false
        )

        #expect(update.scrollTargetID == "entry-42")
        #expect(update.inputText.isEmpty)
        #expect(update.shouldFocusComposer == false)
    }

    @Test("keeps editor text and requests focus when composer is hidden")
    func requestsFocusForNonEmptyTextWhenComposerHidden() {
        let update = TreeNavigationViewUpdate.from(
            targetId: "entry-42",
            editorText: "  Continue from this branch  ",
            showComposer: false
        )

        #expect(update.scrollTargetID == "entry-42")
        #expect(update.inputText == "Continue from this branch")
        #expect(update.shouldFocusComposer == true)
    }

    @Test("keeps editor text without focus request when composer already visible")
    func doesNotRequestFocusWhenComposerVisible() {
        let update = TreeNavigationViewUpdate.from(
            targetId: "entry-42",
            editorText: "Follow up",
            showComposer: true
        )

        #expect(update.scrollTargetID == "entry-42")
        #expect(update.inputText == "Follow up")
        #expect(update.shouldFocusComposer == false)
    }
}
