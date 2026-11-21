import UIKit

/// A `tiles` node: places drawn as the Pinned screen draws pins (`PinTileView`), each opening its
/// `oppi://` pane link: in a panel pane on that pane's own stack, elsewhere as a pin opens (beside
/// the chat on a wide window, in the stack on a narrow one). A tile reads its preview through the same pipeline (`PinPreviewStore`), and a target the
/// server says is gone draws dimmed, "Not found", and opens nothing.
///
/// The tiles wrap in rows, as many across as fit at 160 points or more (never fewer than two).
/// Everything a tile shows comes from its link and the words the node carries; nothing here reads
/// which extension sent it.
@MainActor
final class BlocksTilesView: UIView, BlocksColumnFillable {
    private static let minimumWidth: CGFloat = 160
    private static let columnSpacing: CGFloat = 14
    private static let rowSpacing: CGFloat = 16

    private let previews = PinPreviewStore()
    private let grid = UIStackView()
    private var controls: [String: TileControl] = [:]
    private var tiles: [ExtensionUISurfaceTile] = []
    private var columns = 2
    private var server: ExtensionSurfaceServer?
    private var identifierRoot = ""
    private var palette: ThemePalette = ThemeRuntimeState.currentThemeID().palette

    override init(frame: CGRect) {
        super.init(frame: frame)
        grid.axis = .vertical
        grid.spacing = Self.rowSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.arrange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        tiles content: ExtensionUISurfaceTilesNode,
        node: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        let changed = tiles.map(\.id) != content.items.map(\.id)
        palette = environment.palette
        identifierRoot = environment.identifierRoot
        server = environment.context.server
        accessibilityIdentifier = environment.identifier(for: node)
        if tiles != content.items {
            // A new list of places reads their previews again; an unchanged one keeps them.
            previews.refresh()
        }
        tiles = content.items
        for tile in content.items where controls[tile.id] == nil {
            let control = TileControl()
            control.onOpen = { [weak self] route in self?.open(route) }
            controls[tile.id] = control
        }
        let live = Set(content.items.map(\.id))
        for id in controls.keys where !live.contains(id) {
            controls[id]?.removeFromSuperview()
            controls[id] = nil
        }
        if changed { arrange() }
        setNeedsUpdateProperties()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // Each time the tiles come on screen they read their places again, as Pinned does.
        previews.refresh()
        setNeedsUpdateProperties()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let usable = bounds.width
        let fit = max(2, Int((usable + Self.columnSpacing) / (Self.minimumWidth + Self.columnSpacing)))
        if fit != columns {
            columns = fit
            arrange()
        }
    }

    /// Puts each tile in its row of the grid.
    private func arrange() {
        for row in grid.arrangedSubviews { row.removeFromSuperview() }
        let ordered = tiles.compactMap { controls[$0.id] }
        let caption = PinTileView.captionHeight(for: traitCollection)
        for control in ordered { control.sizing.forEach { $0.isActive = false } }
        for start in stride(from: 0, to: ordered.count, by: columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = Self.columnSpacing
            row.alignment = .top
            row.distribution = .fillEqually
            for control in ordered[start ..< min(start + columns, ordered.count)] {
                control.sizing = [
                    control.heightAnchor.constraint(
                        equalTo: control.widthAnchor, multiplier: PinTileView.artworkAspect, constant: caption
                    ),
                ]
                NSLayoutConstraint.activate(control.sizing)
                row.addArrangedSubview(control)
            }
            // A short last row keeps its tiles the width of the rows above.
            while row.arrangedSubviews.count < columns { row.addArrangedSubview(UIView()) }
            grid.addArrangedSubview(row)
        }
    }

    /// Draws each tile from its link, its words, and what its preview has read; reading the
    /// previews here redraws a tile when one arrives.
    override func updateProperties() {
        super.updateProperties()
        let serverID = server?.id
        let connection = server?.connection
        for tile in tiles {
            guard let control = controls[tile.id] else { continue }
            let identifier = ExtensionSurfaceIdentity.element(root: identifierRoot, key: tile.id)
            guard let route = Self.route(of: tile), let kind = PinKind(route) else {
                control.show(nil, content: Self.unopenable(tile, palette: palette), palette: palette, identifier: identifier)
                continue
            }
            let preview = connection.flatMap { connection in
                serverID.flatMap { previews.preview(for: route, serverId: $0, connection: connection, checksPresence: true) }
            }
            let place = Self.place(tile, route: route, preview: preview, serverID: serverID, connection: connection)
            control.show(
                place.isGone ? nil : route,
                content: PinTileView.Content.make(place: place, kind: kind, preview: preview, palette: palette),
                palette: palette,
                identifier: identifier
            )
        }
    }

    /// A tile as the Pinned screen would show a pin of the same place: the node's words over the
    /// place's own, why it cannot open over both.
    static func place(
        _ tile: ExtensionUISurfaceTile,
        route: PaneRoute,
        preview: PinPreview?,
        serverID: String?,
        connection: ServerConnection?
    ) -> PinTilePlace {
        let names = connection.map { PinsSection.names(for: route, connection: $0) } ?? .none
        let isGone = preview?.isMissing == true
        let isOff = PinsSection.isOff(route, connection: connection)
        let detail: String? = if isGone {
            PaneRoute.notFound
        } else if isOff {
            String(localized: "Godot Pane is off")
        } else {
            tile.subtitle ?? route.placeLocation(names)
        }
        var isLocked = false
        if let serverID, let workspaceId = route.workspaceId {
            isLocked = ScopedLockService.shared.isLocked(.workspace(serverId: serverID, workspaceId: workspaceId))
        }
        return PinTilePlace(
            route: route,
            // A game's own name is what its preview read from the server.
            title: tile.title ?? route.placeName(names, gameName: preview?.title),
            detail: detail,
            keepsTitle: tile.title != nil,
            keepsDetail: tile.subtitle != nil,
            isGone: isGone,
            isOff: isOff,
            isLocked: isLocked
        )
    }

    /// The route a tile's link names. The server refuses a tile whose link is not a pane link
    /// a pin could name, so nil only meets a newer server's route this build does not open.
    static func route(of tile: ExtensionUISurfaceTile) -> PaneRoute? {
        guard let url = URL(string: tile.link), case .success(let link)? = PaneLinkCodec.decode(url) else { return nil }
        return link.route
    }

    /// A tile this build cannot open: its words, dimmed, on a plain glyph.
    private static func unopenable(_ tile: ExtensionUISurfaceTile, palette: ThemePalette) -> PinTileView.Content {
        let tint = palette.ui.comment
        return PinTileView.Content(
            artwork: PinArtwork(
                image: UIImage(systemName: "questionmark.square.dashed"), fit: .glyph,
                tint: tint, backdrop: tint.withAlphaComponent(0.14)
            ),
            title: tile.title ?? tile.link,
            detail: tile.subtitle,
            children: [],
            isDimmed: true,
            isLocked: false
        )
    }

    /// Opens a place. In a panel pane it opens on that pane's own stack, with Back to the panel
    /// (`ExtensionPanelViewController.openPlace`). Elsewhere (a chat's drawer, its full-screen
    /// reader) it opens as a pin opens: `AppOpenRequest(link:)` beside the focused pane on a wide
    /// window, else in the main stack.
    private func open(_ route: PaneRoute) {
        guard let root = AppRootEnvironment.near(self) else { return }
        let serverID = server?.id
        if let serverID, let panel = sequence(first: self as UIResponder, next: \.next).lazy
            .compactMap({ $0 as? ExtensionPanelViewController }).first {
            panel.openPlace(PaneStackEntry(serverId: serverID, route: route))
            return
        }
        let link = PaneLink(server: serverID, route: route)
        root.opener.open(AppOpenRequest(link: link, origin: .link, sourceServerID: serverID))
    }
}

/// One tile's tap target: the shared tile view, pressed while a touch holds it. It is the tile's
/// accessibility element, a button named by the tile's words.
private final class TileControl: UIControl {
    private let tile = PinTileView()
    /// The place a tap opens; nil for a tile that is gone or that this build cannot open.
    private(set) var route: PaneRoute?
    /// The constraints the tiles view sizes this tile with, replaced at each arrangement.
    var sizing: [NSLayoutConstraint] = []
    /// Opens the tile's place: a touch that lifts inside it, or VoiceOver's activation. A plain
    /// `UIControl` sends no primary action of its own, so the tile sends on touch-up.
    var onOpen: ((PaneRoute) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        tile.isUserInteractionEnabled = false
        tile.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tile)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        addTarget(self, action: #selector(open), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func open() {
        guard isEnabled, let route else { return }
        onOpen?(route)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, route != nil else { return false }
        open()
        return true
    }

    func show(_ route: PaneRoute?, content: PinTileView.Content, palette: ThemePalette, identifier: String) {
        self.route = route
        isEnabled = route != nil
        tile.show(content, palette: palette)
        accessibilityIdentifier = identifier
        accessibilityLabel = content.accessibilityLabel
        accessibilityTraits = route == nil ? [.button, .notEnabled] : .button
    }

    override var isHighlighted: Bool {
        didSet { tile.isPressed = isHighlighted }
    }
}
