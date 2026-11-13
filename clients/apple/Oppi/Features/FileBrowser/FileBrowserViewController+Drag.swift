import UIKit

/// A workspace row lifts as a pane entry (`PaneDragPayload`): dropped on a
/// chat it becomes a file reference in the message, on a pane's edge it
/// opens in a new pane there (`PaneHostController+Drop`). It carries no
/// public type, so a text field never takes it as text.
extension FileBrowserViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let path = rowPath(at: indexPath), let entry = paneEntry(forRowPath: path) else { return [] }
        let provider = NSItemProvider()
        provider.suggestedName = (path.hasSuffix("/") ? String(path.dropLast()) : path).split(separator: "/").last.map(String.init)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = PaneDragPayload(entry: entry)
        return [item]
    }
}
