import UIKit

/// "Get notified when an agent needs you": the one-time push card at the top of
/// All Sessions (`PushDiscovery`), as a list cell inset from the row edges like
/// the other setup cards. The list gives the cell a clear background and no
/// separator.
///
/// Turn On runs the Server Settings turn-on path (`PushEnableFlow`), which asks
/// what the relay can see before anything is sent. Not Now closes the card for
/// good; Server Settings → Notifications keeps the switch.
struct PushDiscoveryCardConfiguration: UIContentConfiguration {
    enum Status: Equatable {
        case idle
        /// The relay disclosure was accepted; registration is running.
        case working
        case failed(String)
    }

    let themeID: ThemeID
    let status: Status
    let onTurnOn: () -> Void
    let onDismiss: () -> Void

    static let title = String(localized: "Get notified when an agent needs you")
    static let message = String(
        localized: "Oppi can alert you when a session finishes or needs your answer, even with the app closed. Alerts are encrypted so only this device can read them."
    )
    static let footnote = String(localized: "You can change this later in Server Settings → Notifications.")

    func makeContentView() -> any UIView & UIContentView {
        PushDiscoveryCardView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class PushDiscoveryCardView: UIView, UIContentView {
    private let card = UIStackView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let footnoteLabel = UILabel()
    private let statusLabel = UILabel()
    private let turnOnButton = UIButton(configuration: .borderedProminent())
    private let dismissButton = UIButton(configuration: .plain())
    private var applied: PushDiscoveryCardConfiguration

    var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? PushDiscoveryCardConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: PushDiscoveryCardConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        for label in [titleLabel, messageLabel, footnoteLabel, statusLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        titleLabel.accessibilityTraits = .header
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.text = PushDiscoveryCardConfiguration.message
        footnoteLabel.font = .preferredFont(forTextStyle: .footnote)
        footnoteLabel.text = PushDiscoveryCardConfiguration.footnote
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        turnOnButton.accessibilityIdentifier = "workspace.pushDiscovery.turnOn"
        turnOnButton.addAction(UIAction { [weak self] _ in self?.applied.onTurnOn() }, for: .touchUpInside)
        dismissButton.accessibilityIdentifier = "workspace.pushDiscovery.dismiss"
        dismissButton.addAction(UIAction { [weak self] _ in self?.applied.onDismiss() }, for: .touchUpInside)
        statusLabel.accessibilityIdentifier = "workspace.pushDiscovery.status"

        let buttons = UIStackView(arrangedSubviews: [turnOnButton, dismissButton])
        buttons.axis = .vertical
        buttons.alignment = .center
        buttons.spacing = 2

        card.axis = .vertical
        card.alignment = .fill
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16)
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.accessibilityIdentifier = "workspace.pushDiscovery.card"
        [titleLabel, messageLabel, statusLabel, buttons, footnoteLabel].forEach(card.addArrangedSubview)
        card.setCustomSpacing(14, after: statusLabel)
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

    private func apply(_ configuration: PushDiscoveryCardConfiguration) {
        let previousStatus = applied.status
        applied = configuration
        let colors = SessionRowStyle.for(configuration.themeID).colors
        titleLabel.attributedText = SessionRowText.symbolAndText(
            "bell.badge", PushDiscoveryCardConfiguration.title,
            style: .headline, symbolWeight: .semibold, textWeight: .semibold, spacing: 6, color: colors.fg
        )
        messageLabel.textColor = colors.comment
        footnoteLabel.textColor = colors.comment

        var turnOn = UIButton.Configuration.borderedProminent()
        turnOn.buttonSize = .large
        turnOn.baseBackgroundColor = colors.blue
        switch configuration.status {
        case .idle, .failed:
            turnOn.title = String(localized: "Turn On Notifications")
        case .working:
            turnOn.title = String(localized: "Turning On…")
            turnOn.showsActivityIndicator = true
        }
        turnOnButton.configuration = turnOn
        // A disabled button keeps its title, so VoiceOver still names it while it works.
        turnOnButton.isEnabled = configuration.status != .working

        var dismiss = UIButton.Configuration.plain()
        dismiss.title = String(localized: "Not Now")
        dismiss.baseForegroundColor = colors.comment
        dismissButton.configuration = dismiss
        dismissButton.isEnabled = configuration.status != .working

        switch configuration.status {
        case .failed(let message):
            statusLabel.text = message
            statusLabel.textColor = colors.orange
            statusLabel.isHidden = false
        case .idle, .working:
            statusLabel.text = nil
            statusLabel.isHidden = true
        }
        card.backgroundColor = colors.comment.withAlphaComponent(0.12)
        card.layer.borderColor = colors.comment.withAlphaComponent(0.18).cgColor
        if previousStatus != configuration.status {
            // The failure line changes the card's height; a list cell keeps the height it measured.
            invalidateIntrinsicContentSize()
        }
    }
}
