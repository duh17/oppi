import Accessibility
import ImageIO
import UIKit

/// A saved workspace or Agent icon on its tile (`EntityIcon`): an SF Symbol in
/// the theme blue, an emoji, a Genmoji, or an imported image the server stores,
/// a sandbox workspace's lock mark, the Pi mark, and plain symbols for the
/// other pills. `EntityIcon` owns the pixels; this view places them in its
/// frame, which the tile fills, and redraws when artwork lands.
///
/// An animated image shows its first frame and a symbol's effect does not play,
/// like everywhere else in the app, unless the view is made with `animates`
/// (the Agent detail screen and the icon picker): then they play while the view
/// is in a window and Reduce Motion, Low Power Mode, and the system's Auto-Play
/// Animated Images allow it. Only the chat timeline animates anything else.
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

    private let frameSize: CGFloat
    private let animates: Bool
    private let imageView = UIImageView()
    /// Over the tile while something plays: an animated image's frames, clipped
    /// to the tile, or a symbol running its effect.
    private let liveView = UIImageView()
    private var content: Content?
    private var themeID: ThemeID?
    private weak var assetCache: IconAssetCache?
    private var observers: [NSObjectProtocol] = []
    private let playback = InlineAnimatedRasterPlayback()
    /// True while an animation (image frames or a symbol effect) owns `liveView`.
    private var isPlaying = false
    /// The content's image turned out still (one frame) or could not load, so it
    /// stays drawn until the content changes.
    private var isKnownStill = false
    /// Bumped by every stop, so a fetch that lands after one starts nothing.
    private var playGeneration = 0

    init(frameSize: CGFloat, animates: Bool = false) {
        self.frameSize = frameSize
        self.animates = animates
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .center
        liveView.isHidden = true
        liveView.clipsToBounds = true
        liveView.layer.cornerRadius = EntityIcon.tileCornerRadius(frameSize)
        liveView.layer.cornerCurve = .continuous
        for view in [imageView, liveView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: frameSize),
            heightAnchor.constraint(equalToConstant: frameSize),
        ])
        observe(.oppiEntityIconDidLoad) { $0.render() }
        // The tile and the symbol tint are the theme's, so a switch repaints.
        observe(.oppiThemeDidChange) { view in
            guard let content = view.content else { return }
            view.apply(content, assetCache: view.assetCache)
        }
        if animates {
            // Any of these turning off stops the icon on its still drawing;
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

    func apply(_ content: Content, assetCache: IconAssetCache? = nil) {
        // A theme change repaints the tile and the playing symbol's tint, so it
        // restarts what plays like a new icon does.
        let themeID = ThemeRuntimeState.currentThemeID()
        if self.content != content || self.assetCache !== assetCache || self.themeID != themeID {
            stopPlaying()
            isKnownStill = false
        }
        self.content = content
        self.assetCache = assetCache
        self.themeID = themeID
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
        guard animates else { return }
        if window == nil {
            stopPlaying()
            render()
        } else {
            startPlayingIfAllowed()
        }
    }

    private func render() {
        // A playing icon's tile and live view are already up.
        guard let content, !isPlaying else { return }
        switch content {
        case .piAvatar:
            imageView.image = EntityIcon.image(.pi, size: frameSize)
        case .symbol(let name, let color, let style, let weight):
            imageView.image = UIImage.scaledSymbol(name, style: style, weight: weight, color: color)
        case .worktree(let color, let style):
            imageView.image = WorktreeGlyph.image(textStyle: style)?.withTintColor(color, renderingMode: .alwaysOriginal)
        case .importedImage(let data):
            let decoded = try? IconAssetCache.decodeRemoteIcon(
                data: data,
                size: min(512, frameSize * max(2, traitCollection.displayScale))
            ).image
            imageView.image = decoded.map { EntityIcon.tile(side: frameSize, filledWith: $0) }
        case .choice(let choice, let purpose, let sandbox):
            let entity: IconEntity = switch purpose {
            case .agent: .agent(choice)
            case .workspace: .workspace(choice, sandbox: sandbox)
            }
            imageView.image = EntityIcon.image(entity, size: frameSize, assets: assetCache)
        }
        startPlayingIfAllowed()
    }

    // MARK: - Animation

    /// Whether an icon may animate right now, wherever it is allowed at all.
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

    /// The symbol and the effect it plays, when the content is a symbol icon with one.
    private var symbolEffect: (name: String, effect: IconSymbolEffect)? {
        guard case .choice(.symbol(let name, let effect?)?, _, false) = content,
              UIImage(systemName: name) != nil else { return nil }
        return (name, effect)
    }

    private func startPlayingIfAllowed() {
        guard animates, !isPlaying, !isKnownStill, window != nil, Self.motionAllowed else { return }
        if let symbolEffect {
            playSymbol(symbolEffect.name, effect: symbolEffect.effect)
        } else if let imageBytes {
            playImage(imageBytes)
        }
    }

    /// The symbol over an empty tile, running its effect as an idle loop.
    private func playSymbol(_ name: String, effect: IconSymbolEffect) {
        guard let symbol = EntityIcon.tileSymbol(name, side: frameSize) else { return }
        isPlaying = true
        imageView.image = EntityIcon.tile(side: frameSize)
        liveView.contentMode = .center
        liveView.image = symbol
        liveView.isHidden = false
        switch effect {
        case .bounce:
            liveView.addSymbolEffect(.bounce, options: .repeat(.periodic(delay: 1.2)))
        case .wiggle:
            liveView.addSymbolEffect(.wiggle, options: .repeat(.periodic(delay: 1.2)))
        case .pulse:
            liveView.addSymbolEffect(.pulse, options: .repeat(.continuous))
        case .breathe:
            liveView.addSymbolEffect(.breathe, options: .repeat(.continuous))
        case .rotate:
            liveView.addSymbolEffect(.rotate, options: .repeat(.continuous))
        }
    }

    /// Gets the image's bytes (a stored one from the cache) and plays them over
    /// the tile when they hold more than one frame. A still image keeps its
    /// drawn frame.
    private func playImage(_ imageBytes: @escaping () async throws -> Data) {
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
            imageView.image = EntityIcon.tile(side: frameSize)
            playback.start(data: data, imageView: liveView, maxPixelSize: frameSize * traitCollection.displayScale)
            // Frames fill the tile edge to edge, like the still drawing.
            liveView.contentMode = .scaleAspectFill
            liveView.isHidden = false
        }
    }

    private func stopPlaying() {
        playGeneration += 1
        playback.stop()
        liveView.removeAllSymbolEffects()
        liveView.image = nil
        liveView.isHidden = true
        isPlaying = false
    }

    private static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }
}
