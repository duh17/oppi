import UIKit

/// Find and Outline: the bar items a file reader shows, and what they do. The
/// body owns both (`ReaderBody`); the reader only places the buttons.
extension FullScreenCodeViewController {
    /// The items for the reader's own bar, Find first. Outline joins only
    /// while the open file has headings.
    func makeReaderNavigationItems(palette: ThemePalette) -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        if supportsFind {
            let find = railItem(symbol: "magnifyingglass", title: String(localized: "Find"), action: #selector(showFind))
            find.accessibilityIdentifier = "fileViewer.find.button"
            find.tintColor = palette.ui.fgDim
            items.append(find)
        }
        outlineBarItem = nil
        if hasOutline {
            let outline = railItem(symbol: "list.bullet.indent", title: String(localized: "Outline"), action: #selector(showOutline))
            outline.accessibilityIdentifier = "fileViewer.outline.button"
            outline.tintColor = palette.ui.fgDim
            outlineBarItem = outline
            items.append(outline)
        }
        return items
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
