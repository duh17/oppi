import UIKit

/// A multi-line text row for a Workspace Settings draft: an optional small
/// label, then one text view in the card that grows with its text (at least
/// `minimumHeight`). Typing reports the text to `onChange`, asks the list to
/// measure the row again, and keeps the caret in view. A long value (a path, a
/// description) wraps instead of clipping at a large text size.
///
/// A `singleParagraph` row is a one-line field that wraps: Return ends editing
/// (and runs `onReturn`) instead of adding a line, and a paste drops its line
/// breaks. The text view is the row's accessibility element and carries
/// `identifier`; the label above it is decorative.
final class WorkspaceTextEditorCell: UICollectionViewListCell, UITextViewDelegate {
    struct Style {
        var title: String?
        var placeholder: String?
        var monospaced = true
        var minimumHeight: CGFloat = 44
        var singleParagraph = false
        var returnKey: UIReturnKeyType = .default
        var autocapitalization: UITextAutocapitalizationType = .none
        var autocorrection: UITextAutocorrectionType = .no
    }

    let textView = UITextView()
    private let titleLabel = UILabel()
    private let placeholderLabel = UILabel()
    private var minimumHeight: NSLayoutConstraint?
    private var onChange: ((String) -> Void)?
    private var onReturn: (() -> Void)?
    private var singleParagraph = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.isAccessibilityElement = false
        placeholderLabel.numberOfLines = 0
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        let stack = UIStackView(arrangedSubviews: [titleLabel, textView])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        let height = textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimumHeight = height
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            height,
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: textView.textContainerInset.top),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
        ])
        accessibilityElements = [textView]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A text view being typed in keeps its text: a redraw of the row must not
    /// move the caret or undo what the person just typed.
    func configure(
        style: Style,
        text: String,
        identifier: String,
        label: String,
        onReturn: @escaping () -> Void = {},
        onChange: @escaping (String) -> Void
    ) {
        let colors = SettingsStyle.current
        self.onChange = onChange
        self.onReturn = onReturn
        singleParagraph = style.singleParagraph
        minimumHeight?.constant = style.minimumHeight
        titleLabel.text = style.title
        titleLabel.isHidden = style.title == nil
        titleLabel.textColor = colors.value
        let font: UIFont = style.monospaced ? .scaledMonospaced(.body) : .preferredFont(forTextStyle: .body)
        textView.font = font
        placeholderLabel.font = font
        placeholderLabel.text = style.placeholder
        placeholderLabel.textColor = colors.value
        if !textView.isFirstResponder, textView.text != text { textView.text = text }
        placeholderLabel.isHidden = style.placeholder == nil || !textView.text.isEmpty
        textView.textColor = colors.title
        textView.tintColor = colors.accent
        textView.autocapitalizationType = style.autocapitalization
        textView.autocorrectionType = style.autocorrection
        textView.spellCheckingType = style.autocorrection == .no ? .no : .default
        textView.returnKeyType = style.singleParagraph && style.returnKey == .default ? .done : style.returnKey
        textView.accessibilityIdentifier = identifier
        textView.accessibilityLabel = label
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard singleParagraph else { return true }
        if text == "\n" {
            textView.resignFirstResponder()
            onReturn?()
            return false
        }
        if text.contains(where: \.isNewline) {
            // A paste of several lines is one line here.
            let joined = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
               let end = textView.position(from: start, offset: range.length),
               let replaced = textView.textRange(from: start, to: end) {
                textView.replace(replaced, withText: joined)
            }
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = placeholderLabel.text == nil || !textView.text.isEmpty
        onChange?(textView.text)
        // The row grows with its text; the list measures it again.
        invalidateIntrinsicContentSize()
        scrollCaretIntoView()
    }

    private func scrollCaretIntoView() {
        guard let end = textView.selectedTextRange?.end,
              let list = superview as? UIScrollView else { return }
        let caret = textView.caretRect(for: end)
        list.scrollRectToVisible(list.convert(caret, from: textView).insetBy(dx: 0, dy: -8), animated: false)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        onReturn = nil
        textView.accessibilityIdentifier = nil
        textView.accessibilityLabel = nil
    }
}

/// A row that opens the workspace icon picker: "Icon" and the current icon at
/// the trailing edge. The whole row is one button, so a tap, a VoiceOver
/// activation, and `app.buttons[id]` all open the picker. Like
/// `SettingsIndexRowCell` its labels paint the row and the button is its one
/// accessible element; the picker opens as a sheet, so there is no chevron.
final class WorkspaceIconRowCell: UICollectionViewListCell {
    private let button = SettingsRowButton(type: .system)
    private let titleLabel = UILabel()
    private let icon = IconChoiceUIView(size: 22, frameSize: 32)

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [titleLabel, icon, button] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        button.accessibilityTraits = .button
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            icon.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        choice: IconChoice,
        assetCache: IconAssetCache?,
        identifier: String,
        label: String,
        value: String,
        hint: String,
        action: @escaping () -> Void
    ) {
        let palette = ThemeRuntimeState.currentPalette()
        titleLabel.text = title
        titleLabel.textColor = SettingsStyle.current.title
        icon.apply(
            .choice(choice, purpose: .workspace, sandbox: false),
            colors: ComposerThemeColors(palette: palette),
            assetCache: assetCache
        )
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.accessibilityValue = value
        button.accessibilityHint = hint
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        button.accessibilityHint = nil
        titleLabel.text = nil
        isHighlighted = false
    }
}

/// Keeps a list's bottom inset equal to how far the keyboard covers it, so the
/// field being typed in stays on screen. Create it once the list is in the
/// view; call `update()` from `viewDidLayoutSubviews()`, which the keyboard's
/// layout guide triggers as it moves.
@MainActor
final class KeyboardContentInset {
    private weak var view: UIView?
    private weak var scrollView: UIScrollView?

    init(view: UIView, scrollView: UIScrollView) {
        self.view = view
        self.scrollView = scrollView
        scrollView.keyboardDismissMode = .interactive
        // A zero-height view on the guide's top edge: its frame changes with
        // the keyboard, which lays the screen out again.
        let probe = UIView()
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        view.addSubview(probe)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            probe.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            probe.widthAnchor.constraint(equalToConstant: 0),
            probe.heightAnchor.constraint(equalToConstant: 0),
            probe.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    func update() {
        guard let view, let scrollView else { return }
        let covered = max(0, view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
        // The list already insets for the home indicator's safe area.
        let inset = max(0, covered - view.safeAreaInsets.bottom)
        guard scrollView.contentInset.bottom != inset else { return }
        scrollView.contentInset.bottom = inset
        scrollView.verticalScrollIndicatorInsets.bottom = inset
    }
}

/// A one-line text field row: a small label above the field, so a long value
/// (a description, a path) has the row's whole width and the label never
/// squeezes it at a large text size. The field is the row's accessibility
/// element and carries `identifier`; the label above it is decorative.
final class WorkspaceFieldCell: UICollectionViewListCell {
    let textField = UITextField()
    private let titleLabel = UILabel()
    private var onChange: ((String) -> Void)?
    private var onReturn: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.isAccessibilityElement = false
        textField.adjustsFontForContentSizeCategory = true
        textField.clearButtonMode = .never
        textField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(textField.text ?? "")
        }, for: .editingChanged)
        // Return ends editing, then moves on.
        textField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            textField.resignFirstResponder()
            onReturn?()
        }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [titleLabel, textField])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityElements = [textField]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A field being typed in keeps its text: a redraw of the row must not
    /// move the caret or undo what the person just typed.
    func configure(
        title: String?,
        accessibilityLabel: String,
        text: String,
        placeholder: String,
        identifier: String,
        monospaced: Bool = false,
        autocapitalization: UITextAutocapitalizationType = .none,
        autocorrection: UITextAutocorrectionType = .no,
        returnKey: UIReturnKeyType,
        onReturn: @escaping () -> Void,
        onChange: @escaping (String) -> Void
    ) {
        let style = SettingsStyle.current
        self.onChange = onChange
        self.onReturn = onReturn
        titleLabel.text = title
        titleLabel.isHidden = title == nil
        titleLabel.textColor = style.value
        if !textField.isFirstResponder, textField.text != text { textField.text = text }
        textField.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: style.value])
        textField.font = monospaced ? .scaledMonospaced(.body) : .preferredFont(forTextStyle: .body)
        textField.textColor = style.title
        textField.tintColor = style.accent
        textField.autocapitalizationType = autocapitalization
        textField.autocorrectionType = autocorrection
        textField.returnKeyType = returnKey
        textField.accessibilityIdentifier = identifier
        textField.accessibilityLabel = accessibilityLabel
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        onReturn = nil
        textField.accessibilityIdentifier = nil
        textField.accessibilityLabel = nil
    }
}
