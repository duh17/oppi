import Metal
import QuartzCore
import UIKit

/// Native Metal host for one orb.
///
/// Owns display-link cadence, GPU submission, and lifecycle gating. Geometry is
/// CPU-shared; rasterization is batched Metal. Hidden, inactive, offscreen, and
/// Reduce Motion states stop the clock. Reduce Motion paints one still frame.
@MainActor
final class OrbMetalView: UIView {
    var style: OrbStyle {
        didSet { if style != oldValue { invalidateStillFrame() } }
    }
    var sizeClass: OrbSizeClass {
        didSet { if sizeClass != oldValue { invalidateStillFrame() } }
    }
    var voiceSpectrum: VoiceSpectrumFrame = .zero
    var isDarkBackground = true {
        didSet { if isDarkBackground != oldValue { invalidateStillFrame() } }
    }
    var isAnimationEnabled = true {
        didSet { updateRunning() }
    }
    var honorsSystemReduceMotion = true {
        didSet { updateRunning() }
    }
    var forceReduceMotion = false {
        didSet { updateRunning() }
    }
    var forceLowPowerMode = false {
        didSet { applyFrameRate() }
    }

    var tintUIColor: UIColor = .label {
        didSet {
            guard !Self.tintComponentsEqual(tintUIColor, oldValue, traits: traitCollection) else { return }
            fallbackLayer.fillColor = tintUIColor.cgColor
            invalidateStillFrame()
        }
    }
    var accentUIColors: [UIColor] = [] {
        didSet {
            guard !Self.accentColorsEqual(accentUIColors, oldValue, traits: traitCollection) else { return }
            invalidateStillFrame()
        }
    }

    private let renderer: OrbMetalRenderer?
    private(set) var unavailableReason: String?
    private let fallbackLayer = CAShapeLayer()
    private let ledger = OrbFrameLedger()
    private let displayLinkProxy = DisplayLinkProxy()
    nonisolated(unsafe) private var cadenceLink: CADisplayLink?
    nonisolated(unsafe) private var defaultObserverTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var visibilityObservations: [NSKeyValueObservation] = []
    private var smoother = VoiceSpectrumSmoother()
    private var lastStepNow: TimeInterval?
    private var clockOrigin: TimeInterval?
    private var sceneActive = true
    private var stillFramePresented = false

    var framesSubmitted: Int { ledger.submitted }
    var framesCompleted: Int { ledger.completed }
    var framesFailed: Int { ledger.failed }
    var framesSkipped: Int { ledger.skipped }
    private(set) var isDriving = false
    /// Smoothed input last fed into geometry, independent of GPU drawables.
    private(set) var lastPresentedSpectrum: VoiceSpectrumFrame = .zero
    private(set) var lastPresentedGeometryTime: Double = 0
    var rendererForTests: OrbMetalRenderer? { renderer }

    var isFrozen: Bool {
        forceReduceMotion || (honorsSystemReduceMotion && systemReduceMotionEnabled)
    }

    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    init(style: OrbStyle, sizeClass: OrbSizeClass) {
        self.style = style
        self.sizeClass = sizeClass
        let built = OrbMetalRenderer.make()
        self.renderer = built.renderer
        self.unavailableReason = built.unavailableReason
        super.init(frame: .zero)
        displayLinkProxy.owner = self
        if let reason = unavailableReason {
            OrbLog.logger.error("Thinking orb Metal unavailable: \(reason, privacy: .public)")
        }
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        // Tint resolves per color appearance; frames rasterize at display scale.
        registerForTraitChanges(
            UITraitCollection.systemTraitsAffectingColorAppearance + [UITraitDisplayScale.self]
        ) { (view: Self, _: UITraitCollection) in
            view.fallbackLayer.fillColor = view.tintUIColor.cgColor
            view.invalidateStillFrame()
        }
        configureLayer()
        renderer?.onFinished = { [ledger] cost in
            ledger.noteFinished(cost)
        }
        listenForLifecycle()
        sceneActive = currentSceneIsActive()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(owningSceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(owningSceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
    }

    @objc private func owningSceneWillDeactivate(_ note: Notification) {
        guard note.object as? UIScene === window?.windowScene else { return }
        sceneActive = false
        updateRunning()
    }

    @objc private func owningSceneDidActivate(_ note: Notification) {
        guard note.object as? UIScene === window?.windowScene else { return }
        sceneActive = true
        updateRunning()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        cadenceLink?.invalidate()
        cadenceLink = nil
        let defaultCenter = NotificationCenter.default
        defaultCenter.removeObserver(self)
        for token in defaultObserverTokens {
            defaultCenter.removeObserver(token)
        }
        defaultObserverTokens = []
        for observation in visibilityObservations {
            observation.invalidate()
        }
        visibilityObservations = []
    }

    func stopAndDismantle() {
        stopLink()
        clearVisibilityObservation()
    }

    override var isHidden: Bool {
        didSet { updateRunning() }
    }

    override var alpha: CGFloat {
        didSet { updateRunning() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopLink()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneActive = currentSceneIsActive()
        refreshVisibilityObservation()
        updateRunning()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        refreshVisibilityObservation()
        updateRunning()
    }

    override func removeFromSuperview() {
        stopLink()
        super.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMetal()
        updateRunning()
    }

    private func configureLayer() {
        fallbackLayer.fillColor = tintUIColor.cgColor
        fallbackLayer.strokeColor = nil
        fallbackLayer.isHidden = renderer != nil
        if let metalLayer {
            applyMetalProperties(to: metalLayer)
        }
        layer.addSublayer(fallbackLayer)
    }

    private func applyMetalProperties(to metalLayer: CAMetalLayer) {
        if let device = renderer?.device {
            metalLayer.device = device
        }
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
    }

    private func layoutMetal() {
        let bounds = self.bounds
        let scale = max(traitCollection.displayScale, 1)
        let drawable = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if let metalLayer {
            if metalLayer.contentsScale != scale {
                metalLayer.contentsScale = scale
            }
            if metalLayer.drawableSize != drawable {
                metalLayer.drawableSize = drawable
                stillFramePresented = false
            }
        }
        let inset = min(bounds.width, bounds.height) * 0.28
        fallbackLayer.frame = bounds
        fallbackLayer.path = CGPath(
            ellipseIn: bounds.insetBy(dx: inset, dy: inset),
            transform: nil
        )
    }

    var isEffectivelyVisible: Bool {
        guard let window, !window.isHidden, window.alpha > 0.01 else { return false }
        guard !isHidden, alpha > 0.01 else { return false }
        var rect = bounds
        var current: UIView = self
        while let parent = current.superview {
            if current.isHidden || current.alpha < 0.01 { return false }
            rect = current.convert(rect, to: parent)
            if parent.clipsToBounds {
                rect = rect.intersection(parent.bounds)
                if rect.isNull || rect.isEmpty { return false }
            }
            current = parent
        }
        let inWindow = current.convert(rect, to: window)
        let clipped = inWindow.intersection(window.bounds)
        return !clipped.isNull && !clipped.isEmpty
    }

    private var isSceneAbleToRender: Bool {
        sceneActive
    }

    private var canSubmit: Bool {
        isEffectivelyVisible
            && isSceneAbleToRender
            && isAnimationEnabled
            && renderer != nil
    }

    private var shouldRun: Bool {
        canSubmit && !isFrozen
    }

    private func updateRunning() {
        if shouldRun {
            stillFramePresented = false
            startLinkIfNeeded()
        } else {
            pauseOrStopLink()
            if canSubmit && isFrozen && !stillFramePresented {
                presentStillFrame()
            }
        }
    }

    private func startLinkIfNeeded() {
        if cadenceLink != nil {
            isDriving = true
            return
        }
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        cadenceLink = link
        applyFrameRate()
        link.add(to: .main, forMode: .common)
        isDriving = true
    }

    private func stopLink() {
        cadenceLink?.invalidate()
        cadenceLink = nil
        isDriving = false
        lastStepNow = nil
    }

    private func pauseOrStopLink() {
        stopLink()
    }

    private func applyFrameRate() {
        let lowPower = forceLowPowerMode || ProcessInfo.processInfo.isLowPowerModeEnabled
        let fps = OrbDisplayPolicy.preferredFramesPerSecond(
            isLowPowerModeEnabled: lowPower,
            thermalState: ProcessInfo.processInfo.thermalState
        )
        let rate = Float(fps)
        cadenceLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    fileprivate func handleDisplayLink(_ link: CADisplayLink) {
        if !isEffectivelyVisible || !isSceneAbleToRender || !isAnimationEnabled {
            pauseOrStopLink()
            return
        }
        if isFrozen {
            stopLink()
            if !stillFramePresented {
                presentStillFrame()
            }
            return
        }
        isDriving = true
        presentFrame(now: link.targetTimestamp, frozen: false)
    }

    private func presentStillFrame() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let now = CACurrentMediaTime()
        if clockOrigin == nil { clockOrigin = now }
        smoother.reset()
        if presentFrame(now: now, frozen: true) {
            stillFramePresented = true
        }
    }

    @discardableResult
    private func presentFrame(now: TimeInterval, frozen: Bool) -> Bool {
        guard canSubmit else { return false }
        if clockOrigin == nil { clockOrigin = now }
        let dt = lastStepNow.map { max(0, now - $0) } ?? 0
        lastStepNow = now
        let raw = frozen || !style.isVoiceReactive ? .zero : voiceSpectrum
        let smoothed = frozen ? .zero : smoother.step(raw: raw, dt: dt)
        let speed = OrbPresets.resolve(style, sizeClass).speed
        let wall = max(0, now - (clockOrigin ?? now))
        // Dictation uses wall time for Composing's calm sea and Breathing's alpha twinkle.
        let geometryTime = frozen ? OrbDisplayPolicy.reduceMotionTime
            : (style.isVoiceReactive ? wall : wall * speed)
        let side = Double(min(bounds.width, bounds.height))
        let design = side > 0 ? side : sizeClass.designSize
        lastPresentedSpectrum = smoothed
        lastPresentedGeometryTime = geometryTime
        let frame = OrbGeometry.frame(
            style: style,
            sizeClass: sizeClass,
            size: design,
            geometryTime: geometryTime,
            voiceSpectrum: smoothed
        )
        return submit(frame, designSize: design)
    }

    @discardableResult
    private func submit(_ frame: OrbFrame, designSize: Double) -> Bool {
        guard let renderer, let metalLayer else { return false }
        guard bounds.width > 0, bounds.height > 0 else { return false }
        if renderer.inFlightCount >= OrbMetalRenderer.ringSize {
            ledger.addSkipped()
            return false
        }
        let scale = max(traitCollection.displayScale, 1)
        if metalLayer.drawableSize.width < 1 || metalLayer.drawableSize.height < 1 {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
        guard let drawable = metalLayer.nextDrawable() else {
            ledger.addSkipped()
            return false
        }
        let cost = renderer.encode(
            dots: frame.dots,
            designSize: designSize,
            drawable: drawable,
            tint: currentTint,
            palette: currentPalette
        )
        if cost.submitted {
            ledger.addSubmitted()
            return true
        }
        ledger.addFailed()
        if let reason = cost.errorDescription {
            OrbLog.logger.error("Orb encode failed: \(reason, privacy: .public)")
        }
        return false
    }

    private var currentTint: OrbTint {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tintUIColor.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return OrbTint(
            red: Float(r),
            green: Float(g),
            blue: Float(b),
            isDark: isDarkBackground
        )
    }

    private var systemReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    private func invalidateStillFrame() {
        stillFramePresented = false
        updateRunning()
    }

    private func currentSceneIsActive() -> Bool {
        if let state = window?.windowScene?.activationState {
            return state == .foregroundActive
        }
        return UIApplication.shared.applicationState != .background
    }

    private func listenForLifecycle() {
        let center = NotificationCenter.default
        defaultObserverTokens.append(contentsOf: [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sceneActive = false
                    self?.updateRunning()
                }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sceneActive = true
                    self?.updateRunning()
                }
            },

            center.addObserver(
                forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            },
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyFrameRate() }
            },
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyFrameRate() }
            },
        ])
    }

    private func refreshVisibilityObservation() {
        clearVisibilityObservation()
        guard window != nil else { return }

        var ancestor: UIView? = superview
        while let view = ancestor {
            observeVisibilityKeyPath(view, \.isHidden)
            observeVisibilityKeyPath(view, \.alpha)
            observeVisibilityKeyPath(view, \.bounds)
            observeVisibilityKeyPath(view, \.frame)
            if let scroll = view as? UIScrollView {
                observeVisibilityKeyPath(scroll, \.contentOffset)
            }
            ancestor = view.superview
        }
    }

    private func clearVisibilityObservation() {
        for observation in visibilityObservations {
            observation.invalidate()
        }
        visibilityObservations = []
    }

    private func observeVisibilityKeyPath<T: NSObject, Value>(
        _ object: T,
        _ keyPath: KeyPath<T, Value>
    ) {
        visibilityObservations.append(
            object.observe(keyPath, options: []) { [weak self] _, _ in
                Self.deliverVisibilityPing(self)
            }
        )
    }

    nonisolated private static func deliverVisibilityPing(_ owner: OrbMetalView?) {
        guard let owner else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                owner.updateRunning()
            }
        } else {
            DispatchQueue.main.async {
                owner.updateRunning()
            }
        }
    }

    private var currentPalette: OrbPalette {
        let colors = accentUIColors
        let resolved: [SIMD3<Float>] = (0..<4).map { index in
            let color = index < colors.count ? colors[index] : tintUIColor
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD3(Float(r), Float(g), Float(b))
        }
        return OrbPalette(accents: resolved)
    }

    private static func tintComponentsEqual(_ lhs: UIColor, _ rhs: UIColor, traits: UITraitCollection) -> Bool {
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        lhs.resolvedColor(with: traits).getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        rhs.resolvedColor(with: traits).getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        return lr == rr && lg == rg && lb == rb && la == ra
    }

    private static func accentColorsEqual(_ lhs: [UIColor], _ rhs: [UIColor], traits: UITraitCollection) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { tintComponentsEqual($0, $1, traits: traits) }
    }

    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var owner: OrbMetalView?

        @objc func tick(_ link: CADisplayLink) {
            owner?.handleDisplayLink(link)
        }
    }
}

/// GPU-thread-safe submit/complete counters. Completion handlers must not hop
/// to the main actor.
private final class OrbFrameLedger: @unchecked Sendable {
    private struct Counters {
        var submitted = 0
        var completed = 0
        var failed = 0
        var skipped = 0
    }

    private let lock = NSLock()
    private var counters = Counters()

    var submitted: Int { lock.withLock { counters.submitted } }
    var completed: Int { lock.withLock { counters.completed } }
    var failed: Int { lock.withLock { counters.failed } }
    var skipped: Int { lock.withLock { counters.skipped } }

    func addSubmitted() {
        lock.withLock { counters.submitted += 1 }
    }

    func addFailed() {
        lock.withLock { counters.failed += 1 }
    }

    func addSkipped() {
        lock.withLock { counters.skipped += 1 }
    }

    func noteFinished(_ cost: OrbMetalFrameCost) {
        lock.withLock {
            if cost.completed {
                counters.completed += 1
            } else {
                counters.failed += 1
            }
        }
        if !cost.completed, let reason = cost.errorDescription {
            OrbLog.logger.error("Orb GPU failed: \(reason, privacy: .public)")
        }
    }
}
