import UIKit

/// A saved workspace or Agent icon: an SF Symbol in the theme blue, an emoji, or
/// a Genmoji the server stores, a sandbox workspace's lock mark, the Pi mark, and
/// plain symbols for the other pills. `EntityIcon` owns the pixels and their
/// fallbacks; this view places them in its frame and redraws when artwork lands.
/// Quick Session's pills and pickers, the chat title, the empty chat, and the
/// workspace sidebar's rows draw their icons with it.
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

    /// The size the icon's content takes in its frame, following Dynamic Type.
    private var contentSize: CGFloat {
        AgentIconSizingPolicy.contentSize(
            baseSize: size,
            scaledSize: UIFontMetrics(forTextStyle: .body).scaledValue(for: size),
            frameSize: frameSize
        )
    }

    /// `colors` is the presenter's theme and no longer changes an icon's pixels:
    /// `EntityIcon` draws with the theme the app is on, like every other icon.
    func apply(_ content: Content, colors: ComposerThemeColors, assetCache: IconAssetCache? = nil) {
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
            // A sandbox workspace's mark sits in the frame's corner, so that icon
            // is drawn in the whole frame; the others are centered content.
            imageView.image = EntityIcon.image(
                entity,
                size: sandbox ? frameSize : contentSize,
                assets: assetCache
            )
        }
    }
}
