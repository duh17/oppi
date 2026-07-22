import UIKit

/// Shared image renderer for assistant avatars.
@MainActor
enum AssistantAvatarRenderer {
    static func render(
        avatar: AssistantAvatar,
        sessionId: String,
        size: CGFloat,
        themeID: ThemeID? = nil,
        cachedImage: UIImage? = nil
    ) -> UIImage {
        switch avatar {
        case .officialPi:
            return renderOfficialPi(size: size, themeID: themeID ?? ThemeRuntimeState.currentThemeID())
        case .golGrid:
            return renderGrid(sessionId: sessionId, size: size)
        case .piText:
            return renderText("π", size: size)
        case .emoji(let char):
            return renderEmoji(char, size: size)
        case .genmoji(let data, _):
            // Mounted rows receive the persisted snapshot's validated raster.
            // Draft renderers omit it and keep their bytes on this failable boundary.
            if let cachedImage {
                return cachedImage
            }
            let decodeSize = min(512, max(1, size))
            if let decoded = try? IconAssetCache.decodeRemoteHEIF(data: data, size: decodeSize) {
                return decoded.image
            }
            return renderText("π", size: size)
        }
    }

    private static func renderOfficialPi(size: CGFloat, themeID: ThemeID) -> UIImage {
        let palette = themeID.palette
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let canvasScale = size / 800
            context.cgContext.scaleBy(x: canvasScale, y: canvasScale)
            UIColor(palette.fg).setFill()

            // Official mark geometry from https://pi.dev/logo-auto.svg.
            let pMark = UIBezierPath()
            pMark.move(to: CGPoint(x: 165.29, y: 165.29))
            pMark.addLine(to: CGPoint(x: 517.36, y: 165.29))
            pMark.addLine(to: CGPoint(x: 517.36, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 517.36))
            pMark.addLine(to: CGPoint(x: 282.65, y: 517.36))
            pMark.addLine(to: CGPoint(x: 282.65, y: 634.72))
            pMark.addLine(to: CGPoint(x: 165.29, y: 634.72))
            pMark.close()
            pMark.move(to: CGPoint(x: 282.65, y: 282.65))
            pMark.addLine(to: CGPoint(x: 282.65, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 400))
            pMark.addLine(to: CGPoint(x: 400, y: 282.65))
            pMark.close()
            pMark.usesEvenOddFillRule = true
            pMark.fill()

            UIBezierPath(rect: CGRect(x: 517.36, y: 400, width: 117.36, height: 234.72)).fill()
        }
    }

    private static func renderGrid(sessionId: String, size: CGFloat) -> UIImage {
        let palette = ThemeRuntimeState.currentPalette()
        let fgColor = UIColor(palette.fg)
        let sparkColor = UIColor(palette.orange)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            let grid = 8
            let cellTotal = size / CGFloat(grid)
            let gap = cellTotal * 0.10
            let cellSize = cellTotal - gap
            let cornerRadius = cellSize * 0.24

            let cells = SessionGridRenderer.generateCells(sessionId: sessionId)

            for cell in cells {
                let x = CGFloat(cell.col) * cellTotal + gap / 2
                let y = CGFloat(cell.row) * cellTotal + gap / 2
                let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)

                let color: UIColor
                switch cell.role {
                case .spark:
                    color = sparkColor.withAlphaComponent(0.90)
                case .almostSpark:
                    color = sparkColor.withAlphaComponent(0.30)
                default:
                    color = fgColor.withAlphaComponent(CGFloat(cell.opacity))
                }

                cgCtx.setFillColor(color.cgColor)
                cgCtx.addPath(path.cgPath)
                cgCtx.fillPath()
            }
        }
    }

    private static func renderText(_ text: String, size: CGFloat) -> UIImage {
        let palette = ThemeRuntimeState.currentPalette()
        let font = UIFont.monospacedSystemFont(ofSize: size * 0.55, weight: .semibold)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(palette.purple),
            ]
            let nsText = text as NSString
            let textSize = nsText.size(withAttributes: attrs)
            let x = (size - textSize.width) / 2
            let y = (size - textSize.height) / 2
            nsText.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        }
    }

    private static func renderEmoji(_ emoji: String, size: CGFloat) -> UIImage {
        let font = UIFont.systemFont(ofSize: size * 0.7)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let nsText = emoji as NSString
            let textSize = nsText.size(withAttributes: attrs)
            let x = (size - textSize.width) / 2
            let y = (size - textSize.height) / 2
            nsText.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        }
    }

}

/// Renders the assistant avatar as a cached `UIImage` in a `UIImageView`.
///
/// Supports all `AssistantAvatar` types:
/// - `.officialPi` → official Pi logo mark
/// - `.piText` → rendered π character
/// - `.golGrid` → Game of Life grid, unique per session
/// - `.emoji` → rendered emoji character
/// - `.genmoji` → bounded ImageIO/CGImage raster fallback
///
/// One render per (sessionId, avatar, theme) combo, then pure UIImageView.
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

    /// Injectable only at this rendering boundary so focused tests can prove
    /// Agent rows never consult the device-local assistant avatar.
    var assistantAvatarProvider: @MainActor () -> AssistantAvatarSnapshot = { AssistantAvatar.currentSnapshot }

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
            selector: #selector(assistantAvatarDidChange(_:)),
            name: .assistantAvatarDidChange,
            object: nil
        )
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

    override var intrinsicContentSize: CGSize {
        CGSize(width: 18, height: 18)
    }

    @objc private func assistantAvatarDidChange(_ notification: Notification) {
        // A saved-Agent row is entirely defined by its launch snapshot. Do not
        // invalidate its Agent image, start another asset fetch, or consult the
        // device-local assistant avatar when that preference changes.
        guard agentId?.isEmpty != false else { return }

        // Global rows refresh through their lightweight persisted snapshot
        // identity. Keep Agent entries in the shared cache intact.
        lastCacheKey = nil
        updateIfNeeded()
    }

    @objc private func themeDidChange(_ notification: Notification) {
        // Rendered assistant and Agent icons can use theme colors, so a theme
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
        let avatar: AssistantAvatar?
        let cachedAvatarImage: UIImage?
        let identity: String
        switch presentation {
        case .globalAvatar:
            let snapshot = assistantAvatarProvider()
            let globalAvatar = snapshot.avatar
            avatar = globalAvatar
            cachedAvatarImage = snapshot.image
            accessibilityLabel = globalAvatar.accessibilityDescription
            identity = "assistant:\(snapshot.cacheIdentifier)"
        case .agent(let content):
            // Saved-Agent rows are entirely determined by their launch snapshot.
            // Do not load or decode the global device-local assistant avatar.
            avatar = nil
            cachedAvatarImage = nil
            accessibilityLabel = "Saved Agent, \(content.accessibilityDescription)"
            identity = "agent:\(content)"
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
            guard let avatar else { return }
            let image = AssistantAvatarRenderer.render(
                avatar: avatar,
                sessionId: sessionId,
                size: 36,
                cachedImage: cachedAvatarImage
            )
            Self.imageCache.setObject(image, forKey: cacheKey as NSString)
            imageView.image = image
        }
    }
}
