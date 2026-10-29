import UIKit

/// A growing text editor in an inset-grouped settings list, with a
/// placeholder, in the theme's title color. Past `maxHeight` it scrolls inside
/// the row. A page that holds one sets `collectionView.selfSizingInvalidation`
/// to `.enabledIncludingConstraints`, so the row grows with its text.
///
/// The editors of an Agent's system prompt and description, of a schedule's
/// prompt, and of the MCP add-server form. With `singleLine` it is a name
/// field: Return ends editing and a pasted line break becomes a space, and a
/// long name wraps at large text sizes instead of scrolling out of a field
/// (a `UITextField` cannot wrap).
final class SettingsTextViewRowCell: UICollectionViewListCell, UITextViewDelegate {
    static let verticalInsets: CGFloat = 22

    let textView = UITextView()
    private let placeholderLabel = UILabel()
    private var onChange: ((String) -> Void)?
    private var onCaretMove: ((UITextView) -> Void)?
    private var minHeight: NSLayoutConstraint?
    private var cappedHeight: NSLayoutConstraint?
    private var maxHeight: CGFloat?
    private var isSingleLine = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: Self.verticalInsets / 2, left: 0, bottom: Self.verticalInsets / 2, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        contentView.addSubview(textView)
        contentView.addSubview(placeholderLabel)
        let minHeight = textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let bottom = textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            bottom,
            minHeight,
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: Self.verticalInsets / 2),
        ])
        self.minHeight = minHeight
        accessibilityElements = [textView]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        text: String,
        placeholder: String,
        identifier: String,
        accessibilityLabel: String,
        minHeight: CGFloat,
        maxHeight: CGFloat?,
        singleLine: Bool = false,
        onChange: @escaping (String) -> Void,
        onCaretMove: @escaping (UITextView) -> Void
    ) {
        self.onChange = onChange
        self.onCaretMove = onCaretMove
        isSingleLine = singleLine
        textView.returnKeyType = singleLine ? .done : .default
        if !textView.isFirstResponder, textView.text != text {
            textView.text = text
        }
        let style = SettingsStyle.current
        textView.textColor = style.title
        textView.tintColor = style.accent
        textView.accessibilityIdentifier = identifier
        textView.accessibilityLabel = accessibilityLabel
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !textView.text.isEmpty
        self.minHeight?.constant = minHeight
        self.maxHeight = maxHeight
        updateScrolling()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard isSingleLine, text.contains(where: \.isNewline) else { return true }
        if text == "\n" {
            textView.resignFirstResponder()
            return false
        }
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        textView.textStorage.replaceCharacters(in: range, with: flattened)
        textView.selectedRange = NSRange(location: range.location + flattened.utf16.count, length: 0)
        textViewDidChange(textView)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateScrolling()
        onChange?(textView.text)
        onCaretMove?(textView)
    }

    /// Grows with its text up to `maxHeight`, then holds that height and scrolls.
    private func updateScrolling() {
        var scrolls = false
        if let maxHeight, textView.bounds.width > 0 {
            let fitting = textView.sizeThatFits(
                CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            ).height
            scrolls = fitting > maxHeight
            cappedHeight = cappedHeight ?? textView.heightAnchor.constraint(equalToConstant: maxHeight)
            cappedHeight?.constant = maxHeight
        }
        guard scrolls != textView.isScrollEnabled else { return }
        cappedHeight?.isActive = scrolls
        textView.isScrollEnabled = scrolls
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrolling()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        onCaretMove = nil
        textView.accessibilityIdentifier = nil
    }
}
