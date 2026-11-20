import Accessibility
import ImageIO
import UIKit

/// A saved workspace or Agent icon: an SF Symbol in the theme blue, an emoji, a
/// Genmoji or an imported image the server stores, a sandbox workspace's lock
/// mark, the Pi mark, and plain symbols for the other pills. `EntityIcon` owns
/// the pixels; this view places them in its frame and redraws when artwork lands.
///
/// An animated image shows its first frame, like everywhere else in the app,
/// unless the view is made with `animatesImage` (the Agent detail screen and the
/// icon picker): then it plays while the view is in a window and Reduce Motion,
/// Low Power Mode, and the system's Auto-Play Animated Images allow it. Only the
/// chat timeline animates anything else.
@MainActor
final class IconChoiceUIView: UIView {
    enum Content: Equatable {
        case choice(IconChoice?, purpose: Purpose, sandbox: Bool)
        case piAvatar
        case symbol(String, color: UIColor, style: UIFont.TextStyle, weight: UIFont.Weight)
        /// The worktree mark (`WorktreeGlyph`).
        case worktree(color: UIColor, style: UIFont.TextStyle)
        /// An image the person just imported in the icon picker, before Save
        /// uploads it: drawn and played like a stored `.image` icon.
        case importedImage(Data)

        enum Purpose: Equatable {
            case agent
            case workspace
        }
    }

    private let size: CGFloat
    private let frameSize: CGFloat
    private let animatesImage: Bool
    private let imageView = UIImageView()
    private var content: Content?
    private weak var assetCache: IconAssetCache?
    private var observers: [NSObjectProtocol] = []
    private let playback = InlineAnimatedRasterPlayback()
    /// True while an animation's frames own the image view.
    private var isPlaying = false
    /// The content's image turned out still (one frame) or could not load, so it
    /// stays drawn until the content changes.
    private var isKnownStill = false
    /// Bumped by every stop, so a fetch that lands after one starts nothing.
    private var playGeneration = 0

    init(size: CGFloat, frameSize: CGFloat, animatesImage: Bool = false) {
        self.size = size
        self.frameSize = frameSize
        self.animatesImage = animatesImage
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
        observe(.oppiEntityIconDidLoad) { $0.render() }
        if animatesImage {
            // Any of these turning off stops the image on its first frame;
            // turning back on plays it again.
            observe(UIAccessibility.reduceMotionStatusDidChangeNotification) { $0.motionPolicyChanged() }
            observe(.NSProcessInfoPowerStateDidChange) { $0.motionPolicyChanged() }
            observe(AccessibilitySettings.animatedImagesEnabledDidChangeNotification) { $0.motionPolicyChanged() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        playback.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (IconChoiceUIView) -> Void) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        })
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
        if self.content != content || self.assetCache !== assetCache {
            stopPlaying()
            isKnownStill = false
        }
        self.content = content
        self.assetCache = assetCache
        render()
    }

    /// Draws nothing and stops a playing image, for a reused view that hides it.
    func clear() {
        stopPlaying()
        content = nil
        isKnownStill = false
        imageView.image = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard animatesImage else { return }
        if window == nil {
            stopPlaying()
            render()
        } else {
            startPlayingIfAllowed()
        }
    }

    private func render() {
        // A playing image's frames own the image view.
        guard let content, !isPlaying else { return }
        imageView.contentMode = .center
        switch content {
        case .piAvatar:
            imageView.image = EntityIcon.image(.pi, size: frameSize)
        case .symbol(let name, let color, let style, let weight):
            imageView.image = UIImage.scaledSymbol(name, style: style, weight: weight, color: color)
        case .worktree(let color, let style):
            imageView.image = WorktreeGlyph.image(textStyle: style)?.withTintColor(color, renderingMode: .alwaysOriginal)
        case .importedImage(let data):
            imageView.contentMode = .scaleAspectFit
            imageView.image = try? IconAssetCache.decodeRemoteIcon(
                data: data,
                size: min(512, frameSize * max(2, traitCollection.displayScale))
            ).image
        case .choice(let choice, let purpose, let sandbox):
            let entity: IconEntity = switch purpose {
            case .agent: .agent(choice)
            case .workspace: .workspace(choice, sandbox: sandbox)
            }
            // Artwork and the sandbox mark fill the frame; a symbol or an emoji
            // takes its glyph size, as it always has in a pill or a title.
            let contentBox = isArtwork(choice) ? frameSize : EntityIcon.box(forGlyph: glyphSize)
            imageView.image = EntityIcon.image(
                entity,
                size: sandbox ? frameSize : contentBox,
                contentSize: sandbox ? contentBox : nil,
                assets: assetCache
            )
        }
        startPlayingIfAllowed()
    }

    private func isArtwork(_ choice: IconChoice?) -> Bool {
        switch AgentIconContent.resolve(choice) {
        case .genmoji, .image: true
        case .symbol, .text, .fallback: false
        }
    }

    // MARK: - Animated images

    /// Whether an animated image may play right now, wherever it is allowed at all.
    private static var motionAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && AccessibilitySettings.animatedImagesEnabled
    }

    private func motionPolicyChanged() {
        if Self.motionAllowed {
            startPlayingIfAllowed()
        } else {
            stopPlaying()
            render()
        }
    }

    /// Where the content's image bytes come from, when it is an image icon.
    private var imageBytes: (() async throws -> Data)? {
        switch content {
        case .choice(.image(let assetId)?, _, false):
            guard let assetCache else { return nil }
            return { try await assetCache.data(assetId: assetId) }
        case .importedImage(let data):
            return { data }
        default:
            return nil
        }
    }

    /// Gets the image's bytes (a stored one from the cache) and plays them when
    /// they hold more than one frame. A still image keeps its drawn frame.
    private func startPlayingIfAllowed() {
        guard animatesImage, !isPlaying, !isKnownStill, window != nil, Self.motionAllowed,
              let imageBytes else { return }
        isPlaying = true
        let generation = playGeneration
        Task { [weak self] in
            let data = try? await imageBytes()
            guard let self, playGeneration == generation else { return }
            guard let data, Self.isAnimated(data) else {
                isKnownStill = true
                isPlaying = false
                render()
                return
            }
            playback.start(data: data, imageView: imageView, maxPixelSize: frameSize * traitCollection.displayScale)
        }
    }

    private func stopPlaying() {
        playGeneration += 1
        playback.stop()
        isPlaying = false
    }

    private static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }
}
