import UIKit

/// Find and Outline: the bar items a file reader shows, and what they do. The
/// body owns both (`ReaderBody`); the reader only places the buttons.
extension FullScreenCodeViewController {
    /// Find and Outline for the reader's bar, or the embedding screen's
    /// (`barOffers`). Outline joins only while the open file has headings.
    func makeReaderNavigationItems(palette: ThemePalette) -> [ReaderBarAction: [UIBarButtonItem]] {
        var items: [ReaderBarAction: [UIBarButtonItem]] = [:]
        if installedBodyView?.supportsFind == true {
            let find = railItem(symbol: "magnifyingglass", title: String(localized: "Find"), action: #selector(showFind))
            find.accessibilityIdentifier = "fileViewer.find.button"
            find.tintColor = palette.ui.fgDim
            items[.find] = [find]
        }
        outlineBarItem = nil
        if installedBodyView?.hasOutline == true {
            let outline = railItem(symbol: "list.bullet.indent", title: String(localized: "Outline"), action: #selector(showOutline))
            outline.accessibilityIdentifier = "fileViewer.outline.button"
            outline.tintColor = palette.ui.fgDim
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
    /// floating controls. Which ones a narrow bar keeps is the Reader Bar
    /// order's call (`ReaderBar.trailingItems`).
    func railItem(symbol: String, title: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.title = title
        item.accessibilityLabel = title
        return item
    }

    @objc private func showFind() {
        installedBodyView?.presentFind()
    }

    @objc private func showOutline() {
        guard let item = outlineBarItem else { return }
        installedBodyView?.presentOutline(from: contentHostController ?? self, sourceItem: item)
    }
}
