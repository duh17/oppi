import UIKit

/// Shared logic between the inline Ask card and the expanded Ask sheet.
///
/// Display helpers and option selection live here. View-specific follow-through
/// (auto-advance, collapse, custom text clearing) goes through `onSingleSelect`.
enum AskCardShared {
    static func isOptionSelected(
        _ option: AskOption,
        in question: AskQuestion,
        answers: [String: AskAnswer]
    ) -> Bool {
        guard let answer = answers[question.id] else { return false }
        switch answer {
        case .single(let value):
            return value == option.value
        case .multi(let values):
            return values.contains(option.value)
        case .custom:
            return false
        }
    }

    static func multiSelectCount(
        for question: AskQuestion,
        answers: [String: AskAnswer]
    ) -> Int? {
        guard case .multi(let values) = answers[question.id] else { return nil }
        return values.count
    }

    static func selectionModeHint(for question: AskQuestion) -> String? {
        question.multiSelect ? "Select multiple" : nil
    }

    /// Multi-select toggles the value in the set. Single-select sets the answer
    /// and calls `onSingleSelect` so the caller can auto-advance or collapse.
    static func handleOptionTap(
        _ option: AskOption,
        question: AskQuestion,
        answers: inout [String: AskAnswer],
        onSingleSelect: () -> Void
    ) {
        AppHaptics.selectionChanged()

        if question.multiSelect {
            var current: Set<String>
            if case .multi(let existing) = answers[question.id] {
                current = existing
            } else {
                current = []
            }

            if current.contains(option.value) {
                current.remove(option.value)
            } else {
                current.insert(option.value)
            }
            answers[question.id] = current.isEmpty ? nil : .multi(current)
        } else {
            answers[question.id] = .single(option.value)
            onSingleSelect()
        }
    }
}

/// "Select multiple" capsule under a multi-select question.
final class AskSelectionModePillView: UIView {
    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "ask.selectionMode.multi"
        isAccessibilityElement = true
        let font = UIFont.scaled(.caption2, .semibold)
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font)
        iconView.image = UIImage(systemName: "checkmark.square")
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        label.font = font
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        layer.cornerCurve = .continuous
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func apply(question: AskQuestion, colors: ComposerThemeColors) {
        let hint = AskCardShared.selectionModeHint(for: question)
        isHidden = hint == nil
        label.text = hint
        accessibilityLabel = hint
        label.textColor = colors.blue
        iconView.tintColor = colors.blue
        backgroundColor = colors.blue.withAlphaComponent(0.12)
    }
}

/// One Ask option: a full-width row whose height follows its title and
/// description, so long multi-line options never clip. Multi-select rows lead
/// with a checkbox; a selected single-select row shows a trailing checkmark.
/// Selection also tints the fill and stroke, so the state does not rest on
/// the glyph alone.
final class AskOptionChoiceRowView: UIControl {
    enum Density {
        /// Inside the composer's Ask card.
        case inline
        /// In the expanded Ask sheet.
        case expanded

        @MainActor fileprivate var titleFont: UIFont {
            switch self {
            case .inline: UIFont.scaled(.subheadline, .semibold)
            case .expanded: UIFont.scaled(.body, .semibold)
            }
        }

        fileprivate var descriptionStyle: UIFont.TextStyle {
            switch self {
            case .inline: .footnote
            case .expanded: .subheadline
            }
        }

        fileprivate var insets: NSDirectionalEdgeInsets {
            switch self {
            case .inline: NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            case .expanded: NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
            }
        }

        /// One title line plus insets; a 44 pt touch target either way.
        fileprivate var minimumHeight: CGFloat {
            switch self {
            case .inline: 44
            case .expanded: 50
            }
        }
    }

    var onTap: (() -> Void)?

    private let density: Density
    private let checkbox = AskMultiSelectCheckboxView()
    private let titleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let checkView = UIImageView()
    private let checkboxSlot = UIView()
    private let checkSlot = UIView()
    private var slotHeights: [NSLayoutConstraint] = []
    private var colors = ComposerThemeColors.placeholder
    private var isMultiSelect = false
    private var optionSelected = false

    init(density: Density) {
        self.density = density
        super.init(frame: .zero)
        titleLabel.font = density.titleFont
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.font = UIFont.preferredFont(forTextStyle: density.descriptionStyle)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.numberOfLines = 0
        descriptionLabel.lineBreakMode = .byWordWrapping
        for label in [titleLabel, descriptionLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        checkView.contentMode = .center
        checkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: density.titleFont)
        checkView.image = UIImage(systemName: "checkmark")
        checkView.setContentHuggingPriority(.required, for: .horizontal)
        checkView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, descriptionLabel])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 3
        // Each glyph sits in a slot one title line tall, so it centers on the
        // title's first line however many lines the title wraps to.
        for (glyph, slot) in [(checkbox, checkboxSlot), (checkView, checkSlot)] as [(UIView, UIView)] {
            glyph.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                slot.widthAnchor.constraint(equalTo: glyph.widthAnchor),
            ])
        }
        let rowStack = UIStackView(arrangedSubviews: [checkboxSlot, textStack, checkSlot])
        rowStack.axis = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 12
        rowStack.isUserInteractionEnabled = false
        rowStack.isLayoutMarginsRelativeArrangement = true
        rowStack.directionalLayoutMargins = density.insets
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: density.minimumHeight)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            minimumHeight,
            checkbox.widthAnchor.constraint(equalToConstant: AskMultiSelectCheckboxView.side),
            checkbox.heightAnchor.constraint(equalToConstant: AskMultiSelectCheckboxView.side),
        ])
        slotHeights = [checkboxSlot, checkSlot].map { $0.heightAnchor.constraint(equalToConstant: 20) }
        NSLayoutConstraint.activate(slotHeights)
        updateSlotHeights()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (row: Self, _) in
            row.updateSlotHeights()
        }
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            defer { self.releasedOutside = false }
            guard !self.releasedOutside else { return }
            self.onTap?()
        }, for: .touchUpInside)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// UIControl counts a release up to ~70 pt outside as inside. A single
    /// choice can send on tap, so a finger that slides off the row cancels,
    /// as it does on a native list row.
    private var releasedOutside = false

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let keepsTracking = super.continueTracking(touch, with: event)
        let inside = bounds.contains(touch.location(in: self))
        if isHighlighted != inside { isHighlighted = inside }
        return keepsTracking
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        releasedOutside = touches.first.map { !bounds.contains($0.location(in: self)) } ?? false
        super.touchesEnded(touches, with: event)
        releasedOutside = false
    }

    override var isHighlighted: Bool {
        didSet { applyFill(animated: true) }
    }

    private func updateSlotHeights() {
        let lineHeight = ceil(titleLabel.font.lineHeight)
        for constraint in slotHeights { constraint.constant = lineHeight }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.5 }
    }

    func apply(
        option: AskOption,
        isSelected: Bool,
        isMultiSelect: Bool,
        colors: ComposerThemeColors
    ) {
        self.colors = colors
        self.isMultiSelect = isMultiSelect
        optionSelected = isSelected
        titleLabel.text = option.label
        titleLabel.textColor = colors.fg
        let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        descriptionLabel.text = description
        descriptionLabel.isHidden = description.isEmpty
        descriptionLabel.textColor = colors.comment
        // Multi-select leads with a checkbox. Single-select keeps its trailing
        // slot even while unselected, so selecting never rewraps the title.
        checkboxSlot.isHidden = !isMultiSelect
        checkSlot.isHidden = isMultiSelect
        checkbox.apply(
            isSelected: isSelected,
            colors: colors,
            onFill: ComposerColorContrast.foreground(for: colors.blue, fg: colors.fg, bg: colors.bg)
        )
        checkView.isHidden = !isSelected
        checkView.tintColor = colors.blue
        applyFill(animated: false)

        accessibilityIdentifier = "ask.option.\(option.value)"
        accessibilityLabel = description.isEmpty ? option.label : "\(option.label). \(description)"
        accessibilityValue = isMultiSelect
            ? (isSelected ? "Selected, multi-select" : "Not selected, multi-select")
            : (isSelected ? "Selected" : "Not selected")
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    private func applyFill(animated: Bool) {
        let fill: UIColor
        if optionSelected {
            fill = colors.blue.withAlphaComponent(isHighlighted ? 0.24 : 0.14)
        } else {
            fill = isHighlighted ? colors.comment.withAlphaComponent(0.22) : colors.bgHighlight
        }
        let stroke = optionSelected
            ? colors.blue.withAlphaComponent(0.6)
            : colors.comment.withAlphaComponent(0.16)
        let update = {
            self.backgroundColor = fill
            self.layer.borderColor = stroke.cgColor
            self.layer.borderWidth = self.optionSelected ? 1.5 : 1
        }
        if animated {
            UIView.animate(withDuration: isHighlighted ? 0.08 : 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: update)
        } else {
            update()
        }
    }
}

private final class AskMultiSelectCheckboxView: UIView {
    static let side: CGFloat = 22

    private let checkView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        checkView.contentMode = .center
        checkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        checkView.image = UIImage(systemName: "checkmark")
        checkView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkView)
        NSLayoutConstraint.activate([
            checkView.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(isSelected: Bool, colors: ComposerThemeColors, onFill: UIColor) {
        backgroundColor = isSelected ? colors.blue : .clear
        layer.borderColor = (isSelected ? colors.blue : colors.comment.withAlphaComponent(0.7)).cgColor
        checkView.isHidden = !isSelected
        checkView.tintColor = onFill
    }
}
