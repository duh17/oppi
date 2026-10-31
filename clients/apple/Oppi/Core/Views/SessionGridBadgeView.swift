import UIKit

/// Session identity badge. Ordinary sessions paint the Pi mark; saved-Agent
/// rows paint the launch snapshot icon and never consult Pi identity. The
/// artwork is `EntityIcon`'s; this view places it at the badge's size.
final class SessionGridBadgeView: UIView {
    private let imageView = UIImageView()

    var sessionId: String = "" {
        didSet { updateIfNeeded() }
    }

    var agentId: String? {
        didSet { updateIfNeeded() }
    }

    var agentIcon: IconChoice? {
        didSet { updateIfNeeded() }
    }

    var agentVisualScale: CGFloat = 1 {
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
    private var iconLoadObserver: NSObjectProtocol?
    private var isConfiguring = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = .image
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        iconLoadObserver = NotificationCenter.default.addObserver(
            forName: .oppiEntityIconDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastApplied = nil
                self?.updateIfNeeded()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange(_:)),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    isolated deinit {
        if let iconLoadObserver {
            NotificationCenter.default.removeObserver(iconLoadObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func prepareForReuse() {
        lastApplied = nil
        imageView.image = nil
    }

    /// Applies one session identity atomically. SwiftUI and collection rows use
    /// this instead of transiently configuring a saved-Agent row as global.
    func configure(
        sessionId: String,
        agentId: String?,
        agentIcon: IconChoice?,
        iconAssetCache: IconAssetCache?,
        agentVisualScale: CGFloat = 1
    ) {
        isConfiguring = true
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentIcon = agentIcon
        self.iconAssetCache = iconAssetCache
        self.agentVisualScale = agentVisualScale
        isConfiguring = false
        updateIfNeeded()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 18, height: 18)
    }

    @objc private func themeDidChange(_ notification: Notification) {
        // The mark's colors follow the theme, so the badge draws again.
        lastApplied = nil
        updateIfNeeded()
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
        imageView.transform = switch presentation {
        case .agent:
            CGAffineTransform(scaleX: agentVisualScale, y: agentVisualScale)
        case .globalAvatar:
            .identity
        }

        let applied = "\(sessionId):\(ThemeRuntimeState.currentThemeID().rawValue):\(identity)"
        guard applied != lastApplied else { return }
        lastApplied = applied

        switch presentation {
        case .agent:
            imageView.image = EntityIcon.image(.agent(agentIcon), size: 36, assets: iconAssetCache)
        case .globalAvatar:
            imageView.image = EntityIcon.image(.pi, size: 36)
        }
    }
}
