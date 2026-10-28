import UIKit

/// A date or time row of the schedule editor: the title with the system's
/// compact date picker beside it, and under it at accessibility text sizes. The
/// picker is the row's one accessible element and carries its identifier.
final class ScheduleDateRowCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let picker = UIDatePicker()
    private let stack = UIStackView()
    private var onChange: ((Date) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Decorative: the picker carries the label.
        titleLabel.isAccessibilityElement = false
        picker.preferredDatePickerStyle = .compact
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(picker.date)
        }, for: .valueChanged)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(picker)
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityElements = [picker]
        arrangeForTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.arrangeForTextSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func arrangeForTextSize() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        stack.axis = stacked ? .vertical : .horizontal
        stack.alignment = stacked ? .leading : .center
    }

    func configure(
        title: String,
        mode: UIDatePicker.Mode,
        date: Date,
        timeZone: TimeZone,
        identifier: String,
        onChange: @escaping (Date) -> Void
    ) {
        self.onChange = onChange
        titleLabel.text = title
        titleLabel.textColor = SettingsStyle.current.title
        picker.datePickerMode = mode
        picker.timeZone = timeZone
        if picker.date != date { picker.date = date }
        picker.accessibilityLabel = title
        picker.accessibilityIdentifier = identifier
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
    }
}

/// The cron expression of a custom schedule: the field, its field names, and
/// either what is wrong with the expression or an example. The field and the
/// message are its accessible elements.
final class ScheduleCronRowCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let field = UITextField()
    private let fieldNames = UILabel()
    private let messageIcon = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private let messageLabel = UILabel()
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .medium))
        titleLabel.text = "Cron Expression"
        titleLabel.isAccessibilityElement = false
        field.font = .scaledMonospaced(.body)
        field.placeholder = "0 9 * * 1-5"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.accessibilityLabel = "Cron expression"
        field.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(field.text ?? "")
        }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.field.resignFirstResponder() }, for: .editingDidEndOnExit)
        // Caption 1, like the message under it: the accessibility audit reports the
        // smaller Caption 2 as partly unsupported Dynamic Type.
        fieldNames.font = .preferredFont(forTextStyle: .caption1)
        messageLabel.font = .preferredFont(forTextStyle: .caption1)
        messageIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        messageIcon.setContentHuggingPriority(.required, for: .horizontal)
        messageIcon.isAccessibilityElement = false
        for label in [titleLabel, fieldNames, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        field.adjustsFontForContentSizeCategory = true
        let message = UIStackView(arrangedSubviews: [messageIcon, messageLabel])
        message.spacing = 6
        message.alignment = .top
        let stack = UIStackView(arrangedSubviews: [titleLabel, field, fieldNames, message])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityElements = [field, fieldNames, messageLabel]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The row is laid out at the width it will have before its height is
    /// measured, so its wrapped lines are measured at the real width.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        if bounds.width != layoutAttributes.size.width {
            bounds.size.width = layoutAttributes.size.width
        }
        layoutIfNeeded()
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    func configure(
        expression: String,
        fieldLabels: String,
        hint: String,
        error: String?,
        guidance: String,
        identifier: String,
        onChange: @escaping (String) -> Void
    ) {
        let style = SettingsStyle.current
        self.onChange = onChange
        titleLabel.textColor = style.title
        if !field.isFirstResponder, field.text != expression { field.text = expression }
        field.textColor = style.title
        field.accessibilityHint = hint
        field.accessibilityIdentifier = identifier
        fieldNames.text = fieldLabels
        fieldNames.textColor = style.value
        messageIcon.isHidden = error == nil
        messageIcon.tintColor = style.destructive
        messageLabel.text = error ?? guidance
        messageLabel.textColor = error == nil ? style.value : style.destructive
        messageLabel.accessibilityIdentifier = error == nil ? nil : "schedule.nativeEdit.cronError"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
    }
}
