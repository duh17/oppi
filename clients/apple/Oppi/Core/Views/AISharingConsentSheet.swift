import UIKit

extension AISharingConsent.Recipient {
    /// The model provider a send would reach: `modelId`'s provider, or with no model the
    /// server's default from its catalog. Nil when neither names one.
    static func modelProvider(modelId: String?, catalog: [ModelInfo]) -> Self? {
        modelProvider(AISharingConsent.modelProviderKey(
            modelId: modelId,
            catalog: catalog.map { .init(id: $0.id, provider: $0.provider, isDefault: $0.isDefault) }
        ))
    }

    /// A voice feature's backend, from the server's `voiceBackends`.
    static func voice(_ kind: Kind, backends: [ServerInfo.VoiceBackend]?) -> Self {
        let feature = kind == .dictation ? "dictation" : "liveVoice"
        return voice(kind, target: backends?.first { $0.feature == feature }?.target)
    }
}

/// Asks, in the app, for every AI recipient this device has not allowed on the server, one
/// sheet at a time. The send paths that can show UI call this before anything leaves the
/// device; Not Now, a swipe down, or no screen to show it on sends nothing, and the caller
/// keeps the draft.
@MainActor
enum AISharingConsentPrompt {
    /// True once every recipient is allowed (asking for the ones that are not); false when the
    /// person declined, or a provider cannot be named (then an alert says why).
    /// `screen` is the screen that asked; nil uses the front-most window.
    static func request(
        _ recipients: [AISharingConsent.Recipient?],
        serverId: String,
        from screen: UIViewController?,
        consent: AISharingConsent = .device
    ) async -> Bool {
        while true {
            switch consent.decide(recipients, serverId: serverId, canAsk: true) {
            case .send:
                return true
            case .refuse(let message):
                (screen ?? frontController())?.errorAlerts.show(
                    title: String(localized: "Not Sent"),
                    message: message
                )
                return false
            case .ask(let recipient):
                guard let presenter = (screen ?? frontController()).map(Router.topPresenter(from:)) else { return false }
                guard await AISharingConsentSheetViewController.ask(about: recipient, from: presenter) else {
                    return false
                }
                consent.grant(recipient, serverId: serverId)
            }
        }
    }

    /// The foreground window's front-most controller, for an owner with no screen of its own
    /// (dictation's voice manager).
    private static func frontController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window?.rootViewController.map(Router.topPresenter(from:))
    }
}

/// The disclosure and the choice: who gets the content, what is sent, and that the person's own
/// server forwards it under that service's terms. Allow, Not Now, or Privacy Policy (which, like
/// the push disclosure's, closes without allowing and opens the policy).
@MainActor
final class AISharingConsentSheetViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    enum Copy {
        static func title(for recipient: AISharingConsent.Recipient) -> String {
            switch recipient.kind {
            case .modelProvider:
                String(localized: "Send to \(recipient.name)?")
            case .dictation:
                String(localized: "Dictate Through Your Server?")
            case .liveVoice:
                String(localized: "Start Live Voice?")
            }
        }

        static func message(for recipient: AISharingConsent.Recipient) -> String {
            let name = recipient.name
            let settings = String(localized: "Oppi asks once for each service on each server. You can withdraw this in Settings > Privacy & Security.")
            switch recipient.kind {
            case .modelProvider:
                return String(localized: """
                Your server sends what you give this session to \(name), a third-party AI model provider, to get the model's replies. That includes your prompts, the conversation so far, files and photos you attach, and tool results.

                Your server uses its own \(name) account, and \(name) handles this content under its terms and privacy policy.
                """) + "\n\n" + settings
            case .dictation:
                return voiceMessage(
                    recipient,
                    what: String(localized: "While you dictate, Oppi streams your voice to your server, which sends it to \(name) to turn it into text.")
                ) + "\n\n" + settings
            case .liveVoice:
                return voiceMessage(
                    recipient,
                    what: String(localized: "During a Live Voice call, Oppi streams your voice to your server, which sends it to \(name). What you say becomes messages to your agent, and the agent's spoken replies go back through it.")
                ) + "\n\n" + settings
            }
        }

        private static func voiceMessage(_ recipient: AISharingConsent.Recipient, what: String) -> String {
            if recipient.isOnServerComputer {
                return what + " " + String(localized: "That service runs on the same computer as your server, not at a third party.")
            }
            if recipient.id == "server" {
                return what + " " + String(localized: "Your server's voice settings decide where the audio goes, which can be a third-party AI service.")
            }
            return what + " " + String(localized: "\(recipient.name) handles the audio under its terms and privacy policy.")
        }
    }

    private let recipient: AISharingConsent.Recipient
    private var answer: CheckedContinuation<Bool, Never>?

    /// Presents the sheet and returns the answer: true only for Allow.
    static func ask(about recipient: AISharingConsent.Recipient, from presenter: UIViewController) async -> Bool {
        await withCheckedContinuation { continuation in
            let sheet = AISharingConsentSheetViewController(recipient: recipient, answer: continuation)
            sheet.modalPresentationStyle = .pageSheet
            if let controller = sheet.sheetPresentationController {
                controller.detents = [.medium(), .large()]
                controller.prefersGrabberVisible = true
            }
            sheet.presentationController?.delegate = sheet
            presenter.present(sheet, animated: true)
        }
    }

    private init(recipient: AISharingConsent.Recipient, answer: CheckedContinuation<Bool, Never>) {
        self.recipient = recipient
        self.answer = answer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = ThemeRuntimeState.currentPalette()
        view.backgroundColor = UIColor(palette.bg)
        view.accessibilityIdentifier = "aiConsent.sheet"

        let icon = UIImageView(image: UIImage(systemName: recipient.kind == .modelProvider ? "hand.raised" : "waveform"))
        icon.tintColor = UIColor(palette.blue)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = Copy.title(for: recipient)
        titleLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = UIColor(palette.fg)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "aiConsent.title"

        let messageLabel = UILabel()
        messageLabel.text = Copy.message(for: recipient)
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = UIColor(palette.fg)
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "aiConsent.message"

        var allowConfig = UIButton.Configuration.filled()
        allowConfig.title = String(localized: "Allow")
        allowConfig.baseBackgroundColor = UIColor(palette.blue)
        allowConfig.buttonSize = .large
        let allow = UIButton(configuration: allowConfig, primaryAction: UIAction { [weak self] _ in
            self?.finish(true)
        })
        allow.accessibilityIdentifier = "aiConsent.allow"

        var notNowConfig = UIButton.Configuration.plain()
        notNowConfig.title = String(localized: "Not Now")
        notNowConfig.baseForegroundColor = UIColor(palette.blue)
        notNowConfig.buttonSize = .large
        let notNow = UIButton(configuration: notNowConfig, primaryAction: UIAction { [weak self] _ in
            self?.finish(false)
        })
        notNow.accessibilityIdentifier = "aiConsent.notNow"

        var policyConfig = UIButton.Configuration.plain()
        policyConfig.title = String(localized: "Privacy Policy")
        policyConfig.baseForegroundColor = UIColor(palette.comment)
        let policy = UIButton(configuration: policyConfig, primaryAction: UIAction { [weak self] _ in
            self?.finish(false)
            AppDelegate.opener?.open(.webLink(AppSupportLinks.privacyPolicyURL))
        })
        policy.accessibilityIdentifier = "aiConsent.privacyPolicy"

        let content = UIStackView(arrangedSubviews: [icon, titleLabel, messageLabel])
        content.axis = .vertical
        content.spacing = 14
        content.setCustomSpacing(8, after: icon)

        let buttons = UIStackView(arrangedSubviews: [allow, notNow, policy])
        buttons.axis = .vertical
        buttons.spacing = 4

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        for subview in [scroll, buttons] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            buttons.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    /// A swipe down is Not Now.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        resolve(false)
    }

    private func finish(_ allowed: Bool) {
        resolve(allowed)
        dismiss(animated: true)
    }

    private func resolve(_ allowed: Bool) {
        answer?.resume(returning: allowed)
        answer = nil
    }
}
