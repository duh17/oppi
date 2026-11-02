import UIKit

/// Password prompt for Connect and Save Host. Save Password edits the profile
/// through `onSavesPasswordChange` so the host list round-trips the toggle.
final class SSHTerminalPasswordViewController: ListScreenController<SSHTerminalPasswordViewController.Section, SSHTerminalPasswordViewController.Item>, UITextFieldDelegate {
    enum Section: Hashable, Sendable { case password, save }
    enum Item: Hashable, Sendable { case password, savePassword, saveHint }

    let endpointLabel: String
    private var savesPassword: Bool
    private let confirmTitle: String
    private let onSavesPasswordChange: (Bool) -> Void
    private let onCancel: () -> Void
    private let onConfirm: (String) -> Void

    private var password = ""
    private weak var passwordField: UITextField?
    private var confirmItem: UIBarButtonItem?
    /// The row's one switch, kept across redraws so a pass never replaces it.
    private let saveSwitch = UISwitch()

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
        super.init(
            title: "SSH Sign In",
            listIdentifier: "sshTerminal.password.list",
            headers: true,
            dismissesKeyboardOnDrag: true
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        let confirm = UIBarButtonItem(title: confirmTitle, style: .prominent, target: self, action: #selector(confirm))
        confirm.accessibilityLabel = confirmTitle
        confirm.accessibilityIdentifier = "sshTerminal.passwordConnect"
        confirm.isEnabled = false
        confirmItem = confirm
        navigationItem.rightBarButtonItem = confirm

        saveSwitch.accessibilityLabel = "Save Password"
        saveSwitch.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.savesPassword = toggle.isOn
            self?.onSavesPasswordChange(toggle.isOn)
        }, for: .valueChanged)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        passwordField?.becomeFirstResponder()
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(.password, header: endpointLabel, items: [.password]),
            ListSection(.save, items: [.savePassword, .saveHint]),
        ]
    }

    /// The host's name heads the field; the Save section states itself in its rows.
    override func showsHeader(for section: Section) -> Bool {
        section == .password
    }

    /// The field is keyed by what it draws — nothing — so typing never
    /// reconfigures it and it keeps focus and selection. The switch is keyed by
    /// its value, and the hint never changes.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .password, .saveHint: AnyHashable(0)
        case .savePassword: AnyHashable(savesPassword)
        }
    }

    private lazy var fieldRow = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            text: password,
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
        passwordField = cell.textField
    }

    override func prepareRegistrations() {
        _ = fieldRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .password: collectionView.dequeueConfiguredReusableCell(using: fieldRow, for: indexPath, item: item)
        case .savePassword, .saveHint: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .password:
            break
        case .savePassword:
            var content = content(.info)
            content.text = "Save Password"
            cell.contentConfiguration = content
            saveSwitch.isOn = savesPassword
            cell.accessories = [.customView(configuration: .init(customView: saveSwitch, placement: .trailing()))]
        case .saveHint:
            var content = content(.subtitle)
            content.text = "Saving requires a device passcode. Face ID or passcode approval is required when Oppi reads it, except for 5 minutes after you approve."
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = SettingsStyle.current.value
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
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
}
