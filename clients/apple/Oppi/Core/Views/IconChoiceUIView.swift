import UIKit

/// A saved workspace or Agent icon: an SF Symbol in the theme blue, an emoji, or
/// a Genmoji the server stores, a sandbox workspace's lock mark, the Pi mark, and
/// plain symbols for the other pills. `EntityIcon` owns the pixels; this view
/// places them in its frame and redraws when artwork lands.
@MainActor
final class IconChoiceUIView: UIView {
    enum Content: Equatable {
        case choice(IconChoice?, purpose: Purpose, sandbox: Bool)
        case piAvatar
        case symbol(String, color: UIColor, style: UIFont.TextStyle, weight: UIFont.Weight)

        enum Purpose: Equatable {
            case agent
            case workspace
        }
    }

    private let size: CGFloat
    private let frameSize: CGFloat
    private let imageView = UIImageView()
    private var content: Content?
    private weak var assetCache: IconAssetCache?
    private var iconLoadObserver: NSObjectProtocol?

    init(size: CGFloat, frameSize: CGFloat) {
        self.size = size
        self.frameSize = frameSize
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: frameSize),
            heightAnchor.constraint(equalToConstant: frameSize),
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
            MainActor.assumeIsolated { self?.render() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let iconLoadObserver {
            NotificationCenter.default.removeObserver(iconLoadObserver)
        }
    }

    /// The glyph size the icon takes in its frame, following Dynamic Type.
    private var glyphSize: CGFloat {
        AgentIconSizingPolicy.contentSize(
            baseSize: size,
            scaledSize: UIFontMetrics(forTextStyle: .body).scaledValue(for: size),
            frameSize: frameSize
        )
    }

    func apply(_ content: Content, assetCache: IconAssetCache? = nil) {
        self.content = content
        self.assetCache = assetCache
        render()
    }

    private func render() {
        guard let content else { return }
        imageView.contentMode = .center
        switch content {
        case .piAvatar:
            imageView.image = EntityIcon.image(.pi, size: frameSize)
        case .symbol(let name, let color, let style, let weight):
            imageView.image = UIImage.scaledSymbol(name, style: style, weight: weight, color: color)
        case .choice(let choice, let purpose, let sandbox):
            let entity: IconEntity = switch purpose {
            case .agent: .agent(choice)
            case .workspace: .workspace(choice, sandbox: sandbox)
            }
            // Artwork and the sandbox mark fill the frame; a symbol or an emoji
            // takes its glyph size, as it always has in a pill or a title.
            let fillsFrame = sandbox || isArtwork(choice)
            imageView.image = EntityIcon.image(
                entity,
                size: fillsFrame ? frameSize : EntityIcon.box(forGlyph: glyphSize),
                assets: assetCache
            )
        }
    }

    private func isArtwork(_ choice: IconChoice?) -> Bool {
        if case .genmoji = AgentIconContent.resolve(choice) { return true }
        return false
    }
}
