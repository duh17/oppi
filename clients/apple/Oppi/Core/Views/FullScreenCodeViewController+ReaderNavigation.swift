import UIKit

/// Find and Outline: the bar items a file reader shows, and what they do. The
/// body owns both (`ReaderBody`); the reader only places the buttons.
extension FullScreenCodeViewController {
    /// Find and Outline for the reader's own bar. Outline joins only while the
    /// open file has headings.
    func makeReaderNavigationItems(palette: ThemePalette) -> [ReaderBarAction: [UIBarButtonItem]] {
        var items: [ReaderBarAction: [UIBarButtonItem]] = [:]
        if supportsFind {
            let find = railItem(symbol: "magnifyingglass", title: String(localized: "Find"), action: #selector(showFind))
            find.accessibilityIdentifier = "fileViewer.find.button"
            find.tintColor = palette.ui.fgDim
            items[.find] = [find]
        }
        outlineBarItem = nil
        if hasOutline {
            let outline = railItem(symbol: "list.bullet.indent", title: String(localized: "Outline"), action: #selector(showOutline))
            outline.accessibilityIdentifier = "fileViewer.outline.button"
            outline.tintColor = palette.ui.fgDim
            // On a narrow bar Outline is the first to fold into the system's
            // "…" (it still opens from there), so Find and the pencil stay one tap.
            if #available(iOS 27.0, *) {
                outline.visibilityPriority = .low
            }
            // Folded into the "…", Outline keeps its identifier and its action.
            let menuAction = UIAction(title: String(localized: "Outline"), image: outline.image) { [weak self] _ in
                self?.showOutline()
            }
            menuAction.accessibilityIdentifier = "fileViewer.outline.button"
            outline.menuRepresentation = menuAction
            outlineBarItem = outline
            items[.outline] = [outline]
        }
        return items
    }

    /// A reader control as a bar item: Find, Outline, and the side rail's
    /// floating controls.
    func railItem(symbol: String, title: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.title = title
        item.accessibilityLabel = title
        if #available(iOS 27.0, *) {
            item.visibilityPriority = .high
        }
        return item
    }

    /// Whether the open file offers Find.
    var supportsFind: Bool { installedBodyView?.supportsFind == true }

    /// Whether the open file has headings to list.
    var hasOutline: Bool { installedBodyView?.hasOutline == true }

    func presentFind() {
        installedBodyView?.presentFind()
    }

    func presentOutline(sourceItem: UIBarButtonItem) {
        installedBodyView?.presentOutline(from: contentHostController ?? self, sourceItem: sourceItem)
    }

    @objc private func showFind() {
        presentFind()
    }

    @objc private func showOutline() {
        guard let item = outlineBarItem else { return }
        presentOutline(sourceItem: item)
    }
}
