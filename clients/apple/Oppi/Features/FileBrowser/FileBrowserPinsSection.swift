import UIKit

// Pins in the File Browser: the Pinned section at the top of the Home and
// workspace roots, and the Pin and Unpin items of rows, the viewer, and View
// Options. The section's rows, menus, and Edit mode are `PinsSection`'s.

/// The Pinned section of one File Browser screen. `FileBrowserViewController`
/// puts its rows in its own list, draws them as its own rows, and forwards
/// their taps, menus, swipes, drags, and Edit-mode reordering here.
///
/// Home shows every pin of the server; a workspace's root shows that
/// workspace's pins. Whether the section is collapsed is kept on the device.
@MainActor
final class FileBrowserPinsSection: PinsSection {
    struct Hooks {
        let connection: @MainActor () -> ServerConnection?
        let navigation: @MainActor () -> SceneNavigation?
        /// The folder the browser lists now (`a/b/`, or empty at the root).
        let currentFolder: @MainActor () -> String
        /// Opens a folder of this screen's own scope the way a row tap does.
        let openFolderHere: @MainActor (String) -> Void
        let setEditing: @MainActor (Bool) -> Void
        let changed: @MainActor () -> Void
    }

    private let scope: FileBrowserScope
    private let currentFolder: @MainActor () -> String

    init(serverId: String, scope: FileBrowserScope, presenter: UIViewController, hooks: Hooks) {
        self.scope = scope
        currentFolder = hooks.currentFolder
        super.init(serverId: serverId, identifierPrefix: "fileBrowser", presenter: presenter, hooks: .init(
            connection: hooks.connection,
            shows: { pin in
                switch scope {
                case .hostHome: true
                case .workspace(let workspaceId, nil): pin.target.workspaceId == workspaceId
                case .workspace: false
                }
            },
            open: { pin, _ in
                Self.open(pin, serverId: serverId, scope: scope, navigation: hooks.navigation(), openFolderHere: hooks.openFolderHere)
            },
            paneSource: { [weak presenter] in presenter?.viewIfLoaded },
            isCollapsed: { FileBrowserViewOptionsStore.shared.pinsCollapsed },
            setCollapsed: { FileBrowserViewOptionsStore.shared.setPinsCollapsed($0) },
            setEditing: hooks.setEditing,
            changed: hooks.changed
        ))
    }

    /// The section at the root, or nil below it.
    func content(atRoot: Bool) -> Content? {
        atRoot ? content() : nil
    }

    /// A folder of this screen's scope opens in place; anything else pushes
    /// its own browser or the viewer.
    private static func open(
        _ pin: Pin,
        serverId: String,
        scope: FileBrowserScope,
        navigation: SceneNavigation?,
        openFolderHere: @MainActor (String) -> Void
    ) {
        guard let navigation else { return }
        switch (pin.target, pin.kind) {
        case (.host(let path), .directory):
            let folder = FileBrowserHostHomePath.directoryPath(rawPath: path)
            if scope == .hostHome {
                openFolderHere(folder)
            } else {
                navigation.pushWorkspaceFileBrowser(FileBrowserNavTarget(serverId: serverId, scope: .hostHome, path: folder))
            }
        case (.workspace(let workspaceId, let path), .directory):
            let folder = path.isEmpty ? "" : path + "/"
            let pinScope = FileBrowserScope.workspace(workspaceId: workspaceId, worktreeId: nil)
            if scope == pinScope {
                openFolderHere(folder)
            } else {
                // The browser's own lock cover asks for the workspace's unlock.
                navigation.pushWorkspaceFileBrowser(FileBrowserNavTarget(serverId: serverId, scope: pinScope, path: folder))
            }
        case (.host(let path), .file):
            navigation.openWorkspaceLinkedFile(.hostFile(serverId: serverId, workspaceId: "", path: path))
        case (.workspace(let workspaceId, let path), .file):
            navigation.openWorkspaceLinkedFile(.workspaceFile(serverId: serverId, workspaceId: workspaceId, path: path))
        }
    }

    /// The heading of the folder's own listing under the Pinned section, so
    /// it is plain where the pins end. Shown only with the section.
    static func configureListingHeader(_ cell: UICollectionViewListCell, palette: ThemePalette) {
        var content = UIListContentConfiguration.header()
        content.text = String(localized: "Files")
        content.textProperties.color = palette.ui.comment
        cell.contentConfiguration = content
        cell.accessories = []
        cell.backgroundConfiguration = background(palette)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = content.text
        cell.accessibilityTraits = .header
        cell.accessibilityIdentifier = "fileBrowser.listing.header"
    }

    // MARK: Pin and Unpin

    /// Pin or Unpin for a browser row at `rowPath` (a folder's ends in "/").
    func rowMenuElement(rowPath: String) -> UIMenuElement? {
        rowToggle(rowPath: rowPath)?.action
    }

    /// The same Pin or Unpin as the row's accessibility action.
    func rowAccessibilityAction(rowPath: String) -> UIAccessibilityCustomAction? {
        rowToggle(rowPath: rowPath)?.accessibilityAction
    }

    private func rowToggle(rowPath: String) -> PinMenu.Toggle? {
        target(forRowPath: rowPath).flatMap { toggle(for: $0, isFolder: rowPath.hasSuffix("/"), current: false) }
    }

    /// View Options' Pin This Folder or Unpin This Folder, for the folder listed now.
    func viewOptionsElements() -> [UIMenuElement] {
        guard let target = target(forRowPath: currentFolder().isEmpty ? "/" : currentFolder()),
              let toggle = toggle(for: target, isFolder: true, current: true) else { return [] }
        return [UIMenu(options: .displayInline, children: [toggle.action])]
    }

    /// The target a row names, as the server stores it; nil where pins do
    /// not reach (a worktree, the chat panel's checkout).
    private func target(forRowPath rowPath: String) -> PinTarget? {
        let isFolder = rowPath.hasSuffix("/")
        switch scope {
        case .hostHome:
            return .host(path: isFolder ? FileBrowserHostHomePath.rawPath(relativePath: rowPath) : rowPath)
        case .workspace(let workspaceId, nil):
            let path = rowPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .workspace(id: workspaceId, path: path)
        case .workspace:
            return nil
        }
    }

    private func toggle(for target: PinTarget, isFolder: Bool, current: Bool) -> PinMenu.Toggle? {
        guard let (pins, api) = store, let view = presenter?.view else { return nil }
        return PinMenu.toggle(target: target, isFolder: isFolder, current: current, pins: pins, api: api, view: view)
    }
}

/// Collection-view hooks a pin row needs that only the delegate answers.
extension FileBrowserViewController {
    /// A pin moves only among the pins, below the section's header.
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard proposedIndexPath.section == originalIndexPath.section else { return originalIndexPath }
        return proposedIndexPath.item == 0 ? IndexPath(item: 1, section: proposedIndexPath.section) : proposedIndexPath
    }
}
