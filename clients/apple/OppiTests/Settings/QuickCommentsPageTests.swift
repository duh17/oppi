import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > Chat > Quick Comments over a real store: what a drag, a swipe,
/// the editor's Save, and Reset to Defaults do to the templates.
@Suite("Settings Quick Comments page", .serialized)
@MainActor
struct QuickCommentsPageTests {
    private typealias Item = QuickCommentsViewController.Item

    private func makeStore(_ titles: [String]) -> QuickCommentTemplateStore {
        QuickCommentTemplateStore(templates: titles.enumerated().map { index, title in
            QuickCommentTemplate(id: UUID(), title: title, systemImage: "bolt", promptPrefix: "\(title) this.", sortOrder: index)
        })
    }

    private func mount(_ store: QuickCommentTemplateStore) throws -> (page: QuickCommentsViewController, window: UIWindow) {
        let page = QuickCommentsViewController(root: makeTestAppRoot(), store: store)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1000)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        return (page, window)
    }

    @Test("One drag is one move for the store: down lands after the row it passed, up before")
    func dragBecomesOneStoreMove() {
        let ids = (0..<4).map { _ in UUID() }
        func slot(_ id: UUID) -> ListSlot<QuickCommentsViewController.Section, Item> { .item(.template(id)) }
        func move(_ from: [UUID], _ to: [UUID]) -> (from: Int, to: Int)? {
            QuickCommentsViewController.move(of: to.map(slot).difference(from: from.map(slot)))
        }
        // Row 0 dragged below row 2.
        let down = move(ids, [ids[1], ids[2], ids[0], ids[3]])
        #expect(down?.from == 0 && down?.to == 3)
        // Row 3 dragged to the top.
        let up = move(ids, [ids[3], ids[0], ids[1], ids[2]])
        #expect(up?.from == 3 && up?.to == 0)
        #expect(move(ids, ids) == nil)

        // The store applies it the way SwiftUI's onMove did.
        let store = makeStore(["a", "b", "c", "d"])
        let order = store.templates.map(\.id)
        store.move(from: IndexSet(integer: 0), to: 3)
        #expect(store.templates.map(\.id) == [order[1], order[2], order[0], order[3]])
        #expect(store.templates.map(\.sortOrder) == [0, 1, 2, 3])
    }

    @Test("A template row opens its editor by its button, titled by its name and showing its text")
    func rowsAreButtonsWithTheirText() async throws {
        let store = makeStore(["Explain", "Fix"])
        let (page, window) = try mount(store)
        defer { window.isHidden = true; window.rootViewController = nil }
        let id = try #require(store.templates.first?.id)
        #expect(await waitForMainActorCondition {
            page.view.layoutIfNeeded()
            return page.indexPath(for: .template(id)).flatMap { page.collectionView.cellForItem(at: $0) } != nil
        })
        let cell = try #require(page.indexPath(for: .template(id)).flatMap { page.collectionView.cellForItem(at: $0) })
        let button = try #require(cell.accessibilityElements?.first as? UIButton)
        #expect(button.accessibilityLabel == "Explain")
        #expect(button.accessibilityValue == "Explain this.")
        #expect(button.accessibilityIdentifier == "settings.quickComments.template.\(id.uuidString)")
    }

    @Test("Swiping a row's Delete removes it and renumbers the rest")
    func swipeDeletes() async throws {
        let store = makeStore(["a", "b", "c"])
        let (page, window) = try mount(store)
        defer { window.isHidden = true; window.rootViewController = nil }
        let middle = store.templates[1].id
        let actions = try #require(page.trailingSwipeActions(for: .template(middle)))
        let delete = try #require(actions.actions.first)
        #expect(delete.title == "Delete")
        delete.handler(delete, UIView()) { _ in }
        #expect(store.templates.map(\.title) == ["a", "c"])
        #expect(store.templates.map(\.sortOrder) == [0, 1])
        #expect(page.trailingSwipeActions(for: .add) == nil)
    }

    @Test("The editor saves trimmed text, refuses a blank title or text, and a new template starts blank")
    func editorValidatesAndTrims() throws {
        let blank = QuickCommentTemplate(id: UUID(), title: "", systemImage: "text.bubble", promptPrefix: "", sortOrder: 3)
        var saved: [QuickCommentTemplate] = []
        let editor = QuickCommentEditorViewController(template: blank, isNew: true) { saved.append($0) }
        #expect(editor.title == "New Quick Comment")
        #expect(!editor.canSave)

        editor.setTitle("  Explain  ")
        #expect(!editor.canSave, "text is still blank")
        editor.setText("   ")
        #expect(!editor.canSave, "whitespace is blank")
        editor.save()
        #expect(saved.isEmpty)

        editor.setText("  Explain this.\n")
        editor.setSymbol("lightbulb")
        #expect(editor.canSave)
        let template = editor.finishedTemplate()
        #expect(template.title == "Explain")
        #expect(template.promptPrefix == "Explain this.")
        #expect(template.systemImage == "lightbulb")
        #expect(template.id == blank.id)
        #expect(template.sortOrder == 3)
    }

    @Test("Editing keeps the template's id and order")
    func editingKeepsIdentity() {
        let existing = QuickCommentTemplate.builtInDefaults[1]
        let editor = QuickCommentEditorViewController(template: existing, isNew: false) { _ in }
        #expect(editor.title == "Edit Quick Comment")
        #expect(editor.canSave)
        #expect(editor.finishedTemplate().id == existing.id)
        #expect(editor.finishedTemplate().sortOrder == existing.sortOrder)
    }

    @Test("Every icon the picker offers has a word, and an unknown one has none")
    func iconWords() {
        #expect(QuickCommentSymbols.label(for: "lightbulb") == "Idea")
        #expect(QuickCommentSymbols.label(for: "not.a.symbol") == nil)
        #expect(Set(QuickCommentSymbols.all.map(\.symbol)).count == QuickCommentSymbols.all.count)
    }
}
