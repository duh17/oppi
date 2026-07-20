import UIKit

/// Shared image renderer for assistant avatars.
@MainActor
enum AssistantAvatarRenderer {
    static func render(
        avatar: AssistantAvatar,
        sessionId: String,
        size: CGFloat,
        themeID: ThemeID? = nil
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
        case .genmoji(let data):
            if #available(iOS 18.0, *),
               let genmojiImage = renderGenmoji(data: data, size: size) {
                return genmojiImage
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

    @available(iOS 18.0, *)
    private static func renderGenmoji(data: Data, size: CGFloat) -> UIImage? {
        let glyph = NSAdaptiveImageGlyph(imageContent: data)

        // Render via UITextView which has native Genmoji support
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        let attrStr = NSMutableAttributedString(string: "\u{FFFC}")
        attrStr.addAttribute(
            .adaptiveImageGlyph,
            value: glyph,
            range: NSRange(location: 0, length: 1)
        )
        attrStr.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: size * 0.8),
            range: NSRange(location: 0, length: 1)
        )
        textView.attributedText = attrStr
        textView.sizeToFit()

        let renderSize = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        return renderer.image { ctx in
            let viewSize = textView.bounds.size
            guard viewSize.width > 0, viewSize.height > 0 else { return }
            let scale = min(size / viewSize.width, size / viewSize.height)
            let scaledW = viewSize.width * scale
            let scaledH = viewSize.height * scale
            ctx.cgContext.translateBy(x: (size - scaledW) / 2, y: (size - scaledH) / 2)
            ctx.cgContext.scaleBy(x: scale, y: scale)
            textView.layer.render(in: ctx.cgContext)
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
/// - `.genmoji` → NSAdaptiveImageGlyph image
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

    var agentIcon: String? {
        didSet { updateIfNeeded() }
    }

    private var lastCacheKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
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
            selector: #selector(avatarOrThemeDidChange(_:)),
            name: .assistantAvatarDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(avatarOrThemeDidChange(_:)),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 18, height: 18)
    }

    @objc private func avatarOrThemeDidChange(_ notification: Notification) {
        Self.imageCache.removeAllObjects()
        lastCacheKey = nil
        updateIfNeeded()
    }

    private func updateIfNeeded() {
        let avatar = AssistantAvatar.current
        let themeId = ThemeRuntimeState.currentThemeID()
        let presentation = AssistantIdentityPresentation.resolve(
            agentId: agentId,
            agentIcon: agentIcon
        )
        let identity = switch presentation {
        case .agent(let content):
            "agent:\(content)"
        case .globalAvatar:
            "assistant:\(avatar.cacheIdentifier)"
        }
        let cacheKey = "\(sessionId):\(themeId):\(identity)"
        guard cacheKey != lastCacheKey else { return }
        lastCacheKey = cacheKey

        if let cached = Self.imageCache.object(forKey: cacheKey as NSString) {
            imageView.image = cached
            return
        }

        let image = switch presentation {
        case .agent:
            AgentIconRenderer.render(value: agentIcon, size: 36)
        case .globalAvatar:
            AssistantAvatarRenderer.render(avatar: avatar, sessionId: sessionId, size: 36)
        }
        Self.imageCache.setObject(image, forKey: cacheKey as NSString)
        imageView.image = image
    }
}
