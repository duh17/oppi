import UIKit

/// One surface as a panel pane reads it: a classic widget's v1 surface, or a durable plugin's v2
/// one. Only protocol fields are read, so every extension takes the same path.
enum ExtensionPanelSnapshot: Equatable {
    case native(ExtensionNativeSurfaceState)
    case composable(ExtensionUISurface)

    var title: String {
        switch self {
        case .native(let state):
            state.surface.presentation.title?.trimmedNonEmpty ?? state.key.trimmedNonEmpty ?? String(localized: "Extension")
        case .composable(let surface):
            surface.header.title.trimmedNonEmpty ?? surface.title.trimmedNonEmpty ?? String(localized: "Extension")
        }
    }

    var subtitle: String? {
        switch self {
        case .native(let state): state.surface.presentation.subtitle?.trimmedNonEmpty
        case .composable(let surface): surface.header.subtitle?.trimmedNonEmpty
        }
    }

    var hints: ExtensionUISurfacePanelHints? {
        switch self {
        case .native(let state): state.surface.presentation.panelHints
        case .composable(let surface): surface.panel
        }
    }

    var extensionDisplayName: String? {
        switch self {
        case .native(let state): state.extensionDisplayName?.trimmedNonEmpty
        case .composable(let surface): surface.extensionDisplayName?.trimmedNonEmpty
        }
    }

    /// The pane's widths from the surface's declared size: the size sets only the width the pane
    /// opens at; the person's resize wins after that.
    static func widths(for hints: ExtensionUISurfacePanelHints?) -> PaneCompanionWidths {
        // Beside a chat, a panel is never narrower than an iPhone; "narrow"
        // opens at that width.
        let minimum = PaneMinimumSize.attached.width
        let ideal: CGFloat = switch hints?.size {
        case "narrow": minimum
        case "wide": 560
        default: 400
        }
        return PaneCompanionWidths(minimum: minimum, ideal: ideal, maximum: 820)
    }

    /// The pane's glyph: the surface's allowed icon, or the generic extension glyph.
    var iconName: String {
        guard let icon = hints?.icon, UIImage(systemName: icon) != nil else { return "puzzlepiece.extension" }
        return icon
    }
}

/// What a panel pane reads from its chat: the surface by id, live, and the session it belongs to.
@MainActor
struct ExtensionPanelSource {
    let surfaceId: String
    /// The chat's drawer actions: links, actions and the live lookups the readers follow.
    let actions: ExtensionSurfaceDrawerActions
    /// The surface now, or nil while the session does not hold it.
    let snapshot: () -> ExtensionPanelSnapshot?
    /// What the session is doing, for the states of a panel it does not hold.
    let session: () -> PanePanelSession
    /// The chat's title, for the line that names where the panel comes from.
    let chatTitle: () -> String?
}

/// A panel pane (`PaneRoute.panel`): one extension surface at full height beside its chat, or full
/// screen pushed on a narrow one. Oppi draws the bar (the surface's title and subtitle, and Close)
/// and the source line under it (the panel's icon, the extension that published it, and the chat it
/// belongs to); the body is the surface's own reader without its header.
///
/// The pane follows the session's snapshots as the drawer does, and draws the newest when it comes
/// back from being parked. A panel the session clears, or whose session ends, keeps its last
/// snapshot, dimmed, under "Ended" with Close Pane. A panel not published yet shows "Waiting" while
/// its session works and "Not available" once it is idle (`PaneLeafState.panel`).
@MainActor
final class ExtensionPanelViewController: UIViewController {
    private let source: ExtensionPanelSource
    /// Closes the pane; nil when the pane is a pushed page, whose Back leaves it.
    private let onClose: (() -> Void)?

    private let sourceRow = UIStackView()
    private let sourceIcon = UIImageView()
    private let sourceLabel = UILabel()
    private let endedRow = UIStackView()
    private let endedLabel = UILabel()
    private let closePaneButton = UIButton(configuration: .plain())
    private let body = UIView()
    private var reader: UIViewController?
    /// The newest snapshot the pane has seen, kept once the session clears it.
    private var lastSnapshot: ExtensionPanelSnapshot?
    private(set) var shownState: PaneLeafState?

    init(source: ExtensionPanelSource, onClose: (() -> Void)?) {
        self.source = source
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "extensionPanel.\(source.surfaceId.extensionAccessibilityIdentifierComponent)"
        if let onClose {
            let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in onClose() })
            close.accessibilityIdentifier = "extensionPanel.close"
            navigationItem.leftBarButtonItem = close
        }

        sourceIcon.setContentHuggingPriority(.required, for: .horizontal)
        sourceIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        sourceLabel.font = .preferredFont(forTextStyle: .caption1)
        sourceLabel.adjustsFontForContentSizeCategory = true
        sourceLabel.numberOfLines = 1
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceRow.addArrangedSubview(sourceIcon)
        sourceRow.addArrangedSubview(sourceLabel)
        sourceRow.spacing = 6
        sourceRow.alignment = .center
        sourceRow.isAccessibilityElement = true
        sourceRow.accessibilityIdentifier = "extensionPanel.source"

        endedLabel.text = String(localized: "Ended")
        endedLabel.font = UIFont.scaled(.subheadline, .semibold)
        endedLabel.adjustsFontForContentSizeCategory = true
        closePaneButton.configuration?.title = String(localized: "Close Pane")
        closePaneButton.accessibilityIdentifier = "extensionPanel.closePane"
        closePaneButton.addAction(UIAction { [weak self] _ in self?.closePane() }, for: .primaryActionTriggered)
        closePaneButton.setContentHuggingPriority(.required, for: .horizontal)
        endedRow.addArrangedSubview(endedLabel)
        endedRow.addArrangedSubview(closePaneButton)
        endedRow.alignment = .center
        endedRow.accessibilityIdentifier = "extensionPanel.ended"
        endedRow.isHidden = true

        let header = UIStackView(arrangedSubviews: [sourceRow, endedRow])
        header.axis = .vertical
        header.spacing = 6
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 6, trailing: 18)
        for subview in [header, body] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        // Read before anything returns early: observation re-runs this pass on each snapshot, and
        // on the session's status.
        let snapshot = source.snapshot()
        let session = source.session()
        let chatTitle = source.chatTitle()
        let surface: PanePanelSurface = snapshot != nil ? .published : (lastSnapshot != nil ? .cleared : .notPublished)
        if let snapshot { lastSnapshot = snapshot }
        let state = PaneLeafState.panel(surface: surface, session: session, chatShown: true)
        shownState = state

        let palette = (AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
        view.backgroundColor = palette.ui.bg
        navigationItem.title = lastSnapshot?.title ?? String(localized: "Panel")
        navigationItem.subtitle = lastSnapshot?.subtitle
        let extensionName = lastSnapshot?.extensionDisplayName ?? String(localized: "Extension")
        sourceIcon.image = UIImage.scaledSymbol(
            lastSnapshot?.iconName ?? "puzzlepiece.extension", style: .caption1, weight: .semibold, color: palette.ui.comment
        )
        sourceLabel.text = [extensionName, chatTitle?.trimmedNonEmpty].compactMap(\.self).joined(separator: " \u{00B7} ")
        sourceLabel.textColor = palette.ui.comment
        sourceRow.accessibilityLabel = chatTitle?.trimmedNonEmpty.map {
            String(localized: "From \(extensionName) in \($0)")
        } ?? String(localized: "From \(extensionName)")
        endedLabel.textColor = palette.ui.comment
        endedRow.isHidden = state != .ended
        closePaneButton.isHidden = onClose == nil

        if let lastSnapshot { mountReaderIfNeeded(lastSnapshot) }
        reader?.view.alpha = state == .ended ? 0.45 : 1
        contentUnavailableConfiguration = configuration(for: state, palette: palette)
    }

    private func configuration(for state: PaneLeafState, palette: ThemePalette) -> UIContentUnavailableConfiguration? {
        switch state {
        case .waiting:
            return .loadState(.loading(String(localized: "Waiting for this panel\u{2026}")), palette: palette, background: palette.ui.bg)
        case .unavailable:
            var config = UIContentUnavailableConfiguration.loadState(.empty(
                title: String(localized: "This Panel Isn\u{2019}t Available"),
                systemImage: "puzzlepiece.extension",
                message: String(localized: "The session has not published it.")
            ), palette: palette, background: palette.ui.bg)
            if let onClose {
                var button = UIButton.Configuration.plain()
                button.title = String(localized: "Close Pane")
                config.secondaryButton = button
                config.secondaryButtonProperties.primaryAction = UIAction { _ in onClose() }
            }
            return config
        default:
            return nil
        }
    }

    /// The surface's reader, without its header, once there is a snapshot to draw. It follows the
    /// session's snapshots itself and keeps the last one once the surface is cleared.
    private func mountReaderIfNeeded(_ snapshot: ExtensionPanelSnapshot) {
        guard reader == nil else { return }
        let actions = source.actions
        let id = source.surfaceId
        var liveNative: (@MainActor () -> ExtensionUINativeSurface?)?
        if let lookup = actions.liveSurface { liveNative = { lookup(id) } }
        var liveComposable: (@MainActor () -> ExtensionUISurface?)?
        if let lookup = actions.liveComposableSurface { liveComposable = { lookup(id) } }
        // The suffixes the drawer's full-screen readers use, so a control has one identifier.
        let mounted: UIViewController = switch snapshot {
        case .native(let state):
            ExtensionNativeSurfaceDetailViewController(
                surface: state.surface,
                identifierSuffix: id.extensionAccessibilityIdentifierComponent,
                title: snapshot.title,
                subtitle: snapshot.subtitle,
                linkContext: actions.linkContext,
                onOpenURL: actions.onOpenURL,
                sessionMenu: actions.sessionMenu,
                liveSurface: liveNative,
                showsHeader: false,
                onLeave: {}
            )
        case .composable(let surface):
            ExtensionSurfaceDetailViewController(
                content: ExtensionSurfaceReaderContent(
                    surface: surface,
                    identifierSuffix: "surface-\(ExtensionSurfaceIdentity.key(id))",
                    title: snapshot.title,
                    subtitle: snapshot.subtitle,
                    liveSurface: liveComposable,
                    pendingAction: actions.pendingAction,
                    sendAction: actions.sendAction,
                    server: actions.server,
                    openURL: actions.onOpenURL,
                    sessionMenu: actions.sessionMenu
                ),
                showsHeader: false,
                onLeave: {}
            )
        }
        addChild(mounted)
        mounted.view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(mounted.view)
        NSLayoutConstraint.activate([
            mounted.view.topAnchor.constraint(equalTo: body.topAnchor),
            mounted.view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            mounted.view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            mounted.view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        mounted.didMove(toParent: self)
        reader = mounted
    }

    private func closePane() {
        onClose?()
    }

    /// Opens a place one of the panel's tiles names on the panel's own stack: it fills the pane
    /// (beside the chat, or full screen on a narrow window) with Back to the panel, as a Git pane's
    /// rows and a split pane's files open, never in a new pane.
    func openPlace(_ entry: PaneStackEntry) {
        guard let root = AppRootEnvironment.near(self) else { return }
        Router.push(PaneSplitScreens.page(entry, root: root), from: self)
    }
}
