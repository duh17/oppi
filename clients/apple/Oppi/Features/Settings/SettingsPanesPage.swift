import UIKit

/// Settings > Panes: New Panes, the side each kind of new pane opens on when
/// nothing says (`SettingsCatalog.newPaneSide`, read by `SidePanePlacement`), saved
/// on this device. Settings lists the page only where panes split (see
/// `SettingsRootViewController.showsPanes`); a compact window never places one.
final class SettingsPanesViewController: ListScreenController<SettingsPanesViewController.Section, SettingsPanesViewController.Item> {
    enum Section: Hashable, Sendable { case newPanes }
    enum Item: Hashable, Sendable {
        /// Where a new pane of this kind opens: Automatic, Right or Below.
        case newPaneSide(AppPreferenceStore.NewPanes.Kind)
        /// The failure line under the declared setting with this id.
        case failure(String)
    }

    init(settings: SettingsStore) {
        super.init(
            title: String(localized: "Panes"),
            listIdentifier: "settings.panes.list",
            scope: .device,
            settings: settings,
            headers: true,
            footers: true
        )
    }

    /// One side per kind. Games only where this build plays them
    /// (`PlatformCapabilities.godotPane`).
    override func sections() -> [ListSection<Section, Item>] {
        let kinds = AppPreferenceStore.NewPanes.Kind.allCases.filter { $0 != .games || PlatformCapabilities.godotPane }
        return [ListSection(
            .newPanes,
            header: String(localized: "New Panes"),
            footer: SettingsCatalog.newPaneSide(.terminal).copy.footer,
            items: kinds.flatMap { kind in settingRows(SettingsCatalog.newPaneSide(kind), .newPaneSide(kind)) { .failure($0) } }
        )]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .newPaneSide(let kind): settingInputs(SettingsCatalog.newPaneSide(kind))
        case .failure(let id): settingFailureInputs(id)
        }
    }

    private lazy var newPaneSideRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        guard let self, case .newPaneSide(let kind) = item else { return }
        settingChoiceRow(cell, SettingsCatalog.newPaneSide(kind), choices: AppPreferenceStore.NewPanes.Side.allCases.map {
            SettingChoice(value: $0, title: $0.title)
        })
    }

    override func prepareRegistrations() {
        _ = newPaneSideRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .newPaneSide: collectionView.dequeueConfiguredReusableCell(using: newPaneSideRow, for: indexPath, item: item)
        case .failure(let id): dequeueSettingFailure(id, at: indexPath)
        }
    }
}
