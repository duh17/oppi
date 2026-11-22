import Accessibility
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A saved workspace or Agent icon on its tile (`EntityIcon`): an SF Symbol in
/// the theme blue, an emoji, a Genmoji, or an imported image the server stores,
/// a sandbox workspace's lock mark, the Pi mark, and plain symbols for the
/// other pills. `EntityIcon` owns the pixels; this view places them in its
/// frame, which the tile fills, and redraws when artwork lands.
///
/// An animated WebP loops and a symbol's effect plays on the icon's own page
/// (the Agent's, which shows it in a circle, and a workspace's form), in the
/// icon picker, and in an Agent's row in the Agents list; everywhere else the
/// first frame draws still. WebP is the only animated image format, so a PNG and
/// a stored GIF draw still. A playing view stops when it leaves its
/// window and whenever `MotionPolicy` takes the loops away (Motion set to
/// Moments only or Off, Reduce Motion, Low Power Mode, or the system's Auto-Play
/// Animated Images), with a sandbox workspace's lock mark kept over it. A view
/// that never animates can still play one short `playBurst()` at a moment — a
/// session row's icon when its session needs the person, a chat's title icon and
/// empty hero when it opens — and rests on its still drawing after it. Only the
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

    private let frameSize: CGFloat
    /// Whether this view plays its icon; a row shared by the owner's page and
    /// plain lists sets it per configuration.
    var animates: Bool {
        didSet {
            guard animates != oldValue else { return }
            if animates {
                observeMotionPolicy()
                startPlayingIfAllowed()
            } else {
                stopPlaying()
                render()
            }
        }
    }
    /// The shape the icon draws in: its tile, or the circle its own page shows.
    let shape: IconShape

    private let imageView = UIImageView()
    /// Over the tile while something plays: an animated image's frames, clipped
    /// to the tile, or a symbol running its effect.
    private let liveView = UIImageView()
    /// A sandbox workspace's lock mark, over `liveView` while it plays.
    private let markView = UIImageView()
    private var content: Content?
    private var observesMotionPolicy = false
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
    /// The pending end of a `playBurst()`; nil when nothing bursts.
    private var burst: Task<Void, Never>?

    init(frameSize: CGFloat, animates: Bool = false, shape: IconShape = .tile) {
        self.frameSize = frameSize
        self.animates = animates
        self.shape = shape
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .center
        liveView.isHidden = true
        liveView.clipsToBounds = true
        liveView.layer.cornerRadius = EntityIcon.cornerRadius(frameSize, shape: shape)
        liveView.layer.cornerCurve = .continuous
        markView.isHidden = true
        for view in [imageView, liveView, markView] {
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
        if animates { observeMotionPolicy() }
    }

    /// Any change that may still these icons stops them on their still drawing;
    /// one that allows them again plays them. A view installs these the first
    /// time it animates or bursts, so a list of still icons observes nothing.
    private func observeMotionPolicy() {
        guard !observesMotionPolicy else { return }
        observesMotionPolicy = true
        observers += MotionPolicy.observe { [weak self] in self?.motionPolicyChanged() }
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
        if window == nil {
            // Playing stops with the window, a burst included.
            guard animates || burst != nil else { return }
            stopPlaying()
            render()
        } else if animates {
            startPlayingIfAllowed()
        }
    }

    private func render() {
        // A playing icon's tile and live view are already up.
        guard let content, !isPlaying else { return }
        switch content {
        case .piAvatar:
            imageView.image = EntityIcon.image(.pi, size: frameSize, shape: shape)
        case .symbol(let name, let color, let style, let weight):
            imageView.image = UIImage.scaledSymbol(name, style: style, weight: weight, color: color)
        case .worktree(let color, let style):
            imageView.image = WorktreeGlyph.image(textStyle: style)?.withTintColor(color, renderingMode: .alwaysOriginal)
        case .importedImage(let data):
            let decoded = try? IconAssetCache.decodeRemoteIcon(
                data: data,
                size: min(512, frameSize * max(2, traitCollection.displayScale))
            ).image
            imageView.image = decoded.map { EntityIcon.tile(side: frameSize, filledWith: $0, shape: shape) }
        case .choice(let choice, let purpose, let sandbox):
            let entity: IconEntity = switch purpose {
            case .agent: .agent(choice)
            case .workspace: .workspace(choice, sandbox: sandbox)
            }
            imageView.image = EntityIcon.image(entity, size: frameSize, assets: assetCache, shape: shape)
        }
        startPlayingIfAllowed()
    }

    // MARK: - Animation

    /// How long a burst plays: about two loops of a typical animated icon, and
    /// longer than one run of a symbol's effect.
    static let burstDuration: Duration = .milliseconds(2_400)

    /// A settings or system change may stop or allow the loops and a running
    /// burst; ask `MotionPolicy` again rather than keeping its own copy.
    private func motionPolicyChanged() {
        guard animates || burst != nil else { return }
        if animates {
            if MotionPolicy.playsLoops {
                startPlayingIfAllowed()
            } else {
                stopPlaying()
                render()
            }
        } else if !MotionPolicy.playsMoments {
            stopPlaying()
            render()
        }
    }

    // MARK: - Burst

    /// Plays the icon briefly and then rests on its still drawing: an animated
    /// image's frames for `burstDuration`, or a symbol's effect once. A session
    /// row plays one when its session starts needing the person, and a chat's
    /// title icon and empty hero when the chat opens; `MotionPolicy` allows a
    /// moment in Moments only and Full, and never in Off. A view that already
    /// animates ignores it.
    func playBurst() {
        guard !animates, !isKnownStill, window != nil, MotionPolicy.playsMoments else { return }
        // A burst replaces whatever the view showed, so a reused row never
        // keeps the previous session's burst.
        stopPlaying()
        observeMotionPolicy()
        if let symbolEffect {
            playSymbol(symbolEffect.name, effect: symbolEffect.effect, repeats: false)
        } else if let imageBytes {
            playImage(imageBytes)
        } else {
            return
        }
        burst = Task { [weak self] in
            try? await Task.sleep(for: Self.burstDuration)
            guard !Task.isCancelled else { return }
            self?.endBurst()
        }
    }

    /// Stops a playing burst and returns to the still drawing, for a row whose
    /// session stops needing the person.
    func stopBurst() {
        guard burst != nil else { return }
        stopPlaying()
        render()
    }

    private func endBurst() {
        burst = nil
        stopPlaying()
        render()
    }

    /// Where the content's image bytes come from, when it is an image icon.
    private var imageBytes: (() async throws -> Data)? {
        switch content {
        case .choice(.image(let assetId)?, _, _):
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
        guard case .choice(.symbol(let name, let effect?)?, _, _) = content,
              UIImage(systemName: name) != nil else { return nil }
        return (name, effect)
    }

    private func startPlayingIfAllowed() {
        guard animates, !isPlaying, !isKnownStill, window != nil, MotionPolicy.playsLoops else { return }
        if let symbolEffect {
            playSymbol(symbolEffect.name, effect: symbolEffect.effect, repeats: true)
        } else if let imageBytes {
            playImage(imageBytes)
        }
    }

    /// The symbol over an empty tile, running its effect: as an idle loop, or
    /// once for a burst.
    private func playSymbol(_ name: String, effect: IconSymbolEffect, repeats: Bool) {
        guard let symbol = EntityIcon.tileSymbol(name, side: frameSize) else { return }
        isPlaying = true
        imageView.image = EntityIcon.tile(side: frameSize, shape: shape)
        liveView.contentMode = .center
        liveView.image = symbol
        liveView.isHidden = false
        showSandboxMarkIfNeeded()
        let periodically: SymbolEffectOptions = repeats ? .repeat(.periodic(delay: 1.2)) : .default
        let continuously: SymbolEffectOptions = repeats ? .repeat(.continuous) : .default
        switch effect {
        case .bounce:
            liveView.addSymbolEffect(.bounce, options: periodically)
        case .wiggle:
            liveView.addSymbolEffect(.wiggle, options: periodically)
        case .pulse:
            liveView.addSymbolEffect(.pulse, options: continuously)
        case .breathe:
            liveView.addSymbolEffect(.breathe, options: continuously)
        case .rotate:
            liveView.addSymbolEffect(.rotate, options: continuously)
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
            imageView.image = EntityIcon.tile(side: frameSize, shape: shape)
            playback.start(data: data, imageView: liveView, maxPixelSize: frameSize * traitCollection.displayScale)
            // Frames fill the tile edge to edge, like the still drawing.
            liveView.contentMode = .scaleAspectFill
            liveView.isHidden = false
            showSandboxMarkIfNeeded()
        }
    }

    /// A sandbox workspace keeps its lock mark over what plays.
    private func showSandboxMarkIfNeeded() {
        guard case .choice(_, .workspace, true) = content else { return }
        markView.image = EntityIcon.sandboxMark(frame: frameSize)
        markView.isHidden = false
    }

    private func stopPlaying() {
        burst?.cancel()
        burst = nil
        playGeneration += 1
        playback.stop()
        liveView.removeAllSymbolEffects()
        liveView.image = nil
        liveView.isHidden = true
        markView.image = nil
        markView.isHidden = true
        isPlaying = false
    }

    /// Whether `data` plays: an animated WebP. A PNG (an APNG included) and a GIF
    /// stored before WebP became the animated icon draw their first frame.
    private static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1,
              let identifier = CGImageSourceGetType(source),
              UTType(identifier as String)?.conforms(to: .webP) == true else { return false }
        return true
    }
}
