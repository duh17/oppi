import UIKit

/// Session identity badge. Ordinary sessions paint the Pi mark; saved-Agent
/// rows paint the launch snapshot icon and never consult Pi identity. The
/// artwork is `EntityIcon`'s and the moving is `IconChoiceUIView`'s; this view
/// places it at the badge's size and shape and passes on the row's burst
/// (`playBurst()`, `stopBurst()`) when the session needs the person.
final class SessionGridBadgeView: UIView {
    private var icon: IconChoiceUIView
    /// The badge's side in points, and the shape it draws the icon in: the
    /// rounded tile, or the circle a session row draws it as.
    private(set) var iconSize: CGFloat
    let shape: IconShape

    var sessionId: String = "" {
        didSet { updateIfNeeded() }
    }

    var agentId: String? {
        didSet { updateIfNeeded() }
    }

    var agentIcon: IconChoice? {
        didSet { updateIfNeeded() }
    }

    var iconAssetCache: IconAssetCache? {
        didSet {
            guard iconAssetCache !== oldValue else { return }
            lastApplied = nil
            updateIfNeeded()
        }
    }

    /// What the badge last drew, so a pass that changes nothing keeps its image.
    private var lastApplied: String?
    private var isConfiguring = false

    /// `iconSize` is the badge's own side: its holder lays it out at that
    /// square, and the icon draws to fill it in `shape`. The Agent icon view
    /// listens for artwork and theme changes itself, so the badge only says
    /// what to draw.
    init(iconSize: CGFloat, shape: IconShape = .tile) {
        self.iconSize = iconSize
        self.shape = shape
        icon = IconChoiceUIView(frameSize: iconSize, shape: shape)
        super.init(frame: .zero)
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = .image
        backgroundColor = .clear
        placeIcon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    private func placeIcon() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func prepareForReuse() {
        lastApplied = nil
        icon.clear()
    }

    /// Draws the icon at a new side. A session row calls this when the person
    /// changes Settings › Session Rows › Session Icons while the row is on
    /// screen: `IconChoiceUIView` draws at its own size, so it is replaced and
    /// given the badge's identity again. The holder lays the badge out at
    /// `iconSize`, so it is the caller's to resize too.
    func setIconSize(_ side: CGFloat) {
        guard side != iconSize else { return }
        iconSize = side
        icon.removeFromSuperview()
        icon = IconChoiceUIView(frameSize: side, shape: shape)
        placeIcon()
        lastApplied = nil
        updateIfNeeded()
    }

    /// Applies one session identity atomically. SwiftUI and collection rows use
    /// this instead of transiently configuring a saved-Agent row as global.
    func configure(
        sessionId: String,
        agentId: String?,
        agentIcon: IconChoice?,
        iconAssetCache: IconAssetCache?
    ) {
        isConfiguring = true
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentIcon = agentIcon
        self.iconAssetCache = iconAssetCache
        isConfiguring = false
        updateIfNeeded()
    }

    /// Plays the icon once, briefly; the row asks when its session needs the person.
    func playBurst() {
        icon.playBurst()
    }

    /// Stops a playing burst; the icon rests on its still drawing.
    func stopBurst() {
        icon.stopBurst()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: iconSize, height: iconSize)
    }

    private func updateIfNeeded() {
        guard !isConfiguring else { return }
        let presentation = AssistantIdentityPresentation.resolve(
            agentId: agentId,
            agentIcon: agentIcon
        )
        let identity: String
        switch presentation {
        case .globalAvatar:
            accessibilityLabel = PiAvatar.accessibilityLabel
            identity = "assistant:pi"
        case .agent(let content):
            accessibilityLabel = "Saved Agent, \(content.accessibilityDescription)"
            identity = "agent:\(content)"
        }
        guard identity != lastApplied else { return }
        lastApplied = identity

        switch presentation {
        case .agent:
            icon.apply(.choice(agentIcon, purpose: .agent, sandbox: false), assetCache: iconAssetCache)
        case .globalAvatar:
            icon.apply(.piAvatar)
        }
    }
}
