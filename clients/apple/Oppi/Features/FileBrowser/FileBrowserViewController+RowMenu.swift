import UIKit

/// A row's menu: Share…, Open, and Copy Path for a file; Open and Copy Path
/// for a folder, because the server has no folder download to share.
///
/// Long press and secondary click open the menu; VoiceOver and Full Keyboard
/// Access reach Share… and Copy Path as the row's actions (Open is the row's
/// own activation). Every way in runs `performRowAction`, which finds the
/// row by its path when it runs.
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
        guard indexPaths.count == 1, let path = rowPath(at: indexPaths[0]), rowMenuEntry(path: path) != nil else {
            return nil
        }
        let configuration = UIContextMenuConfiguration(identifier: path as NSString, previewProvider: nil) { [weak self] _ in
            UIMenu(children: Self.rowActions(path: path).map { action in
                let item = UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { _ in
                    self?.performRowAction(action, path: path)
                }
                item.accessibilityIdentifier = action.identifier
                return item
            })
        }
        // Share stays on top when the menu opens above a row low on the screen.
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    func rowAccessibilityActions(path: String) -> [UIAccessibilityCustomAction] {
        Self.rowActions(path: path).filter { $0 != .open }.map { action in
            UIAccessibilityCustomAction(name: action.title) { [weak self] _ in
                self?.performRowAction(action, path: path) ?? false
            }
        }
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
            TransientConfirmationPill.show(String(localized: "Path Copied"))
        case .share:
            guard let file = entry.file, let services, let api = services.apiClient else { return false }
            // The file is read the way its viewer reads it: the same origin and checkout.
            let access = FileBrowserViewerFactory
                .configuration(readerRequest(file, context: nil, services: services), chromeMode: .pushed)
                .fileAccess
            let share = access.remoteFileShare(api: api, path: file.path, fileName: file.name, size: file.size)
            Task { await FileSharePresenter.share(share, sourceItem: entry.cell) }
        }
        return true
    }
}
