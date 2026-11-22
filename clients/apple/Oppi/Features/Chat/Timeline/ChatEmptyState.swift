import UIKit

/// What an empty chat says about the Agent it will talk to: the name the
/// Agents list shows, and its description when it has one.
struct ChatAgentGreeting: Equatable {
    let name: String
    let description: String?
}

/// The chat's half of the empty timeline: what its greeting says, where its
/// circle lands when the first message arrives, and the two moments the chat
/// reads that greeting and drops it again. Nil for a Pi session, which keeps
/// the plain hero.
struct ChatEmptyChatHost {
    /// The Agent's name and description, as the chat has read them. A value,
    /// not a read: two configurations then differ when the greeting lands.
    var greeting: ChatAgentGreeting?
    /// The title's icon in window coordinates: the hero's circle lands there.
    var titleIconFrame: @MainActor () -> CGRect?
    /// The empty timeline is up: read the Agent's greeting.
    var onShown: @MainActor () -> Void
    /// It is gone: drop the greeting, so the composer says "Message…" again.
    var onLeft: @MainActor () -> Void
}

/// How big the empty chat's circle is. An Agent's greeting takes the pane's
/// width (a phone-width pane, an iPhone's main pane, a wide one) and its height
/// caps it, so a short pane (a pane above another, the Duo's) keeps the name and
/// description under the circle on screen. A Pi session keeps the mark it has
/// always shown.
enum ChatEmptyHeroMetrics {
    /// The Pi mark on an empty chat, unchanged by the greeting's sizes.
    static let piMarkSide: CGFloat = 112

    static func greetingSide(paneWidth: CGFloat, paneHeight: CGFloat) -> CGFloat {
        let byWidth: CGFloat = switch paneWidth {
        case ..<340: 120
        case ..<390: 140
        case ..<560: 168
        default: 180
        }
        return max(96, min(byWidth, paneHeight * 0.3)).rounded()
    }

    /// One step smaller under a small circle, so a 140 pt hero's name does not
    /// dwarf it. Scaled by Dynamic Type like every other system style.
    static func nameStyle(for side: CGFloat) -> UIFont.TextStyle {
        side < 160 ? .title3 : .title1
    }
}

/// The empty timeline: the session's Agent (Genmoji included) or the Pi mark,
/// on the same circle as the Agent page's hero, with the Agent's name and
/// description under it, centered in the space between the bars. It fades in
/// after 300 ms, so a session that is only briefly empty while its history
/// loads never flashes it, and plays one icon moment as it settles.
final class ChatEmptyStateView: UIView {
    /// The Agent's icon on its circle, at `ChatEmptyHeroMetrics`' side.
    private var icon: IconChoiceUIView?
    private let nameLabel = ExtensionChromeFont.label(.title1, .bold)
    private let descriptionLabel = ExtensionChromeFont.label(.subheadline, lines: 3)
    private let hero = UIStackView()
    private var top: NSLayoutConstraint?
    private var bottom: NSLayoutConstraint?
    private var appliedSide: CGFloat = 0
    /// An Agent's chat sizes and names its circle; a Pi session does neither.
    private var showsAgentGreeting = false
    private var appliedGreeting: ChatAgentGreeting?
    private var shownSessionID: String?
    private var appliedIcon: IconKey?
    /// The icon's artwork source, kept so a resized circle draws it again.
    private weak var appliedAssetCache: IconAssetCache?
    private var revealTask: Task<Void, Never>?

    /// What the icon shows; it renders again only when this changes.
    private struct IconKey: Equatable {
        let identity: AssistantIdentityPresentation
        let icon: IconChoice?
        let themeID: ThemeID
        let hasAssetCache: Bool
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let area = UILayoutGuide()
        addLayoutGuide(area)
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.accessibilityIdentifier = "chat.emptyState.name"
        descriptionLabel.textAlignment = .center
        descriptionLabel.accessibilityIdentifier = "chat.emptyState.description"
        // Only an Agent's chat names its circle; Pi starts without.
        nameLabel.isHidden = true
        descriptionLabel.isHidden = true
        hero.axis = .vertical
        hero.alignment = .center
        hero.spacing = 5
        hero.addArrangedSubview(nameLabel)
        hero.addArrangedSubview(descriptionLabel)
        hero.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hero)
        // Inside the timeline's safe area and then the bars' overlap, as the
        // hosted SwiftUI empty state laid it out.
        let top = area.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor)
        let bottom = area.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
        self.top = top
        self.bottom = bottom
        NSLayoutConstraint.activate([
            top, bottom,
            area.leadingAnchor.constraint(equalTo: leadingAnchor),
            area.trailingAnchor.constraint(equalTo: trailingAnchor),
            hero.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            hero.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            hero.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor, constant: 24),
            hero.trailingAnchor.constraint(lessThanOrEqualTo: area.trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        revealTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = showsAgentGreeting
            ? ChatEmptyHeroMetrics.greetingSide(paneWidth: bounds.width, paneHeight: bounds.height)
            : ChatEmptyHeroMetrics.piMarkSide
        guard side != appliedSide else { return }
        appliedSide = side
        nameLabel.font = .scaled(ChatEmptyHeroMetrics.nameStyle(for: side), .bold)
        rebuildIcon(at: side)
    }

    func apply(configuration: ChatTimelineConfiguration, themeID: ThemeID) {
        top?.constant = configuration.topOverlap
        bottom?.constant = -configuration.bottomOverlap
        let palette = themeID.palette
        nameLabel.textColor = palette.ui.fg
        descriptionLabel.textColor = palette.ui.comment
        let key = IconKey(
            identity: AssistantIdentityPresentation.resolve(agentId: configuration.agentId, agentIcon: configuration.agentIcon),
            icon: configuration.agentIcon,
            themeID: themeID,
            hasAssetCache: configuration.iconAssetCache != nil
        )
        if key != appliedIcon {
            appliedIcon = key
            appliedAssetCache = configuration.iconAssetCache
            icon?.accessibilityLabel = Self.accessibilityLabel(for: key.identity)
            renderIcon()
        }

        if showsAgentGreeting != (configuration.emptyChat != nil) {
            showsAgentGreeting = configuration.emptyChat != nil
            setNeedsLayout()
        }

        // The Agent's name and description, once the chat has read them.
        let greeting = configuration.emptyChat?.greeting
        if greeting != appliedGreeting {
            appliedGreeting = greeting
            nameLabel.text = greeting?.name
            descriptionLabel.text = greeting?.description
            nameLabel.isHidden = greeting?.name.isEmpty != false
            descriptionLabel.isHidden = greeting?.description?.isEmpty != false
        }

        guard shownSessionID != configuration.sessionId else { return }
        shownSessionID = configuration.sessionId
        alpha = 0
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            if UIAccessibility.isReduceMotionEnabled {
                self.alpha = 1
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn) { self.alpha = 1 }
            }
            // The chat's own moment, as its title's icon plays: the hero is the
            // other half of a chat opening.
            self.icon?.playBurst()
        }
    }

    /// One burst of the hero, for the moments `ChatViewController` plays.
    func playIconMoment() {
        icon?.playBurst()
    }

    /// The hero leaves as the first message lands: its circle flies into the
    /// title's own circle, one move up and smaller, so the title takes over
    /// where the snapshot stops. With motion off (`MotionPolicy`) the same
    /// beat is a cross-fade where the hero stands.
    func leave(into titleFrame: CGRect?) {
        revealTask?.cancel()
        guard let window, alpha > 0.01, let titleFrame, MotionPolicy.playsMoments,
              let icon, let snapshot = icon.snapshotView(afterScreenUpdates: false) else {
            UIView.animate(withDuration: 0.18) { self.alpha = 0 }
            return
        }
        snapshot.frame = icon.convert(icon.bounds, to: window)
        window.addSubview(snapshot)
        icon.alpha = 0
        UIView.animate(withDuration: 0.34, delay: 0, options: .curveEaseInOut) {
            snapshot.frame = titleFrame
            self.nameLabel.alpha = 0
            self.descriptionLabel.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }

    /// A circle of `side` points. `IconChoiceUIView` draws for the size it is
    /// made at, so a pane that resizes (a divider, a rotation) makes a new one.
    private func rebuildIcon(at side: CGFloat) {
        let icon = IconChoiceUIView(frameSize: side, shape: .circle)
        icon.isAccessibilityElement = true
        icon.accessibilityTraits = .image
        icon.accessibilityIdentifier = "chat.emptyState.hero"
        icon.accessibilityLabel = appliedIcon.map { Self.accessibilityLabel(for: $0.identity) }
        self.icon?.removeFromSuperview()
        self.icon = icon
        hero.insertArrangedSubview(icon, at: 0)
        hero.setCustomSpacing(18, after: icon)
        // The labels start hidden: only an Agent's chat has them.
        nameLabel.isHidden = appliedGreeting?.name.isEmpty != false
        descriptionLabel.isHidden = appliedGreeting?.description?.isEmpty != false
        renderIcon()
    }

    private func renderIcon() {
        guard let icon, let key = appliedIcon else { return }
        switch key.identity {
        case .globalAvatar:
            icon.apply(.piAvatar)
        case .agent:
            icon.apply(
                .choice(key.icon, purpose: .agent, sandbox: false),
                assetCache: key.hasAssetCache ? appliedAssetCache : nil
            )
        }
    }

    private static func accessibilityLabel(for identity: AssistantIdentityPresentation) -> String {
        switch identity {
        case .globalAvatar: PiAvatar.accessibilityLabel
        case .agent(let content): content.accessibilityDescription
        }
    }
}

extension ChatTimelineController {
    func updateOwnedEmptyOverlay(
        isEmpty: Bool,
        configuration: ChatTimelineConfiguration,
        collectionView: UICollectionView
    ) {
        guard isEmpty, !configuration.isBusy else {
            let overlay = ownedClock.emptyOverlay
            if let overlay {
                // The first message landed: an Agent chat's hero flies into the
                // title's circle; a Pi chat's hero goes as it always did.
                if !isEmpty, let host = configuration.emptyChat {
                    overlay.leave(into: host.titleIconFrame())
                }
                collectionView.backgroundView = nil
                ownedClock.emptyOverlay = nil
            }
            configuration.emptyChat?.onLeft()
            return
        }
        let overlay = ownedClock.emptyOverlay ?? ChatEmptyStateView()
        ownedClock.emptyOverlay = overlay
        overlay.apply(
            configuration: configuration,
            themeID: contentRoot?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        )
        if collectionView.backgroundView !== overlay {
            collectionView.backgroundView = overlay
        }
        configuration.emptyChat?.onShown()
    }
}
