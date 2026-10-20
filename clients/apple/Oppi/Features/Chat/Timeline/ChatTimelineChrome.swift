import UIKit

enum TimelineRenderWindowPolicy {
    enum ShowEarlierAction: Equatable {
        case revealLocal(newWindow: Int)
        case fetchOlderPage
        case none
    }

    static let standardWindow = 80
    static let renderWindowStep = 60

    static func syncedWindow(currentWindow: Int, totalItems: Int) -> Int {
        let clampedTotal = max(0, totalItems)
        let clampedCurrent = min(max(0, currentWindow), clampedTotal)
        let baseline = min(clampedTotal, standardWindow)
        return max(clampedCurrent, baseline)
    }

    static func showsShowEarlierControl(hiddenCount: Int, hasOlderServerPage: Bool) -> Bool {
        hiddenCount > 0 || hasOlderServerPage
    }

    static func showEarlierAction(
        currentWindow: Int,
        totalItems: Int,
        step: Int,
        hasOlderServerPage: Bool
    ) -> ShowEarlierAction {
        let clampedTotal = max(0, totalItems)
        let clampedCurrent = min(max(0, currentWindow), clampedTotal)
        if clampedCurrent < clampedTotal {
            return .revealLocal(newWindow: min(clampedTotal, clampedCurrent + max(1, step)))
        }
        return hasOlderServerPage ? .fetchOlderPage : .none
    }
}
/// The chat collection view reaches up under the navigation bar so rows can
/// scroll under Liquid Glass, with `contentInsetAdjustmentBehavior` `.never`.
///
/// The overlap is measured from frames, never from a safe-area inset. Both
/// frames are in window coordinates: the timeline starts under the navigation
/// bar, and the context bar sits below that bar. `header.maxY - timeline.minY`
/// then covers the bar and the chrome above it, and follows any change to
/// either.
enum ChatTimelineChromeOverlap {
    static func topInset(timelineFrame: CGRect, headerFrame: CGRect) -> CGFloat {
        if timelineFrame == .zero, headerFrame == .zero {
            return 0
        }
        return max(0, headerFrame.maxY - timelineFrame.minY)
    }
}

/// The empty timeline: the session's Agent icon or the Pi mark, centered in
/// the space between the bars. It fades in after 300 ms, so a session that
/// is only briefly empty while its history loads never flashes it.
final class ChatEmptyStateView: UIView {
    private let icon = UIImageView()
    private let emoji = UILabel()
    private let tile = UIView()
    private var top: NSLayoutConstraint?
    private var bottom: NSLayoutConstraint?
    private var shownSessionID: String?
    private var revealTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let area = UILayoutGuide()
        addLayoutGuide(area)
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        emoji.textAlignment = .center
        icon.contentMode = .scaleAspectFit
        // The tile is the one element; the glyph inside it is not another.
        icon.accessibilityElementsHidden = true
        emoji.accessibilityElementsHidden = true
        for view in [tile, icon, emoji] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let top = area.topAnchor.constraint(equalTo: topAnchor)
        let bottom = area.bottomAnchor.constraint(equalTo: bottomAnchor)
        self.top = top
        self.bottom = bottom
        NSLayoutConstraint.activate([
            top, bottom,
            area.leadingAnchor.constraint(equalTo: leadingAnchor),
            area.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            tile.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 112),
            tile.heightAnchor.constraint(equalToConstant: 112),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            emoji.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        revealTask?.cancel()
    }

    func apply(configuration: ChatTimelineConfiguration, themeID: ThemeID) {
        top?.constant = configuration.topOverlap
        bottom?.constant = -configuration.bottomOverlap
        let palette = themeID.palette
        switch AssistantIdentityPresentation.resolve(agentId: configuration.agentId, agentIcon: configuration.agentIcon) {
        case .globalAvatar:
            tile.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.10)
            tile.layer.cornerRadius = 112 * 0.32
            icon.image = PiAvatarRenderer.render(size: 224, themeID: themeID)
            icon.transform = .identity
            setIconSize(112)
            icon.isHidden = false
            emoji.isHidden = true
            tile.accessibilityLabel = PiAvatar.accessibilityLabel
        case .agent(let content):
            tile.backgroundColor = .clear
            tile.layer.cornerRadius = 0
            // The hero agent icon: 64pt content in its 112pt frame, scaled
            // optically like the chat's other agent marks.
            let side = AgentIconSizingPolicy.contentSize(
                baseSize: 64,
                scaledSize: UIFontMetrics(forTextStyle: .body).scaledValue(for: 64),
                frameSize: 112
            )
            let scale = CGAffineTransform(scaleX: ChatAgentIconStyle.heroVisualScale, y: ChatAgentIconStyle.heroVisualScale)
            icon.transform = scale
            emoji.transform = scale
            switch content {
            case .text(let text):
                emoji.text = text
                emoji.font = .systemFont(ofSize: side)
                icon.isHidden = true
                emoji.isHidden = false
            case .symbol(let name):
                showSymbol(name, side: side, palette: palette)
            case .genmoji, .fallback:
                showSymbol(IconChoiceRenderPurpose.agent.defaultSymbolName, side: side, palette: palette)
            }
            tile.accessibilityLabel = content.accessibilityDescription
        }
        tile.isAccessibilityElement = true
        tile.accessibilityTraits = .image

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
        }
    }

    private var iconSize: [NSLayoutConstraint] = []

    private func setIconSize(_ side: CGFloat) {
        NSLayoutConstraint.deactivate(iconSize)
        iconSize = [icon.widthAnchor.constraint(equalToConstant: side), icon.heightAnchor.constraint(equalToConstant: side)]
        NSLayoutConstraint.activate(iconSize)
    }

    private func showSymbol(_ name: String, side: CGFloat, palette: ThemePalette) {
        icon.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: side))?
            .withTintColor(UIColor(palette.blue), renderingMode: .alwaysOriginal)
        NSLayoutConstraint.deactivate(iconSize)
        iconSize = []
        icon.isHidden = false
        emoji.isHidden = true
    }
}

extension ChatTimelineController {
    func updateOwnedEmptyOverlay(
        isEmpty: Bool,
        configuration: ChatTimelineConfiguration,
        collectionView: UICollectionView
    ) {
        guard isEmpty, !configuration.isBusy else {
            if ownedClock.emptyOverlay != nil {
                collectionView.backgroundView = nil
                ownedClock.emptyOverlay = nil
            }
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
    }
}
