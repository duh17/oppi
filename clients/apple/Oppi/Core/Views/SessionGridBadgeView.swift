import UIKit

/// Shared image renderer for assistant avatars.
enum AssistantAvatarRenderer {
    static func render(avatar: AssistantAvatar, sessionId: String, size: CGFloat) -> UIImage {
        switch avatar {
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
        guard let glyph = try? NSAdaptiveImageGlyph(imageContent: data) else { return nil }

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 18, height: 18)
    }

    /// Call when avatar preference changes to flush stale cached images.
    static func clearCache() {
        imageCache.removeAllObjects()
    }

    private func updateIfNeeded() {
        let avatar = AssistantAvatar.current
        let themeId = ThemeRuntimeState.currentThemeID()
        let cacheKey = "\(sessionId):\(themeId):\(avatar.cacheIdentifier)"
        guard cacheKey != lastCacheKey else { return }
        lastCacheKey = cacheKey

        if let cached = Self.imageCache.object(forKey: cacheKey as NSString) {
            imageView.image = cached
            return
        }

        let image = AssistantAvatarRenderer.render(avatar: avatar, sessionId: sessionId, size: 36)
        Self.imageCache.setObject(image, forKey: cacheKey as NSString)
        imageView.image = image
    }
}
