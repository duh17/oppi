import UIKit

/// A row lifts as a pane entry (`PaneDragPayload`): dropped on a chat of
/// its own workspace it becomes a file reference in the message, on a pane's edge it
/// opens in a new pane there (`PaneHostController+Drop`). It carries no
/// public type, so a text field never takes it as text.
extension FileBrowserViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        if let pinId = pinId(at: indexPath) { return pinsSection?.dragItems(pinId: pinId) ?? [] }
        guard let path = rowPath(at: indexPath), let entry = paneEntry(forRowPath: path) else { return [] }
        let provider = NSItemProvider()
        provider.suggestedName = (path.hasSuffix("/") ? String(path.dropLast()) : path).split(separator: "/").last.map(String.init)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = PaneDragPayload(entry: entry)
        return [item]
    }
}
