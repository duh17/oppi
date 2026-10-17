import UIKit

/// Host-key trust and changed-key block. Trust & Connect sits in the
/// navigation bar and is pinned above the keyboard so it stays reachable
/// while a field on the form behind this sheet still holds focus.
final class SSHTerminalTrustViewController: UIViewController {
    private let failure: SSHConnectionError
    private let connecting: Bool
    private let onTrust: () -> Void
    private let onForget: () -> Void
    private var commentLabels: [UILabel] = []
    private var fgLabels: [UILabel] = []
    private var fgTextViews: [UITextView] = []
    private var lastThemeID: ThemeID?

    init(
        failure: SSHConnectionError,
        connecting: Bool,
        onTrust: @escaping () -> Void,
        onForget: @escaping () -> Void
    ) {
        self.failure = failure
        self.connecting = connecting
        self.onTrust = onTrust
        self.onForget = onForget
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .inline
        applyTheme()
        let palette = sshTerminalThemeID.palette

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)

        let action = UIButton(type: .system)
        action.translatesAutoresizingMaskIntoConstraints = false
        action.titleLabel?.font = .preferredFont(forTextStyle: .body)
        action.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        switch failure {
        case .unknownHostKey(let key):
            title = "New host"
            let heading = headline("New host — trust decision", color: UIColor(palette.fg))
            heading.accessibilityIdentifier = "sshTerminal.trustPrompt"
            fgLabels.append(heading)
            stack.addArrangedSubview(heading)
            stack.addArrangedSubview(fingerprint("Presented Host Key", key, palette: palette))
            stack.addArrangedSubview(footnote(
                "Verify this fingerprint on the host before trusting it. No credentials were sent.",
                palette: palette
            ))
            var config = UIButton.Configuration.borderedProminent()
            config.title = "Trust & Connect"
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            action.configuration = config
            action.accessibilityIdentifier = "sshTerminal.trustKey"
            action.isEnabled = !connecting
            action.addAction(UIAction { [weak self] _ in self?.onTrust() }, for: .touchUpInside)
            let bar = UIBarButtonItem(title: "Trust & Connect", style: .done, target: self, action: #selector(trust))
            bar.isEnabled = !connecting
            navigationItem.rightBarButtonItem = bar
        case .hostKeyMismatch(let saved, let presented):
            title = "Host key changed"
            let heading = headline("Host key changed — connection blocked.", color: UIColor(palette.red))
            fgLabels.append(heading)
            stack.addArrangedSubview(heading)
            stack.addArrangedSubview(fingerprint("Trusted", saved, palette: palette))
            stack.addArrangedSubview(fingerprint("Presented", presented, palette: palette))
            var config = UIButton.Configuration.borderedProminent()
            config.title = "Forget Trusted Key"
            config.baseBackgroundColor = UIColor(palette.red)
            config.baseForegroundColor = UIColor(palette.bg)
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            action.configuration = config
            action.accessibilityIdentifier = "sshTerminal.forgetKey"
            action.addAction(UIAction { [weak self] _ in self?.onForget() }, for: .touchUpInside)
        default:
            title = "Host trust"
        }

        view.addSubview(action)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: action.topAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: view.layoutMarginsGuide.widthAnchor),
            action.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            action.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        applyTheme()
    }

    @objc private func trust() { onTrust() }

    private func applyTheme() {
        let themeID = sshTerminalThemeID
        lastThemeID = themeID
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bg)
        commentLabels.forEach { $0.textColor = UIColor(palette.comment) }
        fgLabels.forEach { $0.textColor = UIColor(palette.fg) }
        fgTextViews.forEach { $0.textColor = UIColor(palette.fg) }
        if case .hostKeyMismatch = failure, let heading = fgLabels.first {
            heading.textColor = UIColor(palette.red)
        }
    }

    private func headline(_ text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func footnote(_ text: String, palette: ThemePalette) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = UIColor(palette.comment)
        label.numberOfLines = 0
        commentLabels.append(label)
        return label
    }

    private func fingerprint(_ label: String, _ key: SSHHostKey, palette: ThemePalette) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        let caption = UILabel()
        caption.text = "\(label) (\(key.algorithm))"
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.textColor = UIColor(palette.comment)
        commentLabels.append(caption)
        let value = UITextView()
        value.text = key.fingerprint
        value.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        value.textColor = UIColor(palette.fg)
        value.isEditable = false
        value.isScrollEnabled = false
        value.backgroundColor = .clear
        value.textContainerInset = .zero
        value.textContainer.lineFragmentPadding = 0
        value.isSelectable = true
        fgTextViews.append(value)
        stack.addArrangedSubview(caption)
        stack.addArrangedSubview(value)
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "\(label) (\(key.algorithm)). \(key.fingerprint)"
        return stack
    }
}
