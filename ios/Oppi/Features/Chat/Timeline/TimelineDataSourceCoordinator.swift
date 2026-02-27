import UIKit

@MainActor
enum TimelineDataSourceCoordinator {
    typealias DataSource = UICollectionViewDiffableDataSource<Int, String>

    static func makeDataSource(
        collectionView: UICollectionView,
        itemByIDProvider: @escaping () -> [String: ChatItem],
        registrations: TimelineCellFactory.Registrations,
        isCompactionMessage: @escaping (String) -> Bool
    ) -> DataSource {
        DataSource(collectionView: collectionView) { collectionView, indexPath, itemID in
            TimelineCellFactory.dequeueCell(
                collectionView: collectionView,
                indexPath: indexPath,
                itemID: itemID,
                itemByID: itemByIDProvider(),
                registrations: registrations,
                isCompactionMessage: isCompactionMessage
            )
        }
    }
}
