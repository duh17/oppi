import UIKit

/// The bar a file viewer asks for: its title, the reader actions it offers,
/// and whether the editor owns it. The person's Reader Bar layout places the
/// actions (`ReaderBar`); the viewer never orders buttons itself. A viewer at
/// the top of a stack applies it to its own navigation item; a screen that
/// embeds one (a route, a review, a file list) reads it in
/// `updateProperties()` and shows the items in its own bar.
@MainActor @Observable
final class FileViewerBar {
    var title = ""
    /// In `rightBarButtonItems` order: the first is the trailing-most. The
    /// editor's status, Preview, and Done while it is open; else the offered
    /// actions the layout shows.
    private(set) var trailingItems: [UIBarButtonItem] = []
    /// The … menu for the system overflow (`additionalOverflowItems`): the
    /// turned-off actions, the document's own, and Customize Bar…. Nil while
    /// the editor owns the bar or the viewer offers nothing.
    private(set) var overflow: UIDeferredMenuElement?
    /// The text editor is open; its status, Preview, and Done own the bar.
    private(set) var isEditing = false

    @ObservationIgnored let reader = ReaderBar()
    @ObservationIgnored private var editorItems: [UIBarButtonItem] = []

    init() {
        reader.onLayoutChange = { [weak self] in self?.layOut() }
    }

    /// What the viewer offers now. `offers` are the reader's actions, each
    /// leading to trailing; `editorItems` own the bar while `isEditing`.
    func show(
        offers: [ReaderBarAction: [UIBarButtonItem]],
        documentActions: [UIMenuElement],
        editorItems: [UIBarButtonItem],
        isEditing: Bool
    ) {
        let readerChanged = reader.update(offers: offers, documentActions: documentActions)
        guard readerChanged || isEditing != self.isEditing || !editorItems.elementsEqual(self.editorItems, by: ===) else {
            return
        }
        self.editorItems = editorItems
        if self.isEditing != isEditing { self.isEditing = isEditing }
        layOut()
    }

    private func layOut() {
        let items = isEditing ? editorItems : reader.trailingItems
        if !trailingItems.elementsEqual(items, by: ===) { trailingItems = items }
        let offersAnything = !reader.offers.isEmpty || !reader.documentActions.isEmpty
        let menu = isEditing || !offersAnything ? nil : reader.overflow
        if overflow !== menu { overflow = menu }
    }

    /// Shows the title, items, and … menu on `navigationItem`. Assigns only
    /// what changed, so open menus and glass groups survive.
    func apply(to navigationItem: UINavigationItem) {
        if navigationItem.title != title {
            navigationItem.title = title
        }
        if !(navigationItem.rightBarButtonItems ?? []).elementsEqual(trailingItems, by: ===) {
            navigationItem.rightBarButtonItems = trailingItems
        }
        if navigationItem.additionalOverflowItems !== overflow {
            navigationItem.additionalOverflowItems = overflow
        }
    }
}
