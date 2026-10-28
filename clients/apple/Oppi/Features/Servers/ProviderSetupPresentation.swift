import UIKit

enum ProviderSetupState: Equatable {
    case unknown
    case unavailable
    case needsConfiguration
    case configured

    init(providerStatuses: [ProviderAuthProviderStatus]) {
        self = providerStatuses.contains(where: \.authenticated)
            ? .configured
            : .needsConfiguration
    }
}

enum ProviderSetupPromptPolicy {
    static func shouldShow(for state: ProviderSetupState) -> Bool {
        state == .needsConfiguration
    }

    /// Keep the All Sessions empty-state copy from stacking under the setup card.
    static func shouldShowInboxEmptyState(isEmpty: Bool, showsProviderSetup: Bool) -> Bool {
        isEmpty && !showsProviderSetup
    }
}

/// The setup card as an All Sessions cell's content (`ProviderSetupPromptConfiguration`, drawn by
/// `ProviderSetupPromptView`).
@MainActor
enum ProviderSetupPromptListRow {
    static func providerSetup(
        root: AppRootEnvironment,
        message: String,
        openAccessibilityIdentifier: String,
        onConfigure: @escaping () -> Void
    ) -> any UIContentConfiguration {
        ProviderSetupPromptConfiguration(
            themeID: root.themeStore.activeThemeID,
            message: message,
            identifier: openAccessibilityIdentifier,
            onConfigure: onConfigure
        )
    }
}

struct ProviderConfigurationPresentation: Equatable {
    let state: ProviderSetupState

    var showsLoading: Bool { state == .unknown }
    var showsProviderSections: Bool {
        state == .needsConfiguration || state == .configured
    }

    func summary(connectedCount: Int) -> String {
        switch state {
        case .unknown:
            "Loading…"
        case .unavailable:
            "Unavailable"
        case .needsConfiguration:
            "Needs setup"
        case .configured:
            "\(connectedCount) connected"
        }
    }
}

/// "This server is older than this app" with Open Server Settings, as an All
/// Sessions cell inset from the row edges. The list gives the cell a clear
/// background and no separator.
struct ServerVersionPromptConfiguration: UIContentConfiguration {
    let themeID: ThemeID
    let onOpen: () -> Void

    func makeContentView() -> any UIView & UIContentView {
        ServerVersionPromptView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class ServerVersionPromptView: UIView, UIContentView {
    private let card = UIStackView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let button = UIButton(configuration: .borderedProminent())
    private var applied: ServerVersionPromptConfiguration

    var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? ServerVersionPromptConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: ServerVersionPromptConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.text = ServerUpdatePresentation.minimumVersionNoticeMessage
        button.accessibilityIdentifier = "workspace.minimumServerVersion.open"
        button.addAction(UIAction { [weak self] _ in self?.applied.onOpen() }, for: .touchUpInside)
        let buttonRow = UIStackView(arrangedSubviews: [button])
        buttonRow.axis = .vertical
        buttonRow.alignment = .center

        card.axis = .vertical
        card.alignment = .fill
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.accessibilityIdentifier = "workspace.minimumServerVersion.notice"
        [titleLabel, messageLabel, buttonRow].forEach(card.addArrangedSubview)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        // As tall as the card: stack views fit loosely under a tall proposed size.
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

    private func apply(_ configuration: ServerVersionPromptConfiguration) {
        applied = configuration
        let colors = SessionRowStyle.for(configuration.themeID).colors
        titleLabel.attributedText = SessionRowText.symbolAndText(
            "arrow.down.app", ServerUpdatePresentation.minimumVersionNoticeTitle,
            style: .headline, symbolWeight: .semibold, textWeight: .semibold, spacing: 6, color: colors.fg
        )
        messageLabel.textColor = colors.comment
        var buttonConfiguration = UIButton.Configuration.borderedProminent()
        buttonConfiguration.title = ServerUpdatePresentation.minimumVersionNoticeAction
        buttonConfiguration.buttonSize = .large
        buttonConfiguration.baseBackgroundColor = colors.blue
        button.configuration = buttonConfiguration
        card.backgroundColor = colors.comment.withAlphaComponent(0.12)
        card.layer.borderColor = colors.comment.withAlphaComponent(0.18).cgColor
    }
}
