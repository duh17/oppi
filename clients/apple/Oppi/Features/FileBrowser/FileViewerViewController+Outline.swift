import UIKit

extension FileViewerViewController {
    /// The Outline entry for a bar this viewer feeds (a tree pane): the reader
    /// has no bar of its own there. Empty until the file has headings.
    func outlineBarItems() -> [UIBarButtonItem] {
        guard reader?.hasOutline == true else {
            outlineItem = nil
            return []
        }
        if let outlineItem { return [outlineItem] }
        let item = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet.indent"),
            style: .plain,
            target: self,
            action: #selector(showOutline(_:))
        )
        item.title = String(localized: "Outline")
        item.accessibilityLabel = item.title
        item.accessibilityIdentifier = "fileViewer.outline.button"
        outlineItem = item
        return [item]
    }

    @objc private func showOutline(_ sender: UIBarButtonItem) {
        reader?.presentOutline(sourceItem: sender)
    }
}
