import UIKit

/// One choice of a declared setting's menu row.
struct SettingChoice<Value: Equatable & Sendable> {
    var value: Value
    var title: String
}

/// A titled run of choices, drawn inline in the menu (models under their
/// provider). A nil title is an ungrouped run.
struct SettingChoiceGroup<Value: Equatable & Sendable> {
    var title: String?
    var choices: [SettingChoice<Value>]
}

/// Rows drawn from a `SettingDeclaration`: the title, the identifier, the
/// scope, the value, and what the row does while saving or after a failure all
/// come from the declaration and the store, so every setting behaves the same.
///
/// - Reads `settings` (`SettingsStore`), so call `settingRows` and
///   `settingInputs` from `sections()` and `inputs(of:)`, which run inside
///   `updateProperties()`: the page redraws when the setting's state changes.
/// - The row is disabled while a write is in flight or when there is no value
///   to change, and says "Unavailable" when the setting cannot be reached.
/// - A failed load or write adds a failure row under it with the reason and
///   Retry (`settingRows`), and the value rolls back to the last stored one.
extension SettingsListViewController {
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

    /// The scope sentence's scope for a section holding `declaration`: from its
    /// storage and the attached server's name.
    func settingScope<Value>(_ declaration: SettingDeclaration<Value>) -> SettingsScope? {
        settings?.scope(of: declaration)
    }

    /// What a declared setting's row is drawn from, for `inputs(of:)`.
    func settingInputs<Value>(_ declaration: SettingDeclaration<Value>) -> AnyHashable {
        AnyHashable(settings.map { String(describing: $0.read(declaration)) } ?? "")
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

    /// Makes `cell` the switch row of a declared on/off setting.
    func settingToggleRow(_ cell: UICollectionViewListCell, _ declaration: SettingDeclaration<Bool>) {
        let state = settings?.read(declaration) ?? .unavailable(reason: Self.noStore)
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
        ) { [weak self] isOn in
            self?.settings?.set(declaration, isOn)
        }]
    }

    // MARK: - Choice

    /// Configures `cell` as the menu row of a declared setting. `groups` are
    /// the values it can take; the row shows the title of the current one, or
    /// `placeholder` when none matches. While the choices themselves are still
    /// arriving, `choicesLoading` is the text the row shows (when no current
    /// choice has a title) and the row stays disabled, so the menu is never
    /// opened empty.
    func settingChoiceRow<Value>(
        _ cell: SettingsMenuRowCell,
        _ declaration: SettingDeclaration<Value>,
        groups: [SettingChoiceGroup<Value>],
        placeholder: String? = nil,
        choicesLoading: String? = nil
    ) {
        let state = settings?.read(declaration) ?? .unavailable(reason: Self.noStore)
        let current = state.current
        let menu = UIMenu(children: groups.map { group in
            let actions = group.choices.map { choice in
                UIAction(title: choice.title, state: choice.value == current ? .on : .off) { [weak self] _ in
                    self?.settings?.set(declaration, choice.value)
                }
            }
            return UIMenu(title: group.title ?? "", options: .displayInline, children: actions)
        })
        let selected = groups.lazy.flatMap(\.choices).first { $0.value == current }?.title
        let shown: String? = switch state {
        case .unavailable: Self.unavailableTitle
        case .loading: String(localized: "Loading…")
        case .value, .saving, .failed: selected ?? choicesLoading ?? placeholder
        }
        cell.configure(
            title: declaration.copy.title,
            identifier: declaration.id,
            isEnabled: state.canBeginSaving && choicesLoading == nil,
            value: shown,
            menu: menu
        )
    }

    /// One ungrouped list of choices.
    func settingChoiceRow<Value>(
        _ cell: SettingsMenuRowCell,
        _ declaration: SettingDeclaration<Value>,
        choices: [SettingChoice<Value>],
        placeholder: String? = nil
    ) {
        settingChoiceRow(cell, declaration, groups: [SettingChoiceGroup(title: nil, choices: choices)], placeholder: placeholder)
    }

    private static var unavailableTitle: String { String(localized: "Unavailable") }
    private static var noStore: String { String(localized: "This page has no settings store.") }
}
