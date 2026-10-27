import UIKit

/// An action row: a title in the accent or destructive color, an optional
/// leading symbol, and an optional spinner while the work runs. The whole row
/// is one button, so a tap, a VoiceOver activation, and `app.buttons[id]` all
/// run the row's action. Like `SettingsIndexRowCell`, the labels paint the row
/// and the button above them is its one accessible element.
///
/// A row that can't be undone passes a `Confirmation`: an alert, or an action
/// sheet that anchors to the row as a popover on iPad. The action runs only
/// after the person confirms.
///
/// Titles follow the settings verbs: Remove unpairs from this device, Delete
/// destroys, Revoke ends a device's access, Forget drops local trust only.
final class SettingsActionRowCell: UICollectionViewListCell {
    enum Tint {
        /// Does something: connect, save, copy.
        case accent
        /// Deletes, disconnects, or removes.
        case destructive
    }

    /// What the person is asked before a row runs.
    struct Confirmation {
        enum Style { case alert, actionSheet }

        var title: String
        var message: String?
        /// The confirming button. It reads as destructive on a destructive row.
        var actionTitle: String
        var style: Style = .actionSheet
    }

    private let button = SettingsRowButton(type: .system)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private var titleAfterIcon: NSLayoutConstraint?
    private var titleAtMargin: NSLayoutConstraint?
    private var confirmation: Confirmation?
    private var tint: Tint = .accent
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [iconView, titleLabel, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        button.accessibilityTraits = .button
        accessibilityElements = [button]
        let afterIcon = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12)
        titleAfterIcon = afterIcon
        titleAtMargin = titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        NSLayoutConstraint.activate([
            afterIcon,
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        ])
        button.setTapAction { [weak self] in self?.activate() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// - Parameters:
    ///   - isEnabled: a disabled row reads dimmed and says so to VoiceOver.
    ///   - isBusy: shows a spinner and holds the row still while its work runs.
    func configure(
        title: String,
        systemImage: String? = nil,
        tint: Tint = .accent,
        identifier: String,
        isEnabled: Bool = true,
        isBusy: Bool = false,
        confirmation: Confirmation? = nil,
        action: @escaping () -> Void
    ) {
        let style = SettingsStyle.current
        let color = tint == .destructive ? style.destructive : style.accent
        let isActive = isEnabled && !isBusy
        self.tint = tint
        self.confirmation = confirmation
        self.action = action
        titleLabel.text = title
        titleLabel.textColor = isEnabled ? color : color.withAlphaComponent(0.4)
        iconView.image = systemImage.flatMap { UIImage(systemName: $0) }
        iconView.isHidden = systemImage == nil
        iconView.tintColor = titleLabel.textColor
        titleAfterIcon?.isActive = systemImage != nil
        titleAtMargin?.isActive = systemImage == nil
        if isBusy {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = style.value
            spinner.startAnimating()
            accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        } else {
            accessories = []
        }
        button.isEnabled = isActive
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.accessibilityValue = isBusy ? String(localized: "In progress") : nil
        button.accessibilityTraits = isActive ? .button : [.button, .notEnabled]
    }

    override func accessibilityActivate() -> Bool {
        guard button.isEnabled else { return false }
        activate()
        return true
    }

    private func activate() {
        guard let action else { return }
        guard let confirmation else {
            action()
            return
        }
        guard let owner = owningViewController else { return }
        let sheet = UIAlertController(
            title: confirmation.title,
            message: confirmation.message,
            preferredStyle: confirmation.style == .alert ? .alert : .actionSheet
        )
        sheet.addAction(UIAlertAction(
            title: confirmation.actionTitle,
            style: tint == .destructive ? .destructive : .default
        ) { _ in action() })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        // An action sheet is a popover on iPad, from the row that asked.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = bounds
        }
        Router.topPresenter(from: owner).present(sheet, animated: true)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        action = nil
        confirmation = nil
        accessories = []
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        iconView.image = nil
        titleLabel.text = nil
        isHighlighted = false
    }
}

/// A list's loading, empty, and failed rows, in one style: centered text in the
/// value color (the warning color for a failure), a spinner while loading, and
/// "Retry" under a failure that can be retried. A row with a retry is one
/// button; the others read as one line of text.
final class SettingsStateRowCell: UICollectionViewListCell {
    enum State {
        /// Work is running: a spinner and what it is doing.
        case loading(String)
        /// Nothing to show: no items, no matches, nothing online.
        case message(String)
        /// The work failed. `retry` runs it again and adds the Retry label.
        case failure(String, retry: (() -> Void)?)
    }

    static let retryTitle = String(localized: "Retry")

    private let button = SettingsRowButton(type: .system)
    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let textLabel = UILabel()
    private let retryLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        textLabel.font = .preferredFont(forTextStyle: .body)
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.numberOfLines = 0
        textLabel.textAlignment = .center
        retryLabel.font = .preferredFont(forTextStyle: .body)
        retryLabel.adjustsFontForContentSizeCategory = true
        retryLabel.text = Self.retryTitle
        for view in [spinner, textLabel, retryLabel] {
            stack.addArrangedSubview(view)
        }
        for view in [stack, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `identifier` is the button's: a row with a retry is `app.buttons[id]`,
    /// the others `app.staticTexts[id]`.
    func configure(_ state: State, identifier: String? = nil) {
        let style = SettingsStyle.current
        let text: String
        var retry: (() -> Void)?
        spinner.stopAnimating()
        spinner.isHidden = true
        switch state {
        case .loading(let message):
            text = message
            textLabel.textColor = style.value
            spinner.color = style.value
            spinner.isHidden = false
            spinner.startAnimating()
        case .message(let message):
            text = message
            textLabel.textColor = style.value
        case .failure(let message, let action):
            text = message
            textLabel.textColor = style.warning
            retry = action
        }
        textLabel.text = text
        retryLabel.textColor = style.accent
        retryLabel.isHidden = retry == nil
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = text
        button.isUserInteractionEnabled = retry != nil
        button.accessibilityTraits = retry == nil ? .staticText : .button
        button.accessibilityHint = retry == nil ? nil : Self.retryTitle
        button.setTapAction(retry)
    }

    override func accessibilityActivate() -> Bool {
        guard button.isUserInteractionEnabled else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityHint = nil
        textLabel.text = nil
        spinner.stopAnimating()
        isHighlighted = false
    }
}

private extension UIResponder {
    /// The view controller whose view this responder sits in.
    var owningViewController: UIViewController? {
        var responder = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
