import UIKit

/// One choice of a declared setting's menu row.
struct SettingChoice<Value: Equatable & Sendable> {
    var value: Value
    var title: String
    /// A small preview drawn in the menu row.
    var image: UIImage?

    init(value: Value, title: String, image: UIImage? = nil) {
        self.value = value
        self.title = title
        self.image = image
    }
}

/// Rows drawn from a `SettingDeclaration`: the title, the identifier, the
/// value, and what the row does while saving or after a failure all
/// come from the declaration and the store, so every setting behaves the same.
///
/// - Reads `settings` (`SettingsStore`), so call `settingRows` and
///   `settingInputs` from `sections()` and `inputs(of:)`, which run inside
///   `updateProperties()`: the page redraws when the setting's state changes.
/// - The row is disabled while a write is in flight or when there is no value
///   to change, and says "Unavailable" when the setting cannot be reached.
/// - A failed load or write adds a failure row under it with the reason and
///   Retry (`settingRows`), and the value rolls back to the last stored one.
extension ListScreenController {
    /// The page's items for one declared setting: its row, then a failure row
    /// when its last load or write failed. `failure` makes the page's item for
    /// the failure row from the setting's id.
    func settingRows<Value>(
        _ declaration: SettingDeclaration<Value>,
        _ item: Item,
        failure: (String) -> Item
    ) -> [Item] {
        guard let settings, settings.read(declaration).failureReason != nil else { return [item] }
        return [item, failure(declaration.id)]
    }

    /// What a declared setting's row is drawn from, for `inputs(of:)`. `store` is for a
    /// section kept somewhere other than the page's own store (a device setting on a
    /// server's page); it defaults to the page's.
    func settingInputs<Value>(_ declaration: SettingDeclaration<Value>, store: SettingsStore? = nil) -> AnyHashable {
        AnyHashable((store ?? settings).map { String(describing: $0.read(declaration)) } ?? "")
    }

    /// What the failure row under a setting is drawn from, for `inputs(of:)`.
    func settingFailureInputs(_ id: String) -> AnyHashable {
        AnyHashable([settings?.failureReason(id: id) ?? "", settings?.canRetry(id: id) == true ? "retry" : ""])
    }

    /// The failure row under the setting with this id.
    func dequeueSettingFailure(_ id: String, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: settingFailureCell, for: indexPath, item: id)
    }

    // MARK: - Toggle

    /// Makes `cell` the switch row of a declared on/off setting. `store` as in `settingInputs`.
    func settingToggleRow(_ cell: UICollectionViewListCell, _ declaration: SettingDeclaration<Bool>, store: SettingsStore? = nil) {
        let store = store ?? settings
        let state = store?.read(declaration) ?? .unavailable(reason: Self.noStore)
        var content = content(state.unavailableReason == nil ? .plain : .subtitle)
        content.text = declaration.copy.title
        content.secondaryText = state.unavailableReason == nil ? nil : Self.unavailableTitle
        cell.contentConfiguration = content
        cell.accessories = [.settingsToggle(
            state.current ?? declaration.default,
            identifier: declaration.id,
            label: declaration.copy.title,
            isEnabled: state.canBeginSaving,
            reusing: cell
        ) { [weak store] isOn in
            store?.set(declaration, isOn)
        }]
    }

    // MARK: - Choice

    /// Configures `cell` as the menu row of a declared setting. `choices` are the
    /// values it can take; the row shows the title of the current one.
    func settingChoiceRow<Value>(
        _ cell: SettingsMenuRowCell,
        _ declaration: SettingDeclaration<Value>,
        choices: [SettingChoice<Value>]
    ) {
        let state = settings?.read(declaration) ?? .unavailable(reason: Self.noStore)
        let current = state.current
        let shown: String? = switch state {
        case .unavailable: Self.unavailableTitle
        case .loading: String(localized: "Loading…")
        case .value, .saving, .failed: choices.first { $0.value == current }?.title
        }
        cell.configure(
            title: declaration.copy.title,
            identifier: declaration.id,
            isEnabled: state.canBeginSaving,
            value: shown,
            menu: {
                choices.map { choice in
                    SettingsMenuOption(title: choice.title, image: choice.image, selected: choice.value == current) { [weak self] in
                        self?.settings?.set(declaration, choice.value)
                    }
                }
            }
        )
    }

    private static var unavailableTitle: String { String(localized: "Unavailable") }
    private static var noStore: String { String(localized: "This page has no settings store.") }
}
