import UIKit

/// A multi-line text row for a Workspace Settings draft (Allowed Hosts): one
/// text view in the card, at least 120 pt tall, that grows with its text.
/// Typing reports the text to `onChange` and asks the list to re-measure the
/// row, then keeps the caret in view.
///
/// The text view is the row's accessibility element and carries `identifier`.
final class WorkspaceTextEditorCell: UICollectionViewListCell, UITextViewDelegate {
    static let minimumHeight: CGFloat = 120

    let textView = UITextView()
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .scaledMonospaced(.body)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        textView.delegate = self
        contentView.addSubview(textView)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
        ])
        accessibilityElements = [textView]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A text view being typed in keeps its text: a redraw of the row must not
    /// move the caret or undo what the person just typed.
    func configure(
        text: String,
        identifier: String,
        label: String,
        onChange: @escaping (String) -> Void
    ) {
        self.onChange = onChange
        if !textView.isFirstResponder, textView.text != text { textView.text = text }
        textView.textColor = SettingsStyle.current.title
        textView.tintColor = SettingsStyle.current.accent
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.accessibilityIdentifier = identifier
        textView.accessibilityLabel = label
    }

    func textViewDidChange(_ textView: UITextView) {
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
