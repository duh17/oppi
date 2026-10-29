import UIKit

/// "Finish server setup" with a Configure Model Provider button: the card Usage shows
/// above its range control, and (inside `ProviderSetupPromptConfiguration`) the one All
/// Sessions shows as a list cell. The card paints its own rounded surface; the button's
/// identifier is the screen's (`server.providerSetup.open`, `workspace.providerSetup.open`).
@MainActor
final class ProviderSetupPromptView: UIView {
    private let stack = UIStackView()
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let button = UIButton(configuration: .borderedProminent())
    private var onConfigure: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.numberOfLines = 0
        titleLabel.font = UIFont.scaled(.headline, .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        for label in [titleLabel, messageLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { [weak self] _ in self?.onConfigure?() }, for: .touchUpInside)
        let buttonRow = UIStackView(arrangedSubviews: [button])
        buttonRow.axis = .vertical
        buttonRow.alignment = .center

        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        stack.layer.cornerRadius = 16
        stack.layer.cornerCurve = .continuous
        stack.layer.borderWidth = 1
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
        symbol.isAccessibilityElement = false
        let titleRow = UIStackView(arrangedSubviews: [symbol, titleLabel])
        titleRow.alignment = .top
        titleRow.spacing = 6
        [titleRow, messageLabel, buttonRow].forEach(stack.addArrangedSubview)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The labels wrap at the width the card gives them. Handing it over before the stack
    /// measures keeps a narrow phone at an accessibility text size from sizing them for the
    /// wider pass that came first, which drew them clipped (a label in a stack keeps the
    /// height it measured for the pass before).
    override func layoutSubviews() {
        let inner = max(0, bounds.width - stack.directionalLayoutMargins.leading - stack.directionalLayoutMargins.trailing)
        let title = max(0, inner - symbol.intrinsicContentSize.width - 6)
        if inner > 0, messageLabel.preferredMaxLayoutWidth != inner || titleLabel.preferredMaxLayoutWidth != title {
            messageLabel.preferredMaxLayoutWidth = inner
            titleLabel.preferredMaxLayoutWidth = title
        }
        super.layoutSubviews()
    }

    func apply(
        message: String,
        identifier: String,
        themeID: ThemeID,
        onConfigure: @escaping () -> Void
    ) {
        self.onConfigure = onConfigure
        let colors = SessionRowStyle.for(themeID).colors
        titleLabel.text = String(localized: "Finish server setup")
        titleLabel.textColor = colors.fg
        symbol.image = UIImage(systemName: "key.fill")
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline, scale: .default)
        symbol.tintColor = colors.fg
        messageLabel.text = message
        messageLabel.textColor = colors.comment
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = String(localized: "Configure Model Provider")
        configuration.buttonSize = .large
        configuration.baseBackgroundColor = colors.blue
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        stack.backgroundColor = colors.comment.withAlphaComponent(0.12)
        stack.layer.borderColor = colors.comment.withAlphaComponent(0.18).cgColor
    }
}

/// The card as an All Sessions cell, inset from the row edges. The list gives the cell
/// a clear background and no separator.
struct ProviderSetupPromptConfiguration: UIContentConfiguration {
    let themeID: ThemeID
    let message: String
    let identifier: String
    let onConfigure: () -> Void

    func makeContentView() -> any UIView & UIContentView {
        ProviderSetupPromptRowView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

@MainActor
final class ProviderSetupPromptRowView: UIView, UIContentView {
    private let card = ProviderSetupPromptView()
    private var applied: ProviderSetupPromptConfiguration

    var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? ProviderSetupPromptConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: ProviderSetupPromptConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        // As tall as the card: a stack fits loosely under a tall proposed size.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            hug,
            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func apply(_ configuration: ProviderSetupPromptConfiguration) {
        applied = configuration
        card.apply(
            message: configuration.message,
            identifier: configuration.identifier,
            themeID: configuration.themeID,
            onConfigure: configuration.onConfigure
        )
    }
}
