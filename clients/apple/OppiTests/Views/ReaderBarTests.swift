import Foundation
import Testing
import UIKit
@testable import Oppi

/// The reader's bar over what a file offers: the Reader Bar layout places the
/// buttons, and a turned-off one moves into the … menu, where it does what its
/// button did, above the document's own actions and Customize Bar….
@Suite("Reader bar")
@MainActor
struct ReaderBarTests {
    private func item(_ id: String, onTap: @escaping () -> Void = {}) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: id, primaryAction: UIAction { _ in onTap() })
        item.accessibilityIdentifier = id
        return item
    }

    private func identifiers(_ items: [UIBarButtonItem]) -> [String?] { items.map(\.accessibilityIdentifier) }

    private func flattened(_ elements: [UIMenuElement]) -> [UIMenuElement] {
        elements.flatMap { ($0 as? UIMenu).map { flattened($0.children) } ?? [$0] }
    }

    @Test func theDefaultBarShowsEveryOfferedButtonInItsOrderAndTheMenuHoldsOnlyCustomize() throws {
        let bar = ReaderBar(defaults: try makeSettingsDefaults())
        bar.update(offers: [.share: [item("share")], .copy: [item("copy")], .edit: [item("edit")], .find: [item("find")]], documentActions: [])
        // `rightBarButtonItems` order: the trailing-most first, so Edit, which
        // leads the bar, comes last.
        #expect(identifiers(bar.trailingItems) == ["share", "copy", "find", "edit"])
        let menu = flattened(bar.overflowElements())
        #expect(menu.map { ($0 as? UIAction)?.accessibilityIdentifier } == ["fileViewer.menu.customize"])
    }

    @Test func aTurnedOffButtonRunsFromTheMenuAboveTheDocumentsActionsAndCustomize() throws {
        let defaults = try makeSettingsDefaults()
        AppPreferences.ReaderBar.preference.save(
            ReaderBarLayout.defaultValue.setting(.copy, shown: false).setting(.outline, shown: false),
            in: defaults
        )
        let bar = ReaderBar(defaults: defaults)
        var copied = 0
        let editWithSession = UIAction(title: "Edit with Session") { _ in }
        bar.update(
            offers: [.edit: [item("edit")], .copy: [item("copy") { copied += 1 }], .share: [item("share")]],
            documentActions: [editWithSession]
        )
        #expect(identifiers(bar.trailingItems) == ["share", "edit"])

        // Outline is off too, but this file offers none, so the menu has no Outline.
        let menu = flattened(bar.overflowElements())
        #expect(menu.map { ($0 as? UIAction)?.accessibilityIdentifier ?? ($0 as? UIAction)?.title } == [
            "fileViewer.menu.copy", "Edit with Session", "fileViewer.menu.customize",
        ])
        let copy = try #require(menu.first as? UIAction)
        copy.performWithSender(nil, target: nil)
        #expect(copied == 1, "the menu item does what the turned-off button did")
    }
}
