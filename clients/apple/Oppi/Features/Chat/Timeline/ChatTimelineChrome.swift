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

/// The empty timeline: the session's Agent icon (Genmoji included) or the Pi
/// mark, centered in the space between the bars. It fades in after 300 ms,
/// so a session that is only briefly empty while its history loads never
/// flashes it.
final class ChatEmptyStateView: UIView {
    private static let side: CGFloat = 112
    private let piTile = UIView()
    private let piIcon = IconChoiceUIView(size: side, frameSize: side)
    private let agentIcon = IconChoiceUIView(size: 64, frameSize: side)
    private var top: NSLayoutConstraint?
    private var bottom: NSLayoutConstraint?
    private var shownSessionID: String?
    private var appliedIcon: IconKey?
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
        piTile.layer.cornerRadius = Self.side * 0.32
        piTile.layer.cornerCurve = .continuous
        piTile.isAccessibilityElement = true
        piTile.accessibilityTraits = .image
        piTile.accessibilityLabel = PiAvatar.accessibilityLabel
        // The hero agent icon scales optically like the chat's other agent marks.
        agentIcon.transform = CGAffineTransform(
            scaleX: ChatAgentIconStyle.heroVisualScale,
            y: ChatAgentIconStyle.heroVisualScale
        )
        agentIcon.isAccessibilityElement = true
        agentIcon.accessibilityTraits = .image
        for view in [piTile, piIcon, agentIcon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
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
            piTile.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            piTile.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            piTile.widthAnchor.constraint(equalToConstant: Self.side),
            piTile.heightAnchor.constraint(equalToConstant: Self.side),
            piIcon.centerXAnchor.constraint(equalTo: piTile.centerXAnchor),
            piIcon.centerYAnchor.constraint(equalTo: piTile.centerYAnchor),
            agentIcon.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            agentIcon.centerYAnchor.constraint(equalTo: area.centerYAnchor),
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
        let key = IconKey(
            identity: AssistantIdentityPresentation.resolve(agentId: configuration.agentId, agentIcon: configuration.agentIcon),
            icon: configuration.agentIcon,
            themeID: themeID,
            hasAssetCache: configuration.iconAssetCache != nil
        )
        if key != appliedIcon {
            appliedIcon = key
            let colors = ComposerThemeColors(palette: themeID.palette)
            switch key.identity {
            case .globalAvatar:
                piTile.backgroundColor = colors.comment.withAlphaComponent(0.10)
                piIcon.apply(.piAvatar, colors: colors)
                piTile.isHidden = false
                piIcon.isHidden = false
                agentIcon.isHidden = true
            case .agent(let content):
                agentIcon.apply(
                    .choice(key.icon, purpose: .agent, sandbox: false),
                    colors: colors,
                    assetCache: configuration.iconAssetCache
                )
                agentIcon.accessibilityLabel = content.accessibilityDescription
                piTile.isHidden = true
                piIcon.isHidden = true
                agentIcon.isHidden = false
            }
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
