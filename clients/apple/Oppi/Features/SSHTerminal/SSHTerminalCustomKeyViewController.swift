import UIKit

/// The form for making or editing one custom key of the terminal's bottom bar:
/// a name, the modifiers and key to send, and which program shows the button.
/// A draft: Save (enabled once the combination is one the terminal can send)
/// hands the key to `onSave` and closes the sheet; Cancel closes it. The
/// preview shows the combination the way the key cap and the Bottom Bar row
/// show it (⌃D), live.
///
/// The key is one typed character (a letter, a digit, or one of the
/// punctuation keys the keymap reads) or a named key from the menu, which a
/// text field cannot type: Esc, Tab, Return, Space, Backspace, the arrows,
/// Home, End, Page Up, Page Down, and F1 to F12.
@MainActor
final class SSHTerminalCustomKeyViewController: ListScreenController<
    SSHTerminalCustomKeyViewController.Section, SSHTerminalCustomKeyViewController.Item
> {
    enum Section: Hashable, Sendable { case name, combination, preview, showFor }

    enum Item: Hashable, Sendable { case name, modifiers, key, namedKey, preview, showFor }

    private let onSave: (SSHTerminalCustomKey) -> Void
    private let isNew: Bool
    private(set) var draft: SSHTerminalCustomKey
    private var saveItem: UIBarButtonItem?

    init(key: SSHTerminalCustomKey, isNew: Bool, onSave: @escaping (SSHTerminalCustomKey) -> Void) {
        draft = key
        self.isNew = isNew
        self.onSave = onSave
        super.init(
            title: isNew ? String(localized: "New Custom Key") : String(localized: "Edit Custom Key"),
            listIdentifier: "settings.sshTerminal.bar.key.list",
            scope: .device,
            headers: true,
            footers: true,
            dismissesKeyboardOnDrag: true
        )
    }

    /// The combination is one the terminal can encode.
    var canSave: Bool { draft.isValid }

    override func viewDidLoad() {
        super.viewDidLoad()
        let cancel = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        cancel.accessibilityIdentifier = "settings.sshTerminal.bar.key.cancel"
        navigationItem.leftBarButtonItem = cancel
        let save = UIBarButtonItem(title: String(localized: "Save"), primaryAction: UIAction { [weak self] _ in
            self?.save()
        })
        save.style = .prominent
        save.accessibilityIdentifier = "settings.sshTerminal.bar.key.save"
        navigationItem.rightBarButtonItem = save
        saveItem = save
    }

    override func updateProperties() {
        super.updateProperties()
        saveItem?.isEnabled = canSave
    }

    /// The key as saved: its name trimmed.
    func finishedKey() -> SSHTerminalCustomKey {
        var key = draft
        key.name = key.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return key
    }

    func save() {
        guard canSave else { return }
        onSave(finishedKey())
        Router.finish(self)
    }

    private func change(_ edit: (inout SSHTerminalCustomKey) -> Void) {
        edit(&draft)
        setNeedsUpdateProperties()
    }

    /// What the key field typed: one character, as the keymap reads it.
    func setTyped(_ text: String) {
        change { $0.key = text.lowercased() }
    }

    // MARK: - Sections

    override func sections() -> [ListSection<Section, Item>] {
        let message: String
        if draft.key.isEmpty {
            message = String(localized: "Type a key, or pick a named one.")
        } else if !draft.isValid {
            message = String(localized: "Oppi can't send that key. Use a letter, a digit, one of - = [ ] \\ ; ' , . / `, or pick a named key.")
        } else {
            message = String(localized: "The button sends this combination, encoded as the program asks for keys.")
        }
        return [
            ListSection(.name, items: [.name]),
            ListSection(.combination, header: String(localized: "Key Combination"), items: [.modifiers, .key, .namedKey]),
            ListSection(.preview, header: String(localized: "Preview"), footer: message, items: [.preview]),
            ListSection(
                .showFor,
                header: String(localized: "Show for"),
                footer: String(localized: "The bar shows this key while this program is in front. A program reports itself to Oppi; Shell also covers Herdr and anything that does not report."),
                items: [.showFor]
            ),
        ]
    }

    /// Field rows keep what the person is typing; the rest follow the draft.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .name: AnyHashable(0)
        case .modifiers: AnyHashable([draft.control, draft.option, draft.shift])
        // Only a named key rewrites what was typed.
        case .key: AnyHashable(SSHTerminalCustomKey.NamedKey.named(draft.key)?.key ?? "")
        case .namedKey: AnyHashable(draft.key)
        case .preview: AnyHashable(draft)
        case .showFor: AnyHashable(draft.showFor)
        }
    }

    // MARK: - Cells

    private lazy var fieldRow = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        let style = SettingsStyle.current
        if item == .name {
            cell.configure(
                text: draft.name,
                placeholder: String(localized: "Optional"),
                identifier: "settings.sshTerminal.bar.key.name",
                label: String(localized: "Name"),
                autocapitalization: .words,
                autocorrection: .default,
                textColor: style.value,
                labelColor: style.title,
                onChange: { [weak self] text in self?.change { $0.name = text } }
            )
        } else {
            let typed = SSHTerminalCustomKey.NamedKey.named(draft.key) == nil ? draft.key : ""
            cell.configure(
                text: typed,
                placeholder: String(localized: "d"),
                identifier: "settings.sshTerminal.bar.key.key",
                label: String(localized: "Key"),
                monospaced: true,
                textColor: style.value,
                labelColor: style.title,
                maximumLength: 1,
                onChange: { [weak self] in self?.setTyped($0) }
            )
        }
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        if item == .namedKey {
            let none = SSHTerminalCustomKey.NamedKey(key: "", title: String(localized: "None"))
            let choices = [none] + SSHTerminalCustomKey.NamedKey.all
            let current = SSHTerminalCustomKey.NamedKey.named(draft.key) ?? none
            cell.configure(
                title: String(localized: "Named Key"),
                identifier: "settings.sshTerminal.bar.key.named",
                value: current.title,
                menu: UIMenu(children: choices.map { choice in
                    UIAction(title: choice.title, state: choice == current ? .on : .off) { [weak self] _ in
                        self?.change { $0.key = choice.key }
                    }
                })
            )
        } else {
            cell.configure(
                title: String(localized: "Show for"),
                identifier: "settings.sshTerminal.bar.key.showFor",
                options: SSHTerminalCustomKey.ShowFor.choices.map { choice in
                    (title: choice.title, selected: choice == draft.showFor, action: { [weak self] in
                        self?.change { $0.showFor = choice }
                    })
                }
            )
        }
    }

    private lazy var modifiersRow = UICollectionView.CellRegistration<SSHTerminalModifiersCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(control: draft.control, option: draft.option, shift: draft.shift) { [weak self] modifier, isOn in
            self?.change {
                switch modifier {
                case .control: $0.control = isOn
                case .option: $0.option = isOn
                case .shift: $0.shift = isOn
                }
            }
        }
    }

    override func prepareRegistrations() {
        _ = fieldRow
        _ = menuRow
        _ = modifiersRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .name, .key: collectionView.dequeueConfiguredReusableCell(using: fieldRow, for: indexPath, item: item)
        case .namedKey, .showFor: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .modifiers: collectionView.dequeueConfiguredReusableCell(using: modifiersRow, for: indexPath, item: item)
        case .preview: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .preview:
            let style = SettingsStyle.current
            var content = content(.subtitle)
            content.text = draft.isValid ? draft.chord : "\u{2014}"
            content.textProperties.font = UIFont.monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold
            )
            content.textProperties.color = draft.isValid ? style.title : style.value
            content.secondaryText = draft.isValid
                ? String(localized: "Key cap on the bar: \(draft.cap)")
                : String(localized: "Not a key the terminal can send")
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "settings.sshTerminal.bar.key.preview"
        case .name, .modifiers, .key, .namedKey, .showFor:
            break
        }
    }
}

/// The modifier row of the custom key form: Control, Option, and Shift as three
/// toggle buttons side by side, each filled while it is on. Each is a button
/// that reports `selected`, so a tap, VoiceOver, and a test act the same way.
final class SSHTerminalModifiersCell: UICollectionViewListCell {
    enum Modifier: CaseIterable {
        case control, option, shift

        var glyph: String {
            switch self {
            case .control: "\u{2303}"
            case .option: "\u{2325}"
            case .shift: "\u{21E7}"
            }
        }

        var name: String {
            switch self {
            case .control: String(localized: "Control")
            case .option: String(localized: "Option")
            case .shift: String(localized: "Shift")
            }
        }

        var identifier: String {
            switch self {
            case .control: "settings.sshTerminal.bar.key.control"
            case .option: "settings.sshTerminal.bar.key.option"
            case .shift: "settings.sshTerminal.bar.key.shift"
            }
        }
    }

    private var buttons: [Modifier: UIButton] = [:]
    private var onChange: ((Modifier, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        for modifier in Modifier.allCases {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = "\(modifier.glyph) \(modifier.name)"
            configuration.cornerStyle = .capsule
            configuration.titleLineBreakMode = .byTruncatingTail
            let button = UIButton(configuration: configuration)
            button.changesSelectionAsPrimaryAction = true
            button.accessibilityIdentifier = modifier.identifier
            button.accessibilityLabel = modifier.name
            button.configurationUpdateHandler = { button in
                var configuration = button.configuration
                configuration?.background.backgroundColor = button.isSelected
                    ? SettingsStyle.current.accent : SettingsStyle.current.value.withAlphaComponent(0.12)
                configuration?.baseForegroundColor = button.isSelected ? .white : SettingsStyle.current.title
                button.configuration = configuration
            }
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let button else { return }
                self?.onChange?(modifier, button.isSelected)
            }, for: .primaryActionTriggered)
            buttons[modifier] = button
            stack.addArrangedSubview(button)
        }
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(control: Bool, option: Bool, shift: Bool, onChange: @escaping (Modifier, Bool) -> Void) {
        self.onChange = onChange
        for (modifier, isOn) in [(Modifier.control, control), (.option, option), (.shift, shift)] {
            buttons[modifier]?.isSelected = isOn
        }
    }
}
