import UIKit

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

    private let backButton = UIButton(configuration: .plain())
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let divider = UIView()
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
        let trimmedSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        subtitleText = trimmedSubtitle.flatMap { $0.isEmpty || $0 == title ? nil : $0 }
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

        backButton.accessibilityLabel = String(localized: "Back")
        backButton.accessibilityIdentifier = "extension-native-surface-\(identifierSuffix)-detail-back"
        backButton.addAction(UIAction { [weak self] _ in self?.onLeave() }, for: .primaryActionTriggered)
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = UIFont.scaled(.headline, .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.text = titleText
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
        let header = UIStackView(arrangedSubviews: [backButton, titles])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 12, trailing: 18)

        for subview in [header, divider, blocks] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(1, view.traitCollection.displayScale)),
            blocks.topAnchor.constraint(equalTo: divider.bottomAnchor),
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
        let themeID = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bg)
        titleLabel.textColor = UIColor(palette.fg)
        subtitleLabel.textColor = UIColor(palette.comment)
        divider.backgroundColor = .separator

        var back = backButton.configuration ?? .plain()
        back.image = UIImage.scaledSymbol("chevron.backward", style: .body, weight: .semibold)
        back.baseForegroundColor = UIColor(palette.blue)
        // The chevron alone would be a 20 pt target.
        back.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        backButton.configuration = back

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
