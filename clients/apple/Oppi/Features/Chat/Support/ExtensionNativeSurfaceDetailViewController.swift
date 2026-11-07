import UIKit

/// The header of an extension surface's full-screen reader: Back, the title, and the subtitle
/// over a hairline. Both surface readers draw it, so they read alike.
@MainActor
final class ExtensionSurfaceReaderHeaderView: UIView {
    private let backButton = UIButton(configuration: .plain())
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let divider = UIView()

    init(backIdentifier: String, title: String, subtitle: String?, onLeave: @escaping @MainActor () -> Void) {
        super.init(frame: .zero)
        let trimmedSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitleText = trimmedSubtitle.flatMap { $0.isEmpty || $0 == title ? nil : $0 }

        backButton.accessibilityLabel = String(localized: "Back")
        backButton.accessibilityIdentifier = backIdentifier
        backButton.addAction(UIAction { _ in onLeave() }, for: .primaryActionTriggered)
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = UIFont.scaled(.headline, .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.text = title
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.numberOfLines = 2
        subtitleLabel.text = subtitleText
        subtitleLabel.isHidden = subtitleText == nil
        for label in [titleLabel, subtitleLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .fill
        titles.spacing = 3
        let row = UIStackView(arrangedSubviews: [backButton, titles])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 12, trailing: 18)

        for subview in [row, divider] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            divider.topAnchor.constraint(equalTo: row.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(palette: ThemePalette) {
        titleLabel.textColor = palette.ui.fg
        subtitleLabel.textColor = palette.ui.comment
        divider.backgroundColor = .separator

        var back = backButton.configuration ?? .plain()
        back.image = UIImage.scaledSymbol("chevron.backward", style: .body, weight: .semibold)
        back.baseForegroundColor = palette.ui.blue
        // The chevron alone would be a 20 pt target.
        back.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        backButton.configuration = back
    }
}

/// One native surface full screen: the chat reader's page for an extension
/// drawer's double tap (`ChatReaderPayload.extensionNative`). A header with
/// Back, the title, and the subtitle sits over `ExtensionNativeBlockScrollView`,
/// which paints every block.
///
/// Rendering is generic: the surface's blocks and the producer's title and
/// subtitle are all it reads.
@MainActor
final class ExtensionNativeSurfaceDetailViewController: UIViewController {
    private let surface: ExtensionUINativeSurface
    private let identifierSuffix: String
    private let titleText: String
    private let subtitleText: String?
    private let linkContext: ExtensionSurfaceLinkContext
    private let onOpenURL: ((URL) -> Bool)?
    /// Reads the session's current snapshot for this surface id. Observation
    /// re-renders the reader on each widget update, which the server already
    /// throttles and size-limits; no extra data is fetched. When the surface is
    /// cleared, the reader keeps the last snapshot it showed.
    private let liveSurface: (@MainActor () -> ExtensionUINativeSurface?)?
    /// Leaves the reader: Back and the back swipe.
    private let onLeave: @MainActor () -> Void

    private var lastLiveSurface: ExtensionUINativeSurface?
    private var backSwipe: HorizontalBackSwipeGestureInstaller?

    private var header: ExtensionSurfaceReaderHeaderView?
    private let blocks = ExtensionNativeBlockScrollView()

    init(
        surface: ExtensionUINativeSurface,
        identifierSuffix: String,
        title: String,
        subtitle: String?,
        linkContext: ExtensionSurfaceLinkContext = .empty,
        onOpenURL: ((URL) -> Bool)? = nil,
        liveSurface: (@MainActor () -> ExtensionUINativeSurface?)? = nil,
        onLeave: @escaping @MainActor () -> Void
    ) {
        self.surface = surface
        self.identifierSuffix = identifierSuffix
        titleText = title
        subtitleText = subtitle
        self.linkContext = linkContext
        self.onOpenURL = onOpenURL
        self.liveSurface = liveSurface
        self.onLeave = onLeave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "extension-native-surface-\(identifierSuffix)-detail"

        let header = ExtensionSurfaceReaderHeaderView(
            backIdentifier: "extension-native-surface-\(identifierSuffix)-detail-back",
            title: titleText,
            subtitle: subtitleText,
            onLeave: onLeave
        )
        self.header = header
        for subview in [header, blocks] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blocks.topAnchor.constraint(equalTo: header.bottomAnchor),
            blocks.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            blocks.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            blocks.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])

        let installer = HorizontalBackSwipeGestureInstaller { [weak self] in self?.onLeave() }
        installer.install(on: view)
        backSwipe = installer
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = palette.ui.bg
        header?.apply(palette: palette)

        // Reading the live snapshot here makes UIKit re-run this pass on each
        // widget update.
        let displayed = liveSurface?() ?? lastLiveSurface ?? surface
        lastLiveSurface = displayed
        blocks.update(
            content: ExtensionNativeBlockContent(surface: displayed),
            context: ExtensionNativeBlockContext(themeID: themeID, linkContext: linkContext, onOpenURL: onOpenURL),
            sizing: .fill,
            contentInsets: NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18),
            spacing: 12,
            accessibilityIdentifier: nil,
            onDoubleTap: nil
        )
    }
}

/// One composable (v2) surface full screen: the chat reader's page for a drawer that outgrew its
/// cap (`ChatReaderPayload.extensionSurface`). The same cards the drawer draws, in a scroll view
/// that takes the whole screen, under the shared reader header.
///
/// Rendering is generic: the surface's sections and the producer's title and subtitle are all it
/// reads. Actions go out through the host the drawer used, so a card's button works here too.
@MainActor
final class ExtensionSurfaceDetailViewController: UIViewController {
    private let content: ExtensionSurfaceReaderContent
    private let onLeave: @MainActor () -> Void
    private var lastLiveSurface: ExtensionUISurface?
    private var backSwipe: HorizontalBackSwipeGestureInstaller?

    private var header: ExtensionSurfaceReaderHeaderView?
    private let scrollView = UIScrollView()
    private let cards = ExtensionSurfaceCompositesView()

    init(content: ExtensionSurfaceReaderContent, onLeave: @escaping @MainActor () -> Void) {
        self.content = content
        self.onLeave = onLeave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let suffix = content.identifierSuffix
        view.accessibilityIdentifier = "extension.surfaceReader.\(suffix)"

        let header = ExtensionSurfaceReaderHeaderView(
            backIdentifier: "extension.surfaceReader.back.\(suffix)",
            title: content.title,
            subtitle: content.subtitle,
            onLeave: onLeave
        )
        self.header = header
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "extension.surfaceReader.scroll.\(suffix)"
        cards.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(cards)
        for subview in [header, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            cards.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            cards.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
            cards.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18),
            cards.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18),
            // The content has no width of its own to scroll sideways by.
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        let installer = HorizontalBackSwipeGestureInstaller { [weak self] in self?.onLeave() }
        installer.install(on: view)
        backSwipe = installer
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = palette.ui.bg
        header?.apply(palette: palette)

        // Reading the live snapshot and the pending wait here makes UIKit re-run this pass on each
        // replacement and each settled action.
        let displayed = content.liveSurface?() ?? lastLiveSurface ?? content.surface
        lastLiveSurface = displayed
        let pending = content.pendingAction?().flatMap { $0.surfaceId == displayed.id ? $0 : nil }
        cards.apply(surface: displayed, pending: pending, themeID: themeID, onAction: content.sendAction)
    }
}
