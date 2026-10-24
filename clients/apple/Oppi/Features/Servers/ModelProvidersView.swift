import SwiftUI

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

struct ProviderSetupPromptCard: View {
    let message: String
    let openAccessibilityIdentifier: String
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish server setup", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.themeComment)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Button("Configure Model Provider", action: onConfigure)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(openAccessibilityIdentifier)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.themeComment.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.themeComment.opacity(0.18), lineWidth: 1)
        )
    }
}

/// A setup card as a UIKit session-list cell's content, inset from the row
/// edges. The list gives the cell a clear background and no separator.
@MainActor
enum ProviderSetupPromptListRow {
    static func providerSetup(
        root: AppRootEnvironment,
        message: String,
        openAccessibilityIdentifier: String,
        onConfigure: @escaping () -> Void
    ) -> any UIContentConfiguration {
        row(
            ProviderSetupPromptCard(
                message: message,
                openAccessibilityIdentifier: openAccessibilityIdentifier,
                onConfigure: onConfigure
            ),
            root: root
        )
    }

    private static func row<Card: View>(_ card: Card, root: AppRootEnvironment) -> any UIContentConfiguration {
        UIHostingConfiguration { card.appRootEnvironment(root) }
            .margins(.all, EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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

struct ServerDetailsScopedDestinationView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator

    let target: ServerDetailsNavTarget

    private var server: PairedServer? {
        ServerSelection.resolveVisible(
            activeId: coordinator.activeServerId,
            frozenId: target.serverId,
            from: serverStore.servers
        )
    }

    var body: some View {
        if let server {
            ServerSettingsRootView(server: server)
                .id(server.id)
        } else {
            unavailableServerView
        }
    }

    private var unavailableServerView: some View {
        ContentUnavailableView(
            "Server Unavailable",
            systemImage: "server.rack",
            description: Text("This paired server is no longer available.")
        )
        .navigationTitle(HostSwitcherDestination.serverSettings.title)
        .navigationBarTitleDisplayMode(.inline)
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
