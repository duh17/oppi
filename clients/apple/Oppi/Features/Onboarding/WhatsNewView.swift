import UIKit

/// Tracks which app build the user has seen the What's New screen for.
enum WhatsNewManager {
    private static let lastSeenVersionKey = "\(AppIdentifiers.subsystem).whatsNew.lastSeenVersion"

    /// Current marketing version plus build number from the bundle.
    static var currentVersion: String {
        releaseIdentifier(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func releaseIdentifier(marketingVersion: String?, buildNumber: String?) -> String {
        let version = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVersion: String
        if let version, !version.isEmpty {
            cleanVersion = version
        } else {
            cleanVersion = "1.0.0"
        }
        guard let build, !build.isEmpty else { return cleanVersion }
        return "\(cleanVersion) (\(build))"
    }

    /// Whether the What's New changelog should be shown.
    /// First install is not a changelog. Upgrades show it once per release.
    static var shouldShow: Bool {
        shouldShowChangelog(
            lastSeenVersion: UserDefaults.standard.string(forKey: lastSeenVersionKey),
            currentVersion: currentVersion
        )
    }

    static func shouldShowChangelog(lastSeenVersion: String?, currentVersion: String) -> Bool {
        guard let lastSeenVersion, !lastSeenVersion.isEmpty else { return false }
        return lastSeenVersion != currentVersion
    }

    /// Persist this release on first launch so a later upgrade can show What's New.
    static func recordFirstLaunchIfNeeded() {
        if UserDefaults.standard.string(forKey: lastSeenVersionKey) == nil {
            markSeen()
        }
    }

    /// Mark the current app build as seen.
    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
    }

    static func caption(marketingVersion: String?) -> String {
        let version = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if version.isEmpty {
            return String(localized: "What’s new in this version")
        }
        return String(localized: "Version \(version)")
    }
}

// MARK: - Feature Model

private struct WhatsNewFeature {
    enum Icon {
        case symbol(String)
        /// The Git logo, the one the chat's Git top-bar button draws.
        case gitLogo
    }

    let id: String
    let icon: Icon
    let iconColor: KeyPath<ComposerThemeColors, UIColor>
    let title: String
    let description: String
}

// MARK: - Screen

/// The What's New screen: a title, the release's features, and a Done button
/// pinned under the scrolling content. Presented full screen by the router,
/// which closes it when `onContinue` finishes the screen.
///
/// Colors come from the app root's theme store (the active theme when the
/// screen is not under an app root). Dynamic Type
/// refreshes fonts in `updateProperties()`. With Reduce Motion on, the content
/// is in place from the first frame.
@MainActor
final class WhatsNewViewController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private let onContinue: (WhatsNewViewController) -> Void

    private let scrollView = UIScrollView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let header = UIStackView()
    private let featureStack = UIStackView()
    private let bottomBar = UIView()
    private let doneButton = UIButton(configuration: .borderedProminent())
    private var rows: [FeatureRow] = []
    private var hasAppeared = false

    /// Build 56 · Changes since Build 55
    private static let features: [WhatsNewFeature] = [
        WhatsNewFeature(
            id: "ssh-terminal",
            icon: .symbol("terminal"),
            iconColor: \.green,
            title: String(localized: "SSH Terminal"),
            description: String(localized: "The SSH Terminal is no longer an experiment. Open Terminal here starts a shell in the folder a chat works in, password prompts switch to secure entry, images from kitten icat and agents draw in the grid, and the shell survives short trips out of Oppi.")
        ),
        WhatsNewFeature(
            id: "uikit-speed",
            icon: .symbol("bolt"),
            iconColor: \.blue,
            title: String(localized: "Rebuilt and faster"),
            description: String(localized: "Chats, the composer, session lists, Files, and every settings page are rebuilt in UIKit, so opening chats, scrolling, and moving between screens is faster. Scrolling up loads earlier messages before you reach the top.")
        ),
        WhatsNewFeature(
            id: "push-live-activities",
            icon: .symbol("bell.badge"),
            iconColor: \.orange,
            title: String(localized: "Notifications and Live Activities"),
            description: String(localized: "Server Settings → Notifications turns on end-to-end-encrypted push through Oppi's relay: an alert when a session needs your answer or approval, or when an agent notifies you. Live Activities show running and waiting sessions on the Lock Screen and in the Dynamic Island.")
        ),
        WhatsNewFeature(
            id: "code-editor",
            icon: .symbol("chevron.left.forwardslash.chevron.right"),
            iconColor: \.purple,
            title: String(localized: "Code editor"),
            description: String(localized: "Workspace files open in a code editor with syntax color, line numbers, auto-indent, and optional Vim keys. Skill files can be edited in place, or handed to an Oppi session.")
        ),
        WhatsNewFeature(
            id: "git-panel",
            icon: .gitLogo,
            iconColor: \.red,
            title: String(localized: "Git and a tidier top bar"),
            description: String(localized: "The chat's top bar shows Context; Files, Outline, Git, and Terminal sit in its … menu, and Settings → Chat → Top Bar pins the ones you use. Git shows the session's changes and diffs, which now show the fewest changed lines and highlight only edited words.")
        ),
        WhatsNewFeature(
            id: "read-aloud",
            icon: .symbol("speaker.wave.2"),
            iconColor: \.cyan,
            title: String(localized: "Read aloud"),
            description: String(localized: "A speaker under a finished reply reads it with your server's text-to-speech. Live Voice, an experiment under Settings → Experiments, talks with a session hands-free.")
        ),
        WhatsNewFeature(
            id: "context-metrics",
            icon: .symbol("chart.bar"),
            iconColor: \.yellow,
            title: String(localized: "Context and Server Metrics"),
            description: String(localized: "The chat's Context panel shows what fills the context window, from system prompt to tools. Server Metrics in the host menu charts the server's CPU, memory, and disk over 30 days while sampling is on.")
        ),
        WhatsNewFeature(
            id: "incognito",
            icon: .symbol("eye.slash"),
            iconColor: \.comment,
            title: String(localized: "Incognito Quick Session"),
            description: String(localized: "Quick Session's Incognito pill starts a chat that ends and deletes itself when you leave it.")
        ),
    ]

    /// `onContinue` runs after the build is marked seen; it closes the screen.
    init(onContinue: @escaping (WhatsNewViewController) -> Void) {
        self.onContinue = onContinue
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHierarchy()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.setNeedsUpdateProperties()
        }
        if !UIAccessibility.isReduceMotionEnabled {
            applyAppearance(revealed: false)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !hasAppeared else { return }
        hasAppeared = true
        reveal(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        let root = HostFactory.root(near: self)
        if let root {
            overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        }
        let themeID = root?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let colors = ComposerThemeColors(palette: themeID.palette)
        view.backgroundColor = colors.bg
        bottomBar.backgroundColor = colors.bgDark

        titleLabel.font = .scaled(.largeTitle, .bold)
        titleLabel.textColor = colors.fg
        captionLabel.font = .scaled(.subheadline, .medium)
        captionLabel.textColor = colors.comment
        for row in rows {
            row.apply(colors: colors)
        }

        var configuration = doneButton.configuration ?? .borderedProminent()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = colors.blue
        configuration.attributedTitle = AttributedString(
            String(localized: "Done"),
            attributes: AttributeContainer([.font: UIFont.scaled(.headline)])
        )
        doneButton.configuration = configuration
    }

    // MARK: Layout

    private func buildHierarchy() {
        titleLabel.text = String(localized: "What’s New in Oppi")
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "whatsNew.title"
        titleLabel.accessibilityTraits.insert(.header)

        captionLabel.text = WhatsNewManager.caption(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        captionLabel.numberOfLines = 0
        captionLabel.textAlignment = .center
        captionLabel.accessibilityIdentifier = "whatsNew.caption"

        header.axis = .vertical
        header.spacing = 6
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(captionLabel)

        featureStack.axis = .vertical
        featureStack.spacing = 18
        rows = Self.features.map(FeatureRow.init)
        rows.forEach(featureStack.addArrangedSubview)

        let content = UIStackView(arrangedSubviews: [header, featureStack])
        content.axis = .vertical
        content.setCustomSpacing(28, after: header)
        content.translatesAutoresizingMaskIntoConstraints = false

        scrollView.alwaysBounceVertical = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)

        doneButton.accessibilityIdentifier = "whatsNew.done"
        doneButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            WhatsNewManager.markSeen()
            onContinue(self)
        }, for: .primaryActionTriggered)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(doneButton)

        view.addSubview(scrollView)
        view.addSubview(bottomBar)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            doneButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
            doneButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            doneButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    // MARK: Appear animation

    /// The header, rows, and bar before the appear animation: invisible and
    /// shifted down. `revealed` puts them in place.
    private func applyAppearance(revealed: Bool) {
        header.alpha = revealed ? 1 : 0
        header.transform = revealed ? .identity : CGAffineTransform(translationX: 0, y: 20)
        for row in rows {
            row.alpha = revealed ? 1 : 0
            row.transform = revealed ? .identity : CGAffineTransform(translationX: 0, y: 30)
        }
        bottomBar.alpha = revealed ? 1 : 0
    }

    /// The header fades in over half a second, each row follows 60 ms after
    /// the one above, and the Done bar comes last.
    private func reveal(animated: Bool) {
        guard animated else {
            applyAppearance(revealed: true)
            return
        }
        let ease: UIView.AnimationOptions = [.curveEaseOut, .allowUserInteraction]
        UIView.animate(withDuration: 0.5, delay: 0, options: ease) {
            self.header.alpha = 1
            self.header.transform = .identity
        }
        for (index, row) in rows.enumerated() {
            UIView.animate(withDuration: 0.5, delay: Double(index) * 0.06 + 0.1, options: ease) {
                row.alpha = 1
                row.transform = .identity
            }
        }
        UIView.animate(withDuration: 0.4, delay: 0.6, options: ease) {
            self.bottomBar.alpha = 1
        }
    }
}

// MARK: - Feature Row

/// An icon beside a title and a description. Its identifiers are
/// `whatsNew.feature.<id>` with `.title` and `.description` on the labels.
@MainActor
private final class FeatureRow: UIView {
    private let feature: WhatsNewFeature
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let descriptionLabel = UILabel()

    init(_ feature: WhatsNewFeature) {
        self.feature = feature
        super.init(frame: .zero)
        accessibilityIdentifier = "whatsNew.feature.\(feature.id)"

        icon.contentMode = .center
        icon.isAccessibilityElement = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = feature.title
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "whatsNew.feature.\(feature.id).title"
        descriptionLabel.numberOfLines = 0
        descriptionLabel.accessibilityIdentifier = "whatsNew.feature.\(feature.id).description"

        let text = UIStackView(arrangedSubviews: [titleLabel, descriptionLabel])
        text.axis = .vertical
        text.spacing = 4

        // The icon sits 1 pt below the first line's top, as the title's cap
        // height wants it.
        let iconSlot = UIView()
        iconSlot.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: iconSlot.topAnchor, constant: 1),
            icon.leadingAnchor.constraint(equalTo: iconSlot.leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: iconSlot.trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            iconSlot.bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor),
        ])

        let row = UIStackView(arrangedSubviews: [iconSlot, text])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(colors: ComposerThemeColors) {
        let color = colors[keyPath: feature.iconColor]
        icon.image = switch feature.icon {
        case .symbol(let name):
            UIImage.scaledSymbol(name, style: .title3, weight: .semibold, color: color)
        case .gitLogo:
            GitLogoImage.image(textStyle: .title3)?.withTintColor(color, renderingMode: .alwaysOriginal)
        }
        titleLabel.font = .scaled(.headline, .semibold)
        titleLabel.textColor = colors.fg

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        descriptionLabel.attributedText = NSAttributedString(
            string: feature.description,
            attributes: [
                .font: UIFont.scaled(.subheadline),
                .foregroundColor: colors.comment,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
