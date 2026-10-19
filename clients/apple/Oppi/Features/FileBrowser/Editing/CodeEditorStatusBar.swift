import UIKit

/// The editor's status line: Vim mode and pending keys on the leading side,
/// then any message, then Ln/Col (tap for Go to Line), indentation, and
/// language. `:`, `/`, and `?` swap it for a one-line command field.
final class CodeEditorStatusBar: UIView, UITextFieldDelegate {
    var onCommand: (Character, String) -> Void = { _, _ in }
    var onCommandEnded: () -> Void = {}
    var onGoToLine: () -> Void = {}

    private let modeLabel = PaddedLabel()
    private let pendingLabel = UILabel()
    private let messageLabel = UILabel()
    private let positionButton = UIButton(type: .system)
    private let detailLabel = UILabel()
    private let row = UIStackView()
    private let field = CommandField()
    private let promptLabel = UILabel()
    private var prompt: Character = ":"
    private var accent = UIColor.systemBlue
    private var foreground = UIColor.label
    private var dim = UIColor.secondaryLabel

    static let height: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "workspace-file-editor.status-line"
        let small = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for label in [pendingLabel, messageLabel, detailLabel] {
            label.font = small
            label.lineBreakMode = .byTruncatingTail
        }
        modeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        modeLabel.layer.cornerRadius = 4
        modeLabel.layer.cornerCurve = .continuous
        modeLabel.clipsToBounds = true
        modeLabel.accessibilityIdentifier = "workspace-file-editor.vim-mode"
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)
        modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pendingLabel.setContentHuggingPriority(.required, for: .horizontal)
        pendingLabel.accessibilityIdentifier = "workspace-file-editor.vim-pending"
        messageLabel.accessibilityIdentifier = "workspace-file-editor.message"
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        positionButton.titleLabel?.font = small
        positionButton.accessibilityIdentifier = "workspace-file-editor.position"
        positionButton.accessibilityHint = String(localized: "Go to a line")
        positionButton.addAction(UIAction { [weak self] _ in self?.onGoToLine() }, for: .touchUpInside)
        positionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Only the message stretches; everything else keeps its own width.
        positionButton.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        for view in [modeLabel, pendingLabel, messageLabel, positionButton, detailLabel] as [UIView] {
            row.addArrangedSubview(view)
        }

        promptLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .go
        field.delegate = self
        field.isHidden = true
        field.accessibilityIdentifier = "workspace-file-editor.command-line"
        field.onEscape = { [weak self] in self?.endCommand() }
        field.leftView = promptLabel
        field.leftViewMode = .always

        for view in [row, field] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var isEditingCommand: Bool { !field.isHidden }

    func applyColors(background: UIColor, foreground: UIColor, dim: UIColor, accent: UIColor, divider: UIColor) {
        backgroundColor = background
        self.foreground = foreground
        self.dim = dim
        self.accent = accent
        pendingLabel.textColor = foreground
        messageLabel.textColor = foreground
        detailLabel.textColor = dim
        positionButton.tintColor = dim
        field.textColor = foreground
        field.tintColor = accent
        promptLabel.textColor = accent
        layer.borderColor = divider.cgColor
    }

    /// `mode` is nil with Standard keybindings, which hides the mode pill.
    func update(mode: VimMode?, pending: String, message: String?, line: Int, column: Int, detail: String) {
        if let mode {
            modeLabel.isHidden = false
            modeLabel.text = mode.label
            modeLabel.textColor = mode == .normal ? foreground : UIColor.black
            modeLabel.backgroundColor = switch mode {
            case .normal: foreground.withAlphaComponent(0.14)
            case .insert: accent
            case .visual, .visualLine: UIColor.systemOrange
            }
        } else {
            modeLabel.isHidden = true
        }
        pendingLabel.text = pending
        pendingLabel.isHidden = pending.isEmpty
        messageLabel.text = message ?? ""
        positionButton.setTitle(String(localized: "Ln \(line + 1), Col \(column + 1)"), for: .normal)
        positionButton.accessibilityLabel = String(localized: "Line \(line + 1), column \(column + 1)")
        detailLabel.text = detail
    }

    func beginCommand(_ prompt: Character) {
        self.prompt = prompt
        promptLabel.text = String(prompt) + " "
        promptLabel.sizeToFit()
        field.text = ""
        field.isHidden = false
        row.isHidden = true
        field.becomeFirstResponder()
    }

    func endCommand() {
        guard isEditingCommand else { return }
        field.isHidden = true
        row.isHidden = false
        field.resignFirstResponder()
        onCommandEnded()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let entry = textField.text ?? ""
        let prompt = self.prompt
        endCommand()
        onCommand(prompt, entry)
        return false
    }

    private final class CommandField: UITextField {
        var onEscape: () -> Void = {}

        override var keyCommands: [UIKeyCommand]? {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
            escape.wantsPriorityOverSystemBehavior = true
            return [escape]
        }

        @objc private func escape() { onEscape() }

        /// Backspace on an empty command line closes it, as in Vim.
        override func deleteBackward() {
            if (text ?? "").isEmpty {
                onEscape()
                return
            }
            super.deleteBackward()
        }
    }

    private final class PaddedLabel: UILabel {
        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + 10, height: size.height + 4)
        }

        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.insetBy(dx: 5, dy: 2))
        }
    }
}
