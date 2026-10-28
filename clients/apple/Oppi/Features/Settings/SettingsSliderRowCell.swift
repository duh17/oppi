import UIKit

/// A stepped slider that VoiceOver adjusts by one step, where `UISlider` adjusts
/// by a tenth of its range.
final class SettingsSteppedSlider: UISlider {
    var step: Float = 0.05
    /// The row the slider speaks for. Its title and value are drawn by labels
    /// outside the slider, so the slider's accessibility frame is the whole row:
    /// the text it names lies inside the one element that reads it, and the
    /// audit does not call that text inaccessible.
    weak var row: UIView?

    override var accessibilityFrame: CGRect {
        get {
            guard let row else { return super.accessibilityFrame }
            return UIAccessibility.convertToScreenCoordinates(row.bounds, in: row)
        }
        set { super.accessibilityFrame = newValue }
    }

    /// Activation stays on the track itself.
    override var accessibilityActivationPoint: CGPoint {
        get {
            UIAccessibility.convertToScreenCoordinates(CGRect(origin: CGPoint(x: bounds.midX, y: bounds.midY), size: .zero), in: self).origin
        }
        set { super.accessibilityActivationPoint = newValue }
    }

    override func accessibilityIncrement() { adjust(by: step) }
    override func accessibilityDecrement() { adjust(by: -step) }

    private func adjust(by delta: Float) {
        let next = min(max(value + delta, minimumValue), maximumValue)
        guard next != value else { return }
        value = next
        sendActions(for: .valueChanged)
    }
}

/// A slider row: a title with the current value (a percent) beside it, and
/// below them the slider with a small mark at its low end and a large one at
/// its high end. The slider is the row's one accessible element: it carries the
/// title as its label, the value as its value, and the identifier. At
/// accessibility text sizes the value sits under the title.
///
/// The slider moves in whole steps. `onChange` runs for each step the thumb
/// reaches, never twice for the same one, so a drag writes at most once per step.
final class SettingsSliderRowCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let header = UIStackView()
    private let slider = SettingsSteppedSlider()
    private var lastStepped: Float = 0
    private var onChange: ((Float) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular))
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(valueLabel)
        header.spacing = 8
        header.alignment = .firstBaseline
        let symbols = UIImage.SymbolConfiguration(textStyle: .body, scale: .small)
        slider.minimumValueImage = UIImage(systemName: "textformat.size.smaller", withConfiguration: symbols)
        slider.maximumValueImage = UIImage(systemName: "textformat.size.larger", withConfiguration: symbols)
        slider.isContinuous = true
        slider.addAction(UIAction { [weak self] _ in self?.sliderMoved() }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [header, slider])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // The labels paint the row; the slider is its one accessible element, and
        // its frame is the whole row.
        slider.row = self
        accessibilityElements = [slider]
        arrangeForTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.arrangeForTextSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func arrangeForTextSize() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        header.axis = stacked ? .vertical : .horizontal
        header.alignment = stacked ? .leading : .firstBaseline
    }

    /// - Parameters:
    ///   - valueText: what the label beside the title shows ("110%").
    ///   - spokenValue: what VoiceOver says for the value ("110 percent").
    func configure(
        title: String,
        valueText: String,
        spokenValue: String,
        value: Float,
        range: ClosedRange<Float>,
        step: Float,
        identifier: String,
        onChange: @escaping (Float) -> Void
    ) {
        let style = SettingsStyle.current
        self.onChange = onChange
        titleLabel.text = title
        titleLabel.textColor = style.title
        valueLabel.text = valueText
        valueLabel.textColor = style.value
        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.step = step
        slider.value = value
        lastStepped = value
        slider.minimumTrackTintColor = style.accent
        slider.tintColor = style.value
        slider.accessibilityIdentifier = identifier
        slider.accessibilityLabel = title
        slider.accessibilityValue = spokenValue
    }

    private func sliderMoved() {
        let step = slider.step
        let stepped = min(max((slider.value / step).rounded() * step, slider.minimumValue), slider.maximumValue)
        guard abs(stepped - lastStepped) > step / 2 else {
            // Between two steps: the thumb rests on the one it already has.
            slider.value = lastStepped
            return
        }
        lastStepped = stepped
        slider.value = stepped
        onChange?(stepped)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        slider.accessibilityIdentifier = nil
    }
}
