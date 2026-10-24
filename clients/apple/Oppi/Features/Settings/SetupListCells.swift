import UIKit

/// One row of the Tailscale and Set Up a Computer lists: an optional leading
/// symbol or spinner, a title, secondary lines, an optional trailing badge or
/// spinner, and at most one action.
///
/// The action is either the whole row (`rowAction`, a disclosure row that
/// pushes) or an inline button under the text (`button`). Both are real
/// buttons, so a tap, a VoiceOver activation, and `app.buttons[id]` run the
/// same closure. A row without an action reads as one element.
struct SetupRow {
    enum Leading {
        case none
        case symbol(String, UIColor)
        case spinner
    }

    enum Trailing {
        case none
        case spinner
        case badge(String, symbol: String, color: UIColor)
    }

    struct Line {
        var text: String
        var color: UIColor
        var symbol: String? = nil
        var font: UIFont = .preferredFont(forTextStyle: .footnote)
    }

    struct Button {
        var title: String
        var identifier: String
        var color: UIColor
        var enabled = true
        var action: () -> Void
    }

    var leading: Leading = .none
    var title: String
    var titleColor: UIColor
    var lines: [Line] = []
    var trailing: Trailing = .none
    var button: Button?
    /// Whole-row action with a disclosure chevron.
    var rowAction: (identifier: String, action: () -> Void)?
    /// Identifier for a row without an action.
    var identifier: String?
    /// Spoken instead of the painted text, e.g. "mac-mini, checking for Oppi".
    var accessibilityLabel: String?
}

final class SetupRowCell: UICollectionViewListCell {
    private let leadingIcon = UIImageView()
    private let leadingSpinner = UIActivityIndicatorView(style: .medium)
    private let leadingSlot = UIView()
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let inlineButton = UIButton(type: .system)
    private let overlay = SettingsRowButton(type: .system)
    private var inlineAction: UIAction?
    private var overlayAction: UIAction?
    private var leadingWidth: NSLayoutConstraint?
    private var textLeading: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        leadingSlot.translatesAutoresizingMaskIntoConstraints = false
        leadingIcon.translatesAutoresizingMaskIntoConstraints = false
        leadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        leadingIcon.contentMode = .scaleAspectFit
        leadingIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        leadingSlot.addSubview(leadingIcon)
        leadingSlot.addSubview(leadingSpinner)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        textStack.addArrangedSubview(titleLabel)
        var buttonConfig = UIButton.Configuration.plain()
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0)
        inlineButton.configuration = buttonConfig
        inlineButton.contentHorizontalAlignment = .leading
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        overlay.accessibilityTraits = .button
        for view in [leadingSlot, textStack, overlay] as [UIView] {
            contentView.addSubview(view)
        }
        let margins = contentView.layoutMarginsGuide
        let width = leadingSlot.widthAnchor.constraint(equalToConstant: 24)
        leadingWidth = width
        let leading = textStack.leadingAnchor.constraint(equalTo: leadingSlot.trailingAnchor, constant: 12)
        textLeading = leading
        NSLayoutConstraint.activate([
            // The symbol sits beside the title's first line, not the row's middle.
            leadingSlot.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            leadingSlot.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -5),
            leadingSlot.heightAnchor.constraint(equalToConstant: 24),
            width,
            leadingIcon.centerXAnchor.constraint(equalTo: leadingSlot.centerXAnchor),
            leadingIcon.centerYAnchor.constraint(equalTo: leadingSlot.centerYAnchor),
            leadingSpinner.centerXAnchor.constraint(equalTo: leadingSlot.centerXAnchor),
            leadingSpinner.centerYAnchor.constraint(equalTo: leadingSlot.centerYAnchor),
            leading,
            textStack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ row: SetupRow) {
        switch row.leading {
        case .none:
            leadingIcon.image = nil
            leadingSpinner.stopAnimating()
        case .symbol(let name, let color):
            leadingIcon.image = UIImage(systemName: name)
            leadingIcon.tintColor = color
            leadingSpinner.stopAnimating()
        case .spinner:
            leadingIcon.image = nil
            leadingSpinner.startAnimating()
        }
        let hasLeading: Bool
        if case .none = row.leading { hasLeading = false } else { hasLeading = true }
        leadingWidth?.constant = hasLeading ? 24 : 0
        textLeading?.constant = hasLeading ? 12 : 0

        // The title stays; the lines and the inline button are rebuilt.
        textStack.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        titleLabel.text = row.title
        titleLabel.textColor = row.titleColor
        for line in row.lines {
            textStack.addArrangedSubview(Self.label(for: line))
        }

        if let inlineAction {
            inlineButton.removeAction(inlineAction, for: .touchUpInside)
            self.inlineAction = nil
        }
        if let button = row.button {
            var config = inlineButton.configuration ?? .plain()
            config.title = button.title
            config.baseForegroundColor = button.enabled ? button.color : button.color.withAlphaComponent(0.4)
            inlineButton.configuration = config
            inlineButton.isEnabled = button.enabled
            inlineButton.accessibilityIdentifier = button.identifier
            let action = UIAction { _ in button.action() }
            inlineAction = action
            inlineButton.addAction(action, for: .touchUpInside)
            textStack.addArrangedSubview(inlineButton)
        }

        switch row.trailing {
        case .none:
            accessories = []
        case .spinner:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        case .badge(let text, let symbol, let color):
            let badge = UIButton(configuration: .plain())
            var config = UIButton.Configuration.plain()
            config.title = text
            config.image = UIImage(systemName: symbol)
            config.imagePadding = 4
            config.baseForegroundColor = color
            config.contentInsets = .zero
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .preferredFont(forTextStyle: .footnote)
                return outgoing
            }
            badge.configuration = config
            badge.isUserInteractionEnabled = false
            // The row's own label already says "Paired".
            badge.accessibilityElementsHidden = true
            accessories = [.customView(configuration: .init(customView: badge, placement: .trailing()))]
        }

        let spoken = row.accessibilityLabel
            ?? ([row.title] + row.lines.map(\.text)).joined(separator: ", ")
        if let overlayAction {
            overlay.removeAction(overlayAction, for: .touchUpInside)
            self.overlayAction = nil
        }
        if let rowAction = row.rowAction {
            overlay.isHidden = false
            overlay.accessibilityIdentifier = rowAction.identifier
            overlay.accessibilityLabel = spoken
            let action = UIAction { _ in rowAction.action() }
            overlayAction = action
            overlay.addAction(action, for: .touchUpInside)
            accessories.append(.disclosureIndicator())
            contentView.isAccessibilityElement = false
            contentView.accessibilityElements = [overlay]
        } else if row.button != nil {
            overlay.isHidden = true
            contentView.isAccessibilityElement = false
            contentView.accessibilityElements = [
                SetupRowTextElement(label: spoken, container: contentView, anchor: titleLabel),
                inlineButton,
            ]
        } else {
            // One element reads the whole row and carries its identifier. The
            // list exposes the content view's elements, not the cell's.
            overlay.isHidden = true
            contentView.accessibilityElements = nil
            contentView.isAccessibilityElement = true
            contentView.accessibilityLabel = spoken
            contentView.accessibilityIdentifier = row.identifier
            contentView.accessibilityTraits = .staticText
        }
    }

    private static func label(for line: SetupRow.Line) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.textColor = line.color
        if let symbol = line.symbol {
            let text = NSMutableAttributedString()
            let attachment = NSTextAttachment(image: UIImage(systemName: symbol)?.withTintColor(line.color, renderingMode: .alwaysOriginal) ?? UIImage())
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " " + line.text))
            text.addAttributes([.font: line.font, .foregroundColor: line.color], range: NSRange(location: 0, length: text.length))
            label.attributedText = text
        } else {
            label.font = line.font
            label.text = line.text
        }
        return label
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let inlineAction {
            inlineButton.removeAction(inlineAction, for: .touchUpInside)
            self.inlineAction = nil
        }
        if let overlayAction {
            overlay.removeAction(overlayAction, for: .touchUpInside)
            self.overlayAction = nil
        }
        overlay.accessibilityIdentifier = nil
        overlay.accessibilityLabel = nil
        inlineButton.accessibilityIdentifier = nil
        contentView.isAccessibilityElement = false
        contentView.accessibilityIdentifier = nil
        contentView.accessibilityLabel = nil
        contentView.accessibilityElements = nil
        accessories = []
        leadingSpinner.stopAnimating()
        isHighlighted = false
    }
}

/// Headers and footers of the setup lists, kept current without reloading
/// their sections: a section reload rebuilds its rows, which moves VoiceOver
/// focus off a row the person was on.
@MainActor
enum SetupListSupplementaries {
    /// Runs `configure` again on every visible header and footer (diffable
    /// reconfigure leaves them alone) and re-measures those whose text changed.
    /// Off-screen ones are configured when they are dequeued.
    static func refresh(
        _ collectionView: UICollectionView,
        configure: (UICollectionViewListCell, _ kind: String, IndexPath) -> Void
    ) {
        let context = UICollectionViewLayoutInvalidationContext()
        var changed = false
        for kind in [UICollectionView.elementKindSectionHeader, UICollectionView.elementKindSectionFooter] {
            var paths: [IndexPath] = []
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell else { continue }
                let before = view.contentConfiguration as? UIListContentConfiguration
                configure(view, kind, indexPath)
                let after = view.contentConfiguration as? UIListContentConfiguration
                if before?.text != after?.text || before?.textProperties.color != after?.textProperties.color {
                    paths.append(indexPath)
                }
            }
            if !paths.isEmpty {
                context.invalidateSupplementaryElements(ofKind: kind, at: paths)
                changed = true
            }
        }
        if changed { collectionView.collectionViewLayout.invalidateLayout(with: context) }
    }
}

/// The text of a row that also has an inline button: one element that reads
/// the row, beside the button.
private final class SetupRowTextElement: UIAccessibilityElement {
    private weak var anchor: UIView?

    init(label: String, container: UIView, anchor: UIView) {
        self.anchor = anchor
        super.init(accessibilityContainer: container)
        accessibilityLabel = label
        accessibilityTraits = .staticText
    }

    override var accessibilityFrame: CGRect {
        get { anchor.map { UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0) } ?? .zero }
        set {}
    }
}

/// An enrollment waiting on the user's other device: a spinner, what is
/// happening, a once-a-second countdown, and Cancel. The UIKit form of
/// `WaitingForPairingApprovalView`, with the same identifiers.
final class PairingWaitRowCell: UICollectionViewListCell {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let countdownLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private var cancelAction: UIAction?
    private var timer: Timer?
    private var expiresAt: Int64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, countdownLabel, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        spinner.startAnimating()
        messageLabel.text = String(localized: "Waiting for approval on your other device")
        messageLabel.font = .preferredFont(forTextStyle: .headline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.accessibilityIdentifier = "pairing.waiting.message"
        countdownLabel.font = .preferredFont(forTextStyle: .subheadline)
        countdownLabel.adjustsFontForContentSizeCategory = true
        countdownLabel.accessibilityIdentifier = "pairing.waiting.countdown"
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "Cancel")
        cancelButton.configuration = config
        cancelButton.accessibilityIdentifier = "pairing.waiting.cancel"
        accessibilityIdentifier = "pairing.waiting"
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { timer?.invalidate() }

    func configure(expiresAt: Int64, fg: UIColor, comment: UIColor, onCancel: @escaping () -> Void) {
        self.expiresAt = expiresAt
        messageLabel.textColor = fg
        countdownLabel.textColor = comment
        if let cancelAction { cancelButton.removeAction(cancelAction, for: .touchUpInside) }
        let action = UIAction { _ in onCancel() }
        cancelAction = action
        cancelButton.addAction(action, for: .touchUpInside)
        tick()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        countdownLabel.text = WaitingForPairingApprovalView.countdown(until: expiresAt, now: Date())
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        timer = nil
        if let cancelAction {
            cancelButton.removeAction(cancelAction, for: .touchUpInside)
            self.cancelAction = nil
        }
    }
}
