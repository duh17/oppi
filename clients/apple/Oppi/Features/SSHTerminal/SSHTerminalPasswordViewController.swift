import UIKit

/// Password prompt for Connect and Save Host. Save Password edits the profile
/// through `onSavesPasswordChange` so the host list round-trips the toggle.
final class SSHTerminalPasswordViewController: UIViewController, UICollectionViewDelegate, UITextFieldDelegate {
    let endpointLabel: String
    private var savesPassword: Bool
    private let confirmTitle: String
    private let onSavesPasswordChange: (Bool) -> Void
    private let onCancel: () -> Void
    private let onConfirm: (String) -> Void

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var password = ""
    private weak var passwordField: UITextField?
    private var confirmItem: UIBarButtonItem?
    private var lastThemeID: ThemeID?

    private enum Section: Hashable { case password, save }
    private enum Item: Hashable { case password, savePassword, saveHint }

    init(
        endpointLabel: String,
        savesPassword: Bool,
        confirmTitle: String,
        onSavesPasswordChange: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void
    ) {
        self.endpointLabel = endpointLabel
        self.savesPassword = savesPassword
        self.confirmTitle = confirmTitle
        self.onSavesPasswordChange = onSavesPasswordChange
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .none
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SSH Sign In"
        navigationItem.largeTitleDisplayMode = .inline
        applyTheme()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        let confirm = UIBarButtonItem(title: confirmTitle, style: .done, target: self, action: #selector(confirm))
        confirm.accessibilityLabel = confirmTitle
        confirm.accessibilityIdentifier = "sshTerminal.passwordConnect"
        confirm.isEnabled = false
        confirmItem = confirm
        navigationItem.rightBarButtonItem = confirm

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let fieldCell = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(
                text: self.password,
                placeholder: "Password",
                identifier: "sshTerminal.password",
                isSecure: true,
                keyboard: .default,
                contentType: nil,
                onChange: { [weak self] value in
                    self?.password = value
                    self?.confirmItem?.isEnabled = !value.isEmpty
                }
            )
            cell.textField.delegate = self
            self.passwordField = cell.textField
        }
        let toggleCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            content.text = "Save Password"
            content.textProperties.color = UIColor(self.themePalette.fg)
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = self.savesPassword
            toggle.accessibilityLabel = "Save Password"
            toggle.addAction(UIAction { [weak self] action in
                guard let toggle = action.sender as? UISwitch else { return }
                self?.savesPassword = toggle.isOn
                self?.onSavesPasswordChange(toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
        }
        let hintCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Saving requires a device passcode. Face ID or passcode approval is required when Oppi reads it, except for 5 minutes after you approve."
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = UIColor(self?.themePalette.comment ?? ThemeRuntimeState.currentThemeID().palette.comment)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = indexPath.section == 0 ? self?.endpointLabel : nil
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .password: collectionView.dequeueConfiguredReusableCell(using: fieldCell, for: indexPath, item: item)
            case .savePassword: collectionView.dequeueConfiguredReusableCell(using: toggleCell, for: indexPath, item: item)
            case .saveHint: collectionView.dequeueConfiguredReusableCell(using: hintCell, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.password, .save])
        snapshot.appendItems([.password], toSection: .password)
        snapshot.appendItems([.savePassword, .saveHint], toSection: .save)
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        passwordField?.becomeFirstResponder()
    }

    override func updateProperties() {
        super.updateProperties()
        applyTheme()
        let themeID = sshTerminalThemeID
        guard lastThemeID != themeID, let dataSource else { return }
        lastThemeID = themeID
        var snapshot = dataSource.snapshot()
        snapshot.reloadItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if !password.isEmpty { confirm() }
        return false
    }

    @objc private func cancel() { onCancel() }
    @objc private func confirm() {
        guard !password.isEmpty else { return }
        onConfirm(password)
    }

    /// Confirms with `password`, as typing it and tapping Connect does.
    func submit(_ password: String) {
        self.password = password
        confirm()
    }

    private var themePalette: ThemePalette { sshTerminalThemeID.palette }

    private func applyTheme() {
        let themeID = sshTerminalThemeID
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = UIColor(themeID.palette.bg)
        collectionView.backgroundColor = UIColor(themeID.palette.bg)
    }
}
