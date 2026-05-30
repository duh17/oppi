import Foundation
import Testing
@testable import Oppi

@Suite("QuickCommentTemplate")
@MainActor
struct QuickCommentTemplateTests {

    @Test func builtInDefaultsContainFourQuickComments() {
        #expect(QuickCommentTemplate.builtInDefaults.count == 4)
        #expect(QuickCommentTemplate.builtInDefaults.allSatisfy { $0.isQuickCommentTemplate })
    }

    @Test func quickCommentTemplatesFilterEmptyTemplatesAndSort() {
        let emptyLegacy = QuickCommentTemplate(
            id: UUID(),
            title: "Empty legacy template",
            systemImage: "plus.bubble",
            promptPrefix: "",
            sortOrder: 0
        )
        let custom = QuickCommentTemplate(
            id: UUID(),
            title: "Ship it",
            systemImage: "paperplane",
            promptPrefix: "Ship this.",
            sortOrder: 10
        )
        let templates = QuickCommentTemplate.quickCommentTemplates([custom, emptyLegacy])
        #expect(templates == [custom])
    }

    @Test func builtInDefaultsHaveStableIds() {
        let ids = QuickCommentTemplate.builtInDefaults.map(\.id)
        let unique = Set(ids)
        #expect(unique.count == ids.count)
    }

    @Test func emptyPrefixIsNotAUsableTemplate() {
        let template = QuickCommentTemplate(
            id: .init(),
            title: "Empty",
            systemImage: "sparkles",
            promptPrefix: "",
            sortOrder: 0
        )
        #expect(template.isQuickCommentTemplate == false)
    }

    @Test func nonEmptyPrefixIsAUsableTemplate() {
        let template = QuickCommentTemplate(
            id: .init(),
            title: "Review",
            systemImage: "sparkles",
            promptPrefix: "Review this.",
            sortOrder: 0
        )
        #expect(template.isQuickCommentTemplate == true)
    }

    // MARK: - Store

    @Test func storeAddIncrementsSortOrder() {
        let store = QuickCommentTemplateStore(templates: [])
        let first = QuickCommentTemplate(
            id: .init(),
            title: "Custom",
            systemImage: "bolt",
            promptPrefix: "Do the thing.",
            sortOrder: 0
        )
        store.add(first)
        #expect(store.templates.count == 1)
        #expect(store.templates[0].sortOrder == 0)

        let second = QuickCommentTemplate(
            id: .init(),
            title: "Second",
            systemImage: "text.bubble",
            promptPrefix: "Check this.",
            sortOrder: 0
        )
        store.add(second)
        #expect(store.templates.count == 2)
        #expect(store.templates[1].sortOrder == 1)
    }

    @Test func storeInitializerDropsEmptyLegacyTemplates() {
        let emptyLegacy = QuickCommentTemplate(
            id: .init(),
            title: "Add to Prompt",
            systemImage: "plus.bubble",
            promptPrefix: "",
            sortOrder: 0
        )
        let store = QuickCommentTemplateStore(templates: [emptyLegacy])
        #expect(store.templates.isEmpty)
    }

    @Test func storeDeleteRemovesTemplate() {
        let store = QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults)
        let initialCount = store.templates.count
        store.delete(at: IndexSet(integer: 0))
        #expect(store.templates.count == initialCount - 1)
    }

    @Test func storeUpdateModifiesExistingTemplate() {
        let store = QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults)
        var modified = store.templates[0]
        modified.title = "Clarify"
        modified.promptPrefix = "Clarify this."
        store.update(modified)
        #expect(store.templates[0].title == "Clarify")
        #expect(store.templates[0].promptPrefix == "Clarify this.")
    }

    @Test func storeMoveReordersTemplates() {
        let store = QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults)
        let firstTitle = store.templates[0].title
        let secondTitle = store.templates[1].title
        store.move(from: IndexSet(integer: 0), to: 2)
        #expect(store.templates[0].title == secondTitle)
        #expect(store.templates[1].title == firstTitle)
    }

    @Test func storeResetToDefaultsRestoresBuiltIns() {
        let store = QuickCommentTemplateStore(templates: [])
        store.resetToDefaults()
        #expect(store.templates.count == QuickCommentTemplate.builtInDefaults.count)
        #expect(store.templates.map(\.title) == QuickCommentTemplate.builtInDefaults.map(\.title))
    }
}
