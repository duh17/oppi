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
        /// The Pi mark the chat's Pi avatar draws, in the row's color.
        case piMark
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
            id: "uikit",
            icon: .symbol("bolt"),
            iconColor: \.blue,
            title: String(localized: "Rebuilt in UIKit"),
            description: String(localized: "We moved chats, the composer, session lists, Files, and many settings pages from SwiftUI to UIKit. Opening chats, scrolling, and moving between screens are much faster. If anything works differently than before, please report it through TestFlight feedback.")
        ),
        WhatsNewFeature(
            id: "ssh-terminal",
            icon: .symbol("terminal"),
            iconColor: \.green,
            title: String(localized: "SSH Terminal"),
            description: String(localized: "The terminal is out of Experiments and much more polished. We rewrote its rendering on the GPU, so it is a lot faster and scrolls smoothly, and added support for the Kitty image protocol. With an SSH host set up, a chat can open a terminal in its own folder.")
        ),
        WhatsNewFeature(
            id: "live-voice",
            icon: .symbol("waveform"),
            iconColor: \.cyan,
            title: String(localized: "Live Voice (experimental)"),
            description: String(localized: "Talk with a session hands-free from the composer mic, Control Center, or the Action Button. Turn it on in Settings → Experiments. It needs a voice backend on your server: Grok Voice with an xAI key works; our local reference implementation works but is still rough.")
        ),
        WhatsNewFeature(
            id: "code-editor",
            icon: .symbol("chevron.left.forwardslash.chevron.right"),
            iconColor: \.purple,
            title: String(localized: "Code editor"),
            description: String(localized: "Workspace files open in a real code editor with tree-sitter syntax highlighting, line numbers, auto-indent, and optional Vim keybindings in Settings → Editor. Skill files can be edited in place too.")
        ),
        WhatsNewFeature(
            id: "push",
            icon: .symbol("bell.badge"),
            iconColor: \.orange,
            title: String(localized: "Push and Live Activities (experimental)"),
            description: String(localized: "Opt in for each server in Server Settings → Notifications to get end-to-end-encrypted alerts through Oppi's free relay when a session needs your answer or approval, a run fails, or an agent notifies you. Live Activities show running and waiting counts on the Lock Screen. Both are off by default, and the privacy policy lists what the relay can see. Limits are preliminary: up to 100 pushes per phone a day, 30 kept for alerts.")
        ),
        WhatsNewFeature(
            id: "diff-engine",
            icon: .symbol("plus.forwardslash.minus"),
            iconColor: \.red,
            title: String(localized: "Our own diff engine"),
            description: String(localized: "We wrote our own diff engine and dropped Google's diff-match-patch. Diffs show the fewest changed lines, highlight only the words that changed, and scroll smoothly on long files.")
        ),
        WhatsNewFeature(
            id: "top-bar",
            icon: .gitLogo,
            iconColor: \.yellow,
            title: String(localized: "Reorganized top bar"),
            description: String(localized: "The chat's top-right bar is reorganized: Context sits up front, and Files, Git, Outline, and Terminal are in its … menu. Settings → Chat → Top Bar pins the ones you use.")
        ),
        WhatsNewFeature(
            id: "pi",
            icon: .piMark,
            iconColor: \.comment,
            title: String(localized: "Pi 1.4"),
            description: String(localized: "Oppi now runs the latest Pi, 1.4.0. Needs server 0.53.0.")
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
        let palette = themeID.palette
        let colors = ComposerThemeColors(palette: palette)
        view.backgroundColor = colors.bg
        bottomBar.backgroundColor = colors.bgDark

        titleLabel.font = .scaled(.largeTitle, .bold)
        titleLabel.textColor = colors.fg
        captionLabel.font = .scaled(.subheadline, .medium)
        captionLabel.textColor = colors.comment
        for row in rows {
            row.apply(colors: colors)
        }

        // SwiftUI's `.borderedProminent` with a `.headline` label: a capsule in
        // the theme blue, a semibold label. The label color is the better of
        // fg and bg against the blue (the rule behind `ThemeUIKitPalette.onBlue`),
        // so it keeps its contrast on light blues too.
        var configuration = doneButton.configuration ?? .borderedProminent()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = colors.blue
        configuration.baseForegroundColor = UIColor(ThemeColorContrast.contrastingForeground(
            on: palette.blue,
            candidates: [palette.fg, palette.bg]
        ))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20)
        configuration.attributedTitle = AttributedString(
            String(localized: "Done"),
            attributes: AttributeContainer([.font: UIFont.scaled(.headline, .semibold)])
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
            // The old label's 44 pt minimum plus the style's 7 pt above and below.
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
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

    /// The Pi avatar's mark, whose artwork covers about 60% of its canvas,
    /// enlarged to about the size of the symbols (24 pt) in the 28 pt icon slot.
    private static func piMarkImage(color: UIColor) -> UIImage {
        let slot: CGFloat = 28
        let canvas: CGFloat = 41
        let mark = PiAvatarRenderer.render(size: canvas)
            .withRenderingMode(.alwaysTemplate)
            .withTintColor(color, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: CGSize(width: slot, height: slot)).image { _ in
            mark.draw(in: CGRect(x: (slot - canvas) / 2, y: (slot - canvas) / 2, width: canvas, height: canvas))
        }
    }

    func apply(colors: ComposerThemeColors) {
        let color = colors[keyPath: feature.iconColor]
        icon.image = switch feature.icon {
        case .symbol(let name):
            UIImage.scaledSymbol(name, style: .title3, weight: .semibold, color: color)
        case .gitLogo:
            GitLogoImage.image(textStyle: .title3)?.withTintColor(color, renderingMode: .alwaysOriginal)
        case .piMark:
            Self.piMarkImage(color: color)
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
