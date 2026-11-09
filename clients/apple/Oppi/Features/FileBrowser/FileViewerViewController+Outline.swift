import UIKit

extension FileViewerViewController {
    /// Find and Outline for a bar this viewer feeds (a tree pane): the reader
    /// has no bar of its own there. Outline is left out until the file has headings.
    func readerNavigationItems() -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        if reader?.supportsFind == true {
            let find = findItem ?? makeItem(symbol: "magnifyingglass", title: String(localized: "Find"), id: "fileViewer.find.button", action: #selector(showFind))
            findItem = find
            items.append(find)
        } else {
            findItem = nil
        }
        if reader?.hasOutline == true {
            let outline = outlineItem ?? makeItem(symbol: "list.bullet.indent", title: String(localized: "Outline"), id: "fileViewer.outline.button", action: #selector(showOutline(_:)))
            outlineItem = outline
            items.append(outline)
        } else {
            outlineItem = nil
        }
        return items
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
