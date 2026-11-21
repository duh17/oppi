import UIKit

/// A row's menu: Share…, Open, and Copy Path for a file; Open and Copy Path
/// for a folder, because the server has no folder download to share; then
/// Pin or Unpin where the server keeps pins (`FileBrowserPinsSection`). On a
/// window wide enough for panes, Open is Open Here, with Open in New Pane and
/// Open in Pane ▸ beside it (`PaneOpenMenu`).
///
/// Long press and secondary click open the menu; VoiceOver and Full Keyboard
/// Access reach Share…, Copy Path and the pane items as the row's actions
/// (Open is the row's own activation). Every way in runs `performRowAction`,
/// which finds the row by its path when it runs.
extension FileBrowserViewController {
    enum RowAction {
        case share
        case open
        case copyPath

        var title: String {
            switch self {
            case .share: String(localized: "Share\u{2026}")
            case .open: String(localized: "Open")
            case .copyPath: String(localized: "Copy Path")
            }
        }

        var symbol: String {
            switch self {
            case .share: "square.and.arrow.up"
            case .open: "arrow.up.forward.square"
            case .copyPath: "doc.on.doc"
            }
        }

        var identifier: String {
            switch self {
            case .share: "fileBrowser.rowMenu.share"
            case .open: "fileBrowser.rowMenu.open"
            case .copyPath: "fileBrowser.rowMenu.copyPath"
            }
        }
    }

    /// The actions the row at `path` offers, Share first. A folder's path
    /// ends in "/".
    static func rowActions(path: String) -> [RowAction] {
        path.hasSuffix("/") ? [.open, .copyPath] : [.share, .open, .copyPath]
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        if indexPaths.count == 1, let pinId = pinId(at: indexPaths[0]) {
            return pinsSection?.contextMenu(pinId: pinId)
        }
        guard indexPaths.count == 1, let path = rowPath(at: indexPaths[0]), rowMenuEntry(path: path) != nil else {
            return nil
        }
        let panes = paneItems(path: path)
        let pin = pinsSection?.rowMenuElement(rowPath: path)
        let configuration = UIContextMenuConfiguration(identifier: path as NSString, previewProvider: nil) { [weak self] _ in
            let rowItems: [UIMenuElement] = Self.rowActions(path: path).flatMap { action -> [UIMenuElement] in
                // Open Here stands in for Open.
                if action == .open, !panes.isEmpty { return panes.map(\.element) }
                let item = UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { _ in
                    self?.performRowAction(action, path: path)
                }
                item.accessibilityIdentifier = action.identifier
                return [item]
            }
            // Pin or Unpin follows Copy Path.
            return UIMenu(children: rowItems + (pin.map { [$0] } ?? []))
        }
        // Share stays on top when the menu opens above a row low on the screen.
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    func rowAccessibilityActions(path: String) -> [UIAccessibilityCustomAction] {
        var rowActions = Self.rowActions(path: path).filter { $0 != .open }.map { action in
            UIAccessibilityCustomAction(name: action.title) { [weak self] _ in
                self?.performRowAction(action, path: path) ?? false
            }
        }
        if let pin = pinsSection?.rowAccessibilityAction(rowPath: path) { rowActions.append(pin) }
        guard paneContent(path: path) != nil else { return rowActions }
        return rowActions + PaneOpenMenu.accessibilityActions(near: view, includesOpenHere: false) { [weak self] placement in
            self?.openRow(path: path, placement: placement)
        }
    }

    /// Open Here, Open in New Pane and Open in Pane ▸ for the row at `path`;
    /// empty on a compact window or for a row with nothing a pane can show.
    private func paneItems(path: String) -> [PaneMenuItem] {
        guard paneContent(path: path) != nil else { return [] }
        return PaneOpenMenu.items(near: view) { [weak self] placement in
            self?.openRow(path: path, placement: placement)
        }
    }

    /// The row at `path` as a pane's content: a workspace or home file or
    /// folder by its link, as a drag carries it.
    private func paneContent(path: String) -> PaneOpenContent? {
        paneEntry(forRowPath: path).map { PaneOpenContent(entry: $0) }
    }

    private func openRow(path: String, placement: PaneOpenPlacement) {
        guard placement != .here else {
            performRowAction(.open, path: path)
            return
        }
        let content = paneContent(path: path)
        PaneOpenMenu.place(placement, from: view) { content }
    }

    /// False when the row is gone or its file cannot be read now.
    @discardableResult
    func performRowAction(_ action: RowAction, path: String) -> Bool {
        guard let entry = rowMenuEntry(path: path) else { return false }
        switch action {
        case .open:
            entry.open()
        case .copyPath:
            UIPasteboard.general.string = path
            AppHaptics.impact(style: .light, intensity: 0.8)
            TransientConfirmationPill.show(String(localized: "Path Copied"), in: view)
        case .share:
            guard let file = entry.file, let services, services.apiClient != nil else { return false }
            // The file is read the way its viewer reads it: the same origin and checkout.
            let access = FileBrowserViewerFactory
                .configuration(readerRequest(file, context: nil, services: services), chromeMode: .pushed)
                .fileAccess
            let connection = services.connection
            let share = access.remoteFileShare(
                api: { [weak connection] in connection?.apiClient },
                path: file.path,
                fileName: file.name,
                size: file.size
            )
            Task { await FileSharePresenter.share(share, from: self, sourceItem: entry.cell) }
        }
        return true
    }
}
