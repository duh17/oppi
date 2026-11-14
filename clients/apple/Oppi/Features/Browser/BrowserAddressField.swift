import UIKit

/// The browser pane's address field, as Safari's: idle, it shows the page's
/// host (and port, which tells dev servers apart) centred, with Reload, or
/// Stop while the page loads, at its trailing end. A tap shows the whole
/// address, selected, with the keyboard up. Go hands the text to the pane;
/// Cancel, Escape, or leaving the field puts the host back.
///
/// It sits in the pane's bar as its title view and takes the width the bar's
/// buttons leave it.
final class BrowserAddressField: UIView {
    static let height: CGFloat = 36

    /// Go: the pane loads `text`, or says why it cannot; true ends editing.
    var onSubmit: (String) -> Bool = { _ in true }
    /// Editing began (true) or ended (false).
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onReloadOrStop: () -> Void = {}

    let textField = UITextField()
    private let reloadButton = UIButton(type: .system)
    private var address: URL?
    private var isLoading = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous

        textField.borderStyle = .none
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.textAlignment = .center
        textField.keyboardType = .URL
        textField.returnKeyType = .go
        textField.textContentType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartInsertDeleteType = .no
        textField.enablesReturnKeyAutomatically = true
        textField.clearButtonMode = .whileEditing
        textField.placeholder = String(localized: "Website address")
        textField.accessibilityIdentifier = "browser.address"
        textField.accessibilityLabel = String(localized: "Address")
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        reloadButton.addAction(UIAction { [weak self] _ in self?.onReloadOrStop() }, for: .primaryActionTriggered)
        reloadButton.accessibilityIdentifier = "browser.reload"
        reloadButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium), forImageIn: .normal
        )
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reloadButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            reloadButton.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 2),
            reloadButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        show(address: nil, loading: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Takes the width the bar leaves between its buttons.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.layoutFittingExpandedSize.width, height: Self.height)
    }

    var isEditing: Bool { textField.isEditing }

    /// The page the pane shows (nil before it has one) and whether it loads.
    /// While the person edits, their text stays.
    func show(address: URL?, loading: Bool) {
        self.address = address
        isLoading = loading
        reloadButton.setImage(UIImage(systemName: loading ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = loading ? String(localized: "Stop") : String(localized: "Reload")
        reloadButton.isHidden = address == nil || textField.isEditing
        guard !textField.isEditing else { return }
        textField.text = address.map(Self.idleText)
    }

    func beginEditing() {
        textField.becomeFirstResponder()
    }

    /// Ends editing and puts the page's host back.
    @objc func cancelEditing() {
        textField.resignFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        guard textField.isEditing else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelEditing))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    /// What the field shows at rest: the host without a leading `www.`, and
    /// the port when the address names one.
    static func idleText(_ url: URL) -> String {
        guard var host = url.host(percentEncoded: false), !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        if host.contains(":") { host = "[\(host)]" }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

extension BrowserAddressField: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.textAlignment = .natural
        textField.text = address?.absoluteString
        reloadButton.isHidden = true
        onEditingChanged(true)
        // Selected, so typing replaces it, as in Safari; after this turn, or
        // the field's own caret placement undoes it.
        DispatchQueue.main.async { [weak textField] in
            guard let textField, textField.isEditing else { return }
            textField.selectedTextRange = textField.textRange(from: textField.beginningOfDocument, to: textField.endOfDocument)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.textAlignment = .center
        show(address: address, loading: isLoading)
        onEditingChanged(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if onSubmit(textField.text ?? "") { textField.resignFirstResponder() }
        return false
    }
}
