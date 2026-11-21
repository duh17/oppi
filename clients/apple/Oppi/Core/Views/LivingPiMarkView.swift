import QuartzCore
import UIKit

/// The sidebar's mark: the app icon's π drawn cell by cell straight on the
/// sidebar's background, with two elves moving its blocks around
/// (`LivingPiPlanner` decides the moves and keeps the π a π). Only the
/// blocks and the elves are drawn: no scenery, and a slot a block left is
/// plain background.
///
/// The app wakes once per job: it plans the job, hands each layer that moves
/// one keyframe group sampled at 20 fps (at 32 pt that reads the same as 30
/// and the system redraws less), and sleeps through the job and the 2–6 s
/// rest after it. Core Animation plays the motion; there is no
/// per-frame work in the app.
///
/// It runs only while it is in a window, shown, its scene is in the
/// foreground, Low Power Mode and Reduce Motion are off, and UIKit animations
/// are on (UI tests turn them off). Otherwise it holds still. Stopping drops
/// the running animations: the layers already hold the job's end state, which
/// is where the next job starts.
final class LivingPiMarkView: UIView {
    /// The icon's accent colours. Its white cells and the elves take the
    /// theme's foreground (`inkColor`).
    private static let accents: [LivingPiPlanner.Tint: UIColor] = [
        .amber: rgb(0xF5A02C), .red: rgb(0xF05A2D), .blue: rgb(0x3D8CF0),
        .sky: rgb(0x4397FF), .periwinkle: rgb(0x86A7FF), .lavender: rgb(0x9CACFF),
    ]
    private static let blockOpacity: Float = 0.94
    private static let elfOpacity: Float = 0.92
    /// The icon's cells: 85 px on a 97 px pitch, corners 23 px.
    private static let cellFraction: CGFloat = 85.0 / 97.0
    private static let cornerFraction: CGFloat = 23.0 / 85.0
    private static let elfFraction: CGFloat = 0.4
    private static let frameRate = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)

    /// The theme's foreground: the π's white cells and the elves.
    var inkColor: UIColor = .label {
        didSet { applyColors() }
    }

    /// A new seed each launch, so the show differs every time.
    private var planner = LivingPiPlanner(seed: .random(in: .min ... .max))
    private let blockLayers: [CALayer]
    private let elfLayers: [CALayer]
    private var wakeTimer: Timer?
    private var sceneIsInBackground = false

    override init(frame: CGRect) {
        blockLayers = LivingPiPlanner.slots.map { _ in
            let layer = CALayer()
            layer.opacity = Self.blockOpacity
            return layer
        }
        elfLayers = (0..<2).map { _ in
            let layer = CALayer()
            layer.opacity = Self.elfOpacity
            return layer
        }
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        for layer in blockLayers + elfLayers {
            layer.cornerCurve = .continuous
            self.layer.addSublayer(layer)
        }
        applyColors()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(conditionsDidChange), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(conditionsDidChange), name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(sceneDidEnterBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillEnterForeground(_:)), name: UIScene.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    private var pitch: CGFloat { bounds.width / CGFloat(LivingPiPlanner.gridSize) }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: (CGFloat(x) + 0.5) * pitch, y: (CGFloat(y) + 0.5) * pitch)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = pitch * Self.cellFraction
        let cellBounds = CGRect(x: 0, y: 0, width: side, height: side)
        let elfSide = pitch * Self.elfFraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in blockLayers {
            layer.bounds = cellBounds
            layer.cornerRadius = side * Self.cornerFraction
        }
        for layer in elfLayers {
            layer.bounds = CGRect(x: 0, y: 0, width: elfSide, height: elfSide)
            layer.cornerRadius = elfSide / 2
        }
        showState()
        CATransaction.commit()
    }

    // MARK: Colour

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private func color(_ tint: LivingPiPlanner.Tint) -> UIColor { Self.accents[tint] ?? inkColor }

    /// A lifted block brightens a little toward white, as if caught by light.
    /// The tint is resolved once per job, not once per keyframe.
    private func glow(_ tint: LivingPiPlanner.Tint, _ poses: [LivingPiPlanner.Pose]) -> [CGColor] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color(tint).resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return poses.map { pose in
            let lift = CGFloat(max(0, (pose.scale - 1) / 0.12) * 0.18)
            return UIColor(red: r + (1 - r) * lift, green: g + (1 - g) * lift, blue: b + (1 - b) * lift, alpha: a).cgColor
        }
    }

    private func applyColors() {
        let ink = inkColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in elfLayers { layer.backgroundColor = ink }
        for (layer, block) in zip(blockLayers, planner.blocks) {
            layer.backgroundColor = color(block.tint).resolvedColor(with: traitCollection).cgColor
        }
        CATransaction.commit()
    }

    // MARK: State

    /// Puts every layer where the planner's state is: the end of the last job.
    private func showState() {
        for (layer, block) in zip(blockLayers, planner.blocks) {
            layer.position = point(Double(block.cell.col), Double(block.cell.row))
            layer.transform = CATransform3DIdentity
            layer.zPosition = 0
        }
        for (layer, elf) in zip(elfLayers, planner.elves) {
            layer.position = point(Double(elf.col), Double(elf.row))
            layer.transform = CATransform3DIdentity
            layer.zPosition = 2
        }
    }

    // MARK: Running

    private var mayRun: Bool {
        window != nil && !isHidden && !sceneIsInBackground
            && !ProcessInfo.processInfo.isLowPowerModeEnabled && !UIAccessibility.isReduceMotionEnabled
    }

    override var isHidden: Bool {
        didSet { updateRunning() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneIsInBackground = window?.windowScene?.activationState == .background
        applyColors()
        updateRunning()
    }

    private func updateRunning() {
        if mayRun {
            if wakeTimer == nil { wake(after: planner.rest()) }
        } else {
            wakeTimer?.invalidate()
            wakeTimer = nil
            for layer in blockLayers + elfLayers { layer.removeAllAnimations() }
        }
    }

    private func wake(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runJob() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    private func runJob() {
        wakeTimer = nil
        guard mayRun else { return }
        // UI tests launch with UIKit animations off; a mark that keeps
        // animating would hold their idle wait.
        guard UIView.areAnimationsEnabled, let job = planner.nextJob() else {
            wake(after: planner.rest())
            return
        }
        play(job)
        wake(after: job.duration + planner.rest())
    }

    @objc nonisolated private func conditionsDidChange() {
        Task { @MainActor [weak self] in self?.updateRunning() }
    }

    @objc nonisolated private func sceneDidEnterBackground(_ note: Notification) {
        let scene = ObjectIdentifier(note.object as AnyObject)
        Task { @MainActor [weak self] in self?.sceneChanged(scene, inBackground: true) }
    }

    @objc nonisolated private func sceneWillEnterForeground(_ note: Notification) {
        let scene = ObjectIdentifier(note.object as AnyObject)
        Task { @MainActor [weak self] in self?.sceneChanged(scene, inBackground: false) }
    }

    private func sceneChanged(_ scene: ObjectIdentifier, inBackground: Bool) {
        guard let own = window?.windowScene, ObjectIdentifier(own) == scene else { return }
        sceneIsInBackground = inBackground
        updateRunning()
    }

    // MARK: Animation

    /// Turns one planned job into keyframe groups: positions and sizes for
    /// what moves, and a lifted block's brightening. The model values are set to the
    /// job's end first, so the layers stay there when the animations end.
    private func play(_ job: LivingPiPlanner.Job) {
        let frames = max(1, Int((job.duration / LivingPiPlanner.frameInterval).rounded(.up)))
        let times = (0...frames).map { min(job.duration, Double($0) * LivingPiPlanner.frameInterval) }
        let keyTimes = times.map { NSNumber(value: $0 / job.duration) }
        let start = CACurrentMediaTime()

        func animate(_ layer: CALayer, _ animations: [CAKeyframeAnimation]) {
            guard !animations.isEmpty else { return }
            for animation in animations {
                animation.keyTimes = keyTimes
                animation.calculationMode = .linear
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = job.duration
            group.beginTime = start
            group.fillMode = .backwards
            group.preferredFrameRateRange = Self.frameRate
            layer.add(group, forKey: "job")
        }
        func motion(_ poses: [LivingPiPlanner.Pose]) -> [CAKeyframeAnimation] {
            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = poses.map { NSValue(cgPoint: point($0.x, $0.y)) }
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = poses.map { $0.scale }
            return [position, scale]
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        showState()
        for (i, track) in job.blockTracks.enumerated() where !track.isStill {
            let poses = times.map(track.at)
            var animations = motion(poses)
            if poses.contains(where: { $0.scale != 1 }) {
                let brighten = CAKeyframeAnimation(keyPath: "backgroundColor")
                brighten.values = glow(planner.blocks[i].tint, poses)
                animations.append(brighten)
            }
            blockLayers[i].zPosition = 1
            animate(blockLayers[i], animations)
        }
        for (i, track) in job.elfTracks.enumerated() where !track.isStill {
            animate(elfLayers[i], motion(times.map(track.at)))
        }
        CATransaction.commit()
    }
}
