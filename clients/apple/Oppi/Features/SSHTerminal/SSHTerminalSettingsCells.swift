import UIKit

/// Text field in an inset-grouped settings list. Reused by the host form, the
/// password prompt, and New Workspace. With a `label` the row reads like a
/// labeled value: the name on the left, the right-aligned field after it.
final class SSHTerminalTextFieldCell: UICollectionViewListCell {
    let textField = UITextField()
    private let titleLabel = UILabel()
    private var onChange: ((String) -> Void)?
    private var maximumLength: Int?
    private var returnAction: UIAction?
    private var fieldAfterMargin: NSLayoutConstraint?
    private var fieldAfterLabel: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.adjustsFontForContentSizeCategory = true
        textField.addTarget(self, action: #selector(changed), for: .editingChanged)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Decorative: the field carries the label.
        titleLabel.isAccessibilityElement = false
        contentView.addSubview(titleLabel)
        contentView.addSubview(textField)
        let margins = contentView.layoutMarginsGuide
        let minHeight = textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minHeight.priority = .defaultHigh
        let afterMargin = textField.leadingAnchor.constraint(equalTo: margins.leadingAnchor)
        fieldAfterMargin = afterMargin
        fieldAfterLabel = textField.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            textField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            minHeight,
            afterMargin,
        ])
        accessibilityElements = [textField]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `onReturn` runs when Return is pressed, after the field resigns. A field
    /// with none keeps its existing Return behavior. A field with a
    /// `maximumLength` keeps its last characters, so typing over a one-key
    /// field replaces the key.
    func configure(
        text: String,
        placeholder: String,
        identifier: String,
        label: String? = nil,
        isSecure: Bool = false,
        keyboard: UIKeyboardType = .default,
        autocapitalization: UITextAutocapitalizationType = .none,
        autocorrection: UITextAutocorrectionType = .no,
        contentType: UITextContentType? = nil,
        monospaced: Bool = false,
        textColor: UIColor = .label,
        labelColor: UIColor = .label,
        enabled: Bool = true,
        returnKey: UIReturnKeyType = .default,
        maximumLength: Int? = nil,
        onReturn: (() -> Void)? = nil,
        onChange: @escaping (String) -> Void
    ) {
        self.onChange = onChange
        self.maximumLength = maximumLength
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
        textField.font = monospaced ? .scaledMonospaced(.body) : .preferredFont(forTextStyle: .body)
        textField.textColor = textColor
        textField.isEnabled = enabled
        textField.clearButtonMode = .never
        textField.returnKeyType = returnKey
        titleLabel.text = label
        titleLabel.textColor = labelColor
        titleLabel.isHidden = label == nil
        textField.textAlignment = label == nil ? .natural : .right
        // Deactivate before activating, so the field never has two leading edges.
        if label == nil {
            fieldAfterLabel?.isActive = false
            fieldAfterMargin?.isActive = true
        } else {
            fieldAfterMargin?.isActive = false
            fieldAfterLabel?.isActive = true
        }
        setReturnAction(onReturn)
    }

    private func setReturnAction(_ onReturn: (() -> Void)?) {
        if let returnAction {
            textField.removeAction(returnAction, for: .editingDidEndOnExit)
            self.returnAction = nil
        }
        guard let onReturn else { return }
        // A target for `.editingDidEndOnExit` also makes Return resign the field.
        let action = UIAction { _ in onReturn() }
        returnAction = action
        textField.addAction(action, for: .editingDidEndOnExit)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        maximumLength = nil
        setReturnAction(nil)
        textField.delegate = nil
        textField.accessibilityIdentifier = nil
    }

    @objc private func changed() {
        if let maximumLength, let text = textField.text, text.count > maximumLength {
            textField.text = String(text.suffix(maximumLength))
        }
        onChange?(textField.text ?? "")
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
        connectButton.accessibilityHint = profile.opensRexSessions ? "Open Rex sessions"
            : live ? "Open the connected terminal" : "Connect"
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
