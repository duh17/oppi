import UIKit

/// A saved workspace or Agent icon (`IconChoiceView` in UIKit): an SF Symbol in
/// the theme blue, an emoji, or a Genmoji the server stores, which loads
/// through the server's icon cache and shows the default symbol until it
/// arrives. A sandbox workspace adds the lock mark (`WorkspaceRuntimeIcon`).
/// Also the Pi mark, and plain symbols for the other pills. Quick Session's
/// pills and pickers, the chat title, and the empty chat draw their icons
/// with it.
@MainActor
final class IconChoiceUIView: UIView {
    enum Content: Equatable {
        case choice(IconChoice?, purpose: Purpose, sandbox: Bool)
        case piAvatar
        case symbol(String, color: UIColor, style: UIFont.TextStyle, weight: UIFont.Weight)

        enum Purpose: Equatable {
            case agent
            case workspace

            var defaultSymbolName: String {
                switch self {
                case .agent: "person.crop.circle"
                case .workspace: "square.grid.2x2"
                }
            }
        }
    }

    private let size: CGFloat
    private let frameSize: CGFloat
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private let sandboxMark = UIImageView()
    private var content: Content?
    private var colors = ComposerThemeColors.placeholder
    private weak var assetCache: IconAssetCache?
    private var loadTask: Task<Void, Never>?
    private var loadedAssetId: String?

    init(size: CGFloat, frameSize: CGFloat) {
        self.size = size
        self.frameSize = frameSize
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .center
        textLabel.textAlignment = .center
        sandboxMark.contentMode = .center
        for view in [imageView, textLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        let markSize = max(11, frameSize * 0.34)
        sandboxMark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sandboxMark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: frameSize),
            heightAnchor.constraint(equalToConstant: frameSize),
            sandboxMark.widthAnchor.constraint(equalToConstant: markSize),
            sandboxMark.heightAnchor.constraint(equalToConstant: markSize),
            sandboxMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: frameSize * 0.05),
            sandboxMark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: frameSize * 0.05),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The size the icon's content takes in its frame, following Dynamic Type
    /// the way `IconChoiceView` does.
    private var contentSize: CGFloat {
        AgentIconSizingPolicy.contentSize(
            baseSize: size,
            scaledSize: UIFontMetrics(forTextStyle: .body).scaledValue(for: size),
            frameSize: frameSize
        )
    }

    func apply(_ content: Content, colors: ComposerThemeColors, assetCache: IconAssetCache? = nil) {
        let changed = content != self.content || assetCache !== self.assetCache
        self.content = content
        self.colors = colors
        self.assetCache = assetCache
        render()
        if changed { loadGenmojiIfNeeded() }
    }

    private func render() {
        guard let content else { return }
        textLabel.isHidden = true
        imageView.isHidden = false
        imageView.contentMode = .center
        sandboxMark.isHidden = true
        switch content {
        case .piAvatar:
            imageView.contentMode = .scaleAspectFit
            imageView.image = PiAvatarRenderer.render(size: frameSize * 2)
        case .symbol(let name, let color, let style, let weight):
            imageView.image = UIImage.scaledSymbol(name, style: style, weight: weight, color: color)
        case .choice(let choice, let purpose, let sandbox):
            sandboxMark.isHidden = !sandbox
            if sandbox { sandboxMark.image = sandboxImage() }
            switch AgentIconContent.resolve(choice) {
            case .symbol(let name):
                imageView.image = symbol(name)
            case .text(let emoji):
                imageView.isHidden = true
                textLabel.isHidden = false
                textLabel.text = emoji
                textLabel.font = .systemFont(ofSize: contentSize)
            case .genmoji(let assetId, _):
                if loadedAssetId == assetId, let image = imageView.image, image.isSymbolImage == false {
                    imageView.contentMode = .scaleAspectFit
                } else {
                    imageView.image = symbol(purpose.defaultSymbolName)
                }
            case .fallback:
                imageView.image = symbol(purpose.defaultSymbolName)
            }
        }
    }

    private func symbol(_ name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: contentSize)
        )?.withTintColor(colors.blue, renderingMode: .alwaysOriginal)
    }

    private func loadGenmojiIfNeeded() {
        loadTask?.cancel()
        loadTask = nil
        guard case .choice(let choice, _, _) = content,
              case .genmoji(let assetId, _) = AgentIconContent.resolve(choice),
              let assetCache else {
            loadedAssetId = nil
            return
        }
        guard loadedAssetId != assetId else { return }
        loadedAssetId = nil
        let renderSize = contentSize * 2
        loadTask = Task { [weak self] in
            guard let image = try? await assetCache.image(assetId: assetId, size: renderSize),
                  !Task.isCancelled, let self else { return }
            self.loadedAssetId = assetId
            self.imageView.contentMode = .scaleAspectFit
            self.imageView.image = image
        }
    }

    private func sandboxImage() -> UIImage {
        let markSize = max(11, frameSize * 0.34)
        let colors = colors
        return UIGraphicsImageRenderer(size: CGSize(width: markSize, height: markSize)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: markSize, height: markSize)
            colors.orange.setFill()
            UIBezierPath(ovalIn: rect).fill()
            colors.bg.setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            let lock = UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: markSize * 0.52, weight: .bold)
            )?.withTintColor(colors.bg, renderingMode: .alwaysOriginal)
            let lockSize = lock?.size ?? .zero
            lock?.draw(at: CGPoint(x: (markSize - lockSize.width) / 2, y: (markSize - lockSize.height) / 2))
        }
    }
}
