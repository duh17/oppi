import UIKit

extension FileViewerViewController {
    /// Find and Outline for a bar this viewer feeds (a tree pane): the reader
    /// has no bar of its own there. Outline is left out until the file has headings.
    func readerNavigationItems() -> [ReaderBarAction: [UIBarButtonItem]] {
        var items: [ReaderBarAction: [UIBarButtonItem]] = [:]
        if reader?.supportsFind == true {
            let find = findItem ?? makeFindItem()
            findItem = find
            items[.find] = [find]
        } else {
            findItem = nil
        }
        if reader?.hasOutline == true {
            let outline = outlineItem ?? makeOutlineItem()
            outlineItem = outline
            items[.outline] = [outline]
        } else {
            outlineItem = nil
        }
        return items
    }

    /// Find stays on a narrow bar beside the pencil.
    private func makeFindItem() -> UIBarButtonItem {
        let item = makeItem(symbol: "magnifyingglass", title: String(localized: "Find"), id: "fileViewer.find.button", action: #selector(showFind))
        if #available(iOS 27.0, *) {
            item.visibilityPriority = .high
        }
        return item
    }

    /// Outline is the first to fold into the system's "…" on a narrow bar,
    /// and keeps its identifier and its action there.
    private func makeOutlineItem() -> UIBarButtonItem {
        let item = makeItem(symbol: "list.bullet.indent", title: String(localized: "Outline"), id: "fileViewer.outline.button", action: #selector(showOutline(_:)))
        if #available(iOS 27.0, *) {
            item.visibilityPriority = .low
        }
        let menuAction = UIAction(title: String(localized: "Outline"), image: item.image) { [weak self, weak item] _ in
            guard let item else { return }
            self?.showOutline(item)
        }
        menuAction.accessibilityIdentifier = "fileViewer.outline.button"
        item.menuRepresentation = menuAction
        return item
    }

    private func makeItem(symbol: String, title: String, id: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.title = title
        item.accessibilityLabel = title
        item.accessibilityIdentifier = id
        return item
    }

    @objc private func showFind() {
        reader?.presentFind()
    }

    @objc private func showOutline(_ sender: UIBarButtonItem) {
        reader?.presentOutline(sourceItem: sender)
    }
}
