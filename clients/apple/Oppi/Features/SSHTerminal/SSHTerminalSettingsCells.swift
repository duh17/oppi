import UIKit

/// Text field in an inset-grouped settings list. Reused by the host form and
/// the password prompt.
final class SSHTerminalTextFieldCell: UICollectionViewListCell {
    let textField = UITextField()
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.addTarget(self, action: #selector(changed), for: .editingChanged)
        contentView.addSubview(textField)
        let minHeight = textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            textField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            minHeight,
        ])
        accessibilityElements = [textField]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        text: String,
        placeholder: String,
        identifier: String,
        isSecure: Bool = false,
        keyboard: UIKeyboardType = .default,
        autocapitalization: UITextAutocapitalizationType = .none,
        autocorrection: UITextAutocorrectionType = .no,
        contentType: UITextContentType? = nil,
        monospaced: Bool = false,
        textColor: UIColor = .label,
        enabled: Bool = true,
        onChange: @escaping (String) -> Void
    ) {
        self.onChange = onChange
        if !textField.isFirstResponder, textField.text != text {
            textField.text = text
        }
        textField.placeholder = placeholder
        textField.accessibilityIdentifier = identifier
        textField.isSecureTextEntry = isSecure
        textField.keyboardType = keyboard
        textField.autocapitalizationType = autocapitalization
        textField.autocorrectionType = autocorrection
        textField.textContentType = contentType
        textField.font = monospaced
            ? .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
            : .preferredFont(forTextStyle: .body)
        textField.textColor = textColor
        textField.isEnabled = enabled
        textField.clearButtonMode = .never
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        textField.delegate = nil
        textField.accessibilityIdentifier = nil
    }

    @objc private func changed() {
        onChange?(textField.text ?? "")
    }
}

/// A settings row that is a real UIButton so XCUITest `app.buttons[id]` finds it.
final class SSHTerminalActionCell: UICollectionViewListCell {
    let button = UIButton(type: .system)
    private var tapAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityElements = [button]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        identifier: String,
        color: UIColor,
        enabled: Bool = true,
        subtitle: String? = nil,
        image: String? = nil,
        menu: UIMenu? = nil,
        action: (() -> Void)? = nil
    ) {
        accessories = []
        var conf = UIButton.Configuration.plain()
        conf.title = title
        conf.subtitle = subtitle
        conf.baseForegroundColor = enabled ? color : color.withAlphaComponent(0.4)
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        if let image {
            conf.image = UIImage(systemName: image)
            conf.imagePadding = 8
        }
        button.configuration = conf
        button.accessibilityIdentifier = identifier
        button.isEnabled = enabled
        button.menu = menu
        button.showsMenuAsPrimaryAction = menu != nil
        if let tapAction {
            button.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        if let action, menu == nil {
            let tap = UIAction { _ in action() }
            tapAction = tap
            button.addAction(tap, for: .touchUpInside)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessories = []
        button.menu = nil
        button.showsMenuAsPrimaryAction = false
        if let tapAction {
            button.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        button.accessibilityIdentifier = nil
    }
}

/// Host list row: a real UIButton so `app.buttons["sshTerminal.host.row."]` finds it.
final class SSHTerminalHostRowCell: UICollectionViewListCell {
    let connectButton = UIButton(type: .system)
    private var tapAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.contentHorizontalAlignment = .leading
        contentView.addSubview(connectButton)
        NSLayoutConstraint.activate([
            connectButton.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            connectButton.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor, constant: -8),
            connectButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            connectButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            connectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        profile: SSHTerminalProfile,
        live: Bool,
        folderTerminals: [String] = [],
        palette: ThemePalette,
        enabled: Bool,
        onConnect: @escaping () -> Void,
        onEdit: @escaping () -> Void
    ) {
        var conf = UIButton.Configuration.plain()
        conf.title = profile.endpointLabel
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .body)
            outgoing.foregroundColor = UIColor(palette.fg)
            return outgoing
        }
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline)
        let comment = UIColor(palette.comment)
        let subtitle = NSMutableAttributedString()
        func appendLine(_ text: String, color: UIColor) {
            if subtitle.length > 0 { subtitle.append(NSAttributedString(string: "\n")) }
            subtitle.append(NSAttributedString(string: text, attributes: [
                .font: subheadline,
                .foregroundColor: color,
            ]))
        }
        if let port = profile.portLabel { appendLine(port, color: comment) }
        appendLine(profile.startupLabel, color: comment)
        if live { appendLine("Connected", color: UIColor(palette.green)) }
        // One line per open folder terminal, so a host with both its own
        // terminal and a workspace shell says which folders are open.
        for folder in folderTerminals {
            // The remote path as the server stores it: this device's home would
            // name a different folder.
            appendLine(String(localized: "Connected in \(folder)"), color: UIColor(palette.green))
        }
        conf.attributedSubtitle = AttributedString(subtitle)
        conf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        connectButton.configuration = conf
        connectButton.accessibilityIdentifier = "sshTerminal.host.row.\(profile.id.uuidString)"
        // The row opens the host's own terminal either way: a folder terminal is a
        // different terminal, so its folders are the value, not the hint.
        connectButton.accessibilityHint = live ? "Open the connected terminal" : "Connect"
        if live {
            connectButton.accessibilityValue = "Connected"
        } else if folderTerminals.isEmpty {
            connectButton.accessibilityValue = nil
        } else {
            connectButton.accessibilityValue = "Connected in " + folderTerminals.joined(separator: ", ")
        }
        connectButton.isEnabled = enabled
        if let tapAction {
            connectButton.removeAction(tapAction, for: .touchUpInside)
        }
        let tap = UIAction { _ in onConnect() }
        tapAction = tap
        connectButton.addAction(tap, for: .touchUpInside)

        let edit = UIButton(type: .system)
        var editConf = UIButton.Configuration.plain()
        editConf.title = "Edit"
        editConf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        edit.configuration = editConf
        edit.accessibilityIdentifier = "sshTerminal.host.edit.\(profile.id.uuidString)"
        edit.addAction(UIAction { _ in onEdit() }, for: .touchUpInside)
        accessories = [.customView(configuration: .init(customView: edit, placement: .trailing()))]
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessories = []
        if let tapAction {
            connectButton.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        connectButton.accessibilityIdentifier = nil
    }
}

@MainActor
extension UICellAccessory {
    /// A trailing switch. `identifier` makes it `app.switches[id]` in UI tests.
    /// A disabled switch keeps a row's saved value visible while the row cannot
    /// be changed.
    static func settingsToggle(
        _ isOn: Bool,
        identifier: String? = nil,
        isEnabled: Bool = true,
        onChange: @escaping (Bool) -> Void
    ) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        toggle.accessibilityIdentifier = identifier
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing()))
    }

    /// A trailing pop-up button showing the current choice.
    static func settingsPopUpMenu(
        identifier: String,
        options: [(title: String, selected: Bool, action: () -> Void)]
    ) -> UICellAccessory {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.accessibilityIdentifier = identifier
        button.menu = UIMenu(children: options.map { option in
            UIAction(title: option.title, state: option.selected ? .on : .off) { _ in option.action() }
        })
        var config = UIButton.Configuration.plain()
        config.indicator = .popup
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 0)
        button.configuration = config
        return .customView(configuration: .init(customView: button, placement: .trailing()))
    }
}

/// Which rows of a settings list a pass must reconfigure: those whose inputs
/// changed since the last pass. Reconfiguring a row replaces its accessories,
/// and replacing a pop-up button dismisses the menu it has open, so a pass
/// that UIKit runs for the menu itself, or for a change to another row, must
/// leave that row alone.
struct ChangedRows<Item: Hashable> {
    private var last: [Item: AnyHashable] = [:]

    /// The rows in `items` whose `inputs` differ from the previous call.
    mutating func changed(in items: [Item], inputs: (Item) -> AnyHashable) -> [Item] {
        var next: [Item: AnyHashable] = [:]
        var changed: [Item] = []
        for item in items {
            let value = inputs(item)
            next[item] = value
            if last[item] != value { changed.append(item) }
        }
        last = next
        return changed
    }
}

enum SSHTerminalSettingsList {
    static func pin(_ collectionView: UICollectionView, in view: UIView) {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        let maxWidth = collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: IPadReadableContentWidth.form)
        let fillWidth = collectionView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            maxWidth,
            fillWidth,
        ])
    }

    static func applyTheme(to view: UIView, collectionView: UICollectionView, themeID: ThemeID) {
        view.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        let bg = UIColor(themeID.palette.bg)
        view.backgroundColor = bg
        collectionView.backgroundColor = bg
    }
}
