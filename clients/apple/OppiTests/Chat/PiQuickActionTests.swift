import Foundation
import Testing
@testable import Oppi

@Suite("PiQuickAction")
@MainActor
struct PiQuickActionTests {

    // MARK: - Model

    @Test func builtInDefaultsContainSixActions() {
        #expect(PiQuickAction.builtInDefaults.count == 6)
    }

    @Test func builtInDefaultsHaveStableIds() {
        let ids = PiQuickAction.builtInDefaults.map(\.id)
        let unique = Set(ids)
        #expect(unique.count == ids.count)
    }

    @Test func isRawInsertTrueForEmptyPrefix() {
        let action = PiQuickAction(
            id: .init(),
            title: "Test",
            systemImage: "sparkles",
            promptPrefix: "",
            behavior: .currentSession,
            sortOrder: 0
        )
        #expect(action.isRawInsert == true)
    }

    @Test func isRawInsertFalseForNonEmptyPrefix() {
        let action = PiQuickAction(
            id: .init(),
            title: "Test",
            systemImage: "sparkles",
            promptPrefix: "Review this:",
            behavior: .currentSession,
            sortOrder: 0
        )
        #expect(action.isRawInsert == false)
    }

    // MARK: - Store

    @Test func storeAddIncrementsSortOrder() {
        let store = PiQuickActionStore(actions: [])
        let action = PiQuickAction(
            id: .init(),
            title: "Custom",
            systemImage: "bolt",
            promptPrefix: "Do the thing:",
            behavior: .currentSession,
            sortOrder: 0
        )
        store.add(action)
        #expect(store.actions.count == 1)
        #expect(store.actions[0].sortOrder == 0)

        let second = PiQuickAction(
            id: .init(),
            title: "Second",
            systemImage: "ant",
            promptPrefix: "",
            behavior: .newSession,
            sortOrder: 0
        )
        store.add(second)
        #expect(store.actions.count == 2)
        #expect(store.actions[1].sortOrder == 1)
    }

    @Test func storeDeleteRemovesAction() {
        let store = PiQuickActionStore(actions: PiQuickAction.builtInDefaults)
        let initialCount = store.actions.count
        store.delete(at: IndexSet(integer: 0))
        #expect(store.actions.count == initialCount - 1)
    }

    @Test func storeUpdateModifiesExistingAction() {
        let store = PiQuickActionStore(actions: PiQuickAction.builtInDefaults)
        var modified = store.actions[0]
        modified.title = "Clarify"
        modified.promptPrefix = "Clarify this:"
        store.update(modified)
        #expect(store.actions[0].title == "Clarify")
        #expect(store.actions[0].promptPrefix == "Clarify this:")
    }

    @Test func storeMoveReordersActions() {
        let store = PiQuickActionStore(actions: PiQuickAction.builtInDefaults)
        let firstTitle = store.actions[0].title
        let secondTitle = store.actions[1].title
        store.move(from: IndexSet(integer: 0), to: 2)
        #expect(store.actions[0].title == secondTitle)
        #expect(store.actions[1].title == firstTitle)
    }

    @Test func storeResetToDefaultsRestoresBuiltIns() {
        let store = PiQuickActionStore(actions: [])
        store.resetToDefaults()
        #expect(store.actions.count == PiQuickAction.builtInDefaults.count)
        #expect(store.actions.map(\.title) == PiQuickAction.builtInDefaults.map(\.title))
    }

    // MARK: - Prompt formatting with custom action

    @Test func customActionPrefixUsedInDraft() {
        let action = PiQuickAction(
            id: .init(),
            title: "Review Security",
            systemImage: "checkmark.shield",
            promptPrefix: "Review this code for security issues:",
            behavior: .currentSession,
            sortOrder: 0
        )
        let request = SelectedTextPiRequest(
            action: action,
            selectedText: "let password = \"hunter2\"",
            source: .init(sessionId: "s-1", surface: .assistantCodeBlock, languageHint: "swift")
        )
        let result = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        #expect(result.hasPrefix("Review this code for security issues:"))
        #expect(result.contains("let password = \"hunter2\""))
    }

    @Test func rawInsertActionOmitsPrefix() {
        let action = PiQuickAction(
            id: .init(),
            title: "Paste",
            systemImage: "doc.on.doc",
            promptPrefix: "",
            behavior: .currentSession,
            sortOrder: 0
        )
        let request = SelectedTextPiRequest(
            action: action,
            selectedText: "some text",
            source: .init(sessionId: "s-1", surface: .assistantProse)
        )
        let result = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        #expect(result == "> some text")
    }

    // MARK: - Backward compat shim

    @Test func oldEnumMapsToCorrectBuiltInAction() {
        let explain = SelectedTextPiActionKind.explain.builtInAction
        #expect(explain.title == "Explain")
        #expect(explain.promptPrefix == "Explain this:")

        let addToPrompt = SelectedTextPiActionKind.addToPrompt.builtInAction
        #expect(addToPrompt.isRawInsert == true)
    }

    @Test func requestInitWithOldEnumProducesCorrectDraft() {
        let request = SelectedTextPiRequest(
            action: .fix,
            selectedText: "broken code",
            source: .init(sessionId: "s-1", surface: .assistantProse)
        )
        let result = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
        #expect(result.hasPrefix("Fix this:"))
    }
}
