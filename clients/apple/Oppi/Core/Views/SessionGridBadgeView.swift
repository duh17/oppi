import UIKit

/// Session identity badge. Ordinary sessions paint the Pi mark; saved-Agent
/// rows paint the launch snapshot icon and never consult Pi identity.
final class SessionGridBadgeView: UIView {

    private let imageView = UIImageView()
    private static var imageCache = NSCache<NSString, UIImage>()

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
            loadTask?.cancel()
            lastCacheKey = nil
            updateIfNeeded()
        }
    }

    private var lastCacheKey: String?
    private var loadTask: Task<Void, Never>?
    private var currentGenmojiAssetID: String?
    private var isConfiguring = false

    #if DEBUG
        var currentGenmojiAssetIDForTesting: String? { currentGenmojiAssetID }
    #endif

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange(_:)),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func prepareForReuse() {
        loadTask?.cancel()
        loadTask = nil
        lastCacheKey = nil
        currentGenmojiAssetID = nil
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
        // Rendered Pi and Agent icons can use theme colors, so a theme
        // switch must invalidate all cached rasters before redrawing.
        Self.imageCache.removeAllObjects()
        lastCacheKey = nil
        updateIfNeeded()
    }

    private func updateIfNeeded() {
        guard !isConfiguring else { return }
        let themeId = ThemeRuntimeState.currentThemeID()
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

        let cacheKey = "\(sessionId):\(themeId):\(identity)"
        guard cacheKey != lastCacheKey else { return }
        lastCacheKey = cacheKey
        loadTask?.cancel()
        loadTask = nil
        currentGenmojiAssetID = nil

        if let cached = Self.imageCache.object(forKey: cacheKey as NSString) {
            imageView.image = cached
            return
        }

        switch presentation {
        case .agent(.genmoji(let assetId, _)):
            imageView.image = AgentIconRenderer.render(value: .defaultValue, size: 36)
            guard let iconAssetCache else { return }
            currentGenmojiAssetID = assetId
            loadTask = Task { @MainActor [weak self, iconAssetCache] in
                guard let image = try? await iconAssetCache.image(assetId: assetId, size: 36),
                      !Task.isCancelled,
                      let self,
                      self.lastCacheKey == cacheKey,
                      self.currentGenmojiAssetID == assetId else {
                    return
                }
                Self.imageCache.setObject(image, forKey: cacheKey as NSString)
                self.imageView.image = image
                self.loadTask = nil
            }

        case .agent:
            let image = AgentIconRenderer.render(value: agentIcon, size: 36)
            Self.imageCache.setObject(image, forKey: cacheKey as NSString)
            imageView.image = image

        case .globalAvatar:
            let image = PiAvatarRenderer.render(size: 36)
            Self.imageCache.setObject(image, forKey: cacheKey as NSString)
            imageView.image = image
        }
    }
}
