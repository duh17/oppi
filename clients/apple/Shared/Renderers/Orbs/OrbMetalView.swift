#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Metal
import QuartzCore
import SwiftUI

#if canImport(UIKit)
typealias OrbPlatformView = UIView
#else
typealias OrbPlatformView = NSView
#endif

/// Native Metal host for one orb.
///
/// Owns display-link cadence, GPU submission, and lifecycle gating. Geometry is
/// CPU-shared; rasterization is batched Metal. Hidden, inactive, offscreen, and
/// Reduce Motion states stop the clock. Reduce Motion paints one still frame.
@MainActor
final class OrbMetalView: OrbPlatformView {
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

    #if canImport(UIKit)
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
    #else
    var tintNSColor: NSColor = .labelColor {
        didSet {
            guard !Self.tintComponentsEqual(tintNSColor, oldValue) else { return }
            fallbackLayer.fillColor = tintNSColor.cgColor
            invalidateStillFrame()
        }
    }
    var accentNSColors: [NSColor] = [] {
        didSet {
            guard !Self.accentColorsEqual(accentNSColors, oldValue) else { return }
            invalidateStillFrame()
        }
    }
    #endif

    private let renderer: OrbMetalRenderer?
    private(set) var unavailableReason: String?
    private let fallbackLayer = CAShapeLayer()
    private let ledger = OrbFrameLedger()
    private let displayLinkProxy = DisplayLinkProxy()
    nonisolated(unsafe) private var cadenceLink: CADisplayLink?
    nonisolated(unsafe) private var defaultObserverTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var workspaceObserverTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var windowObserverTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var visibilityObservations: [NSKeyValueObservation] = []
    nonisolated(unsafe) private var clipBoundsTokens: [NSObjectProtocol] = []
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

    #if canImport(UIKit)
    override class var layerClass: AnyClass { CAMetalLayer.self }
    #endif

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
        #if canImport(UIKit)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        #else
        wantsLayer = true
        clipsToBounds = true
        #endif
        configureLayer()
        renderer?.onFinished = { [ledger] cost in
            ledger.noteFinished(cost)
        }
        listenForLifecycle()
        sceneActive = currentSceneIsActive()
        #if canImport(UIKit)
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
        #endif
    }

    #if canImport(UIKit)
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
    #endif

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
        for token in windowObserverTokens {
            defaultCenter.removeObserver(token)
        }
        windowObserverTokens = []
        for token in clipBoundsTokens {
            defaultCenter.removeObserver(token)
        }
        clipBoundsTokens = []
        for observation in visibilityObservations {
            observation.invalidate()
        }
        visibilityObservations = []
        #if canImport(AppKit)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObserverTokens {
            workspaceCenter.removeObserver(token)
        }
        workspaceObserverTokens = []
        #endif
    }

    #if canImport(AppKit)
    override func makeBackingLayer() -> CALayer {
        let metal = CAMetalLayer()
        applyMetalProperties(to: metal)
        return metal
    }
    #endif

    func stopAndDismantle() {
        stopLink()
        clearVisibilityObservation()
    }

    #if canImport(UIKit)
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        fallbackLayer.fillColor = tintUIColor.cgColor
        invalidateStillFrame()
    }
    #else
    override var isHidden: Bool {
        didSet { updateRunning() }
    }

    override var alphaValue: CGFloat {
        didSet { updateRunning() }
    }

    override func viewWillMove(toWindow window: NSWindow?) {
        super.viewWillMove(toWindow: window)
        if window == nil {
            stopLink()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sceneActive = currentSceneIsActive()
        refreshVisibilityObservation()
        updateRunning()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshVisibilityObservation()
        updateRunning()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRunning()
    }

    override func removeFromSuperview() {
        stopLink()
        super.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        layoutMetal()
        updateRunning()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fallbackLayer.fillColor = tintNSColor.cgColor
        invalidateStillFrame()
    }
    #endif

    private func configureLayer() {
        fallbackLayer.fillColor = {
            #if canImport(UIKit)
            return tintUIColor.cgColor
            #else
            return tintNSColor.cgColor
            #endif
        }()
        fallbackLayer.strokeColor = nil
        fallbackLayer.isHidden = renderer != nil
        if let metalLayer {
            applyMetalProperties(to: metalLayer)
        }
        #if canImport(UIKit)
        layer.addSublayer(fallbackLayer)
        #else
        layer?.addSublayer(fallbackLayer)
        #endif
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
        #if canImport(UIKit)
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        #else
        let scale = max(window?.backingScaleFactor ?? 1, 1)
        #endif
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
        guard window != nil else { return false }
        #if canImport(UIKit)
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
        #else
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        guard !isHidden, alphaValue > 0.01 else { return false }
        var rect = bounds
        var current: NSView = self
        while let parent = current.superview {
            if current.isHidden || current.alphaValue < 0.01 { return false }
            rect = current.convert(rect, to: parent)
            if parent.clipsToBounds || parent is NSClipView {
                rect = rect.intersection(parent.bounds)
                if rect.isNull || rect.isEmpty { return false }
            }
            current = parent
        }
        guard let content = window.contentView else { return true }
        let inContent = current.convert(rect, to: content)
        let clipped = inContent.intersection(content.bounds)
        return !clipped.isNull && !clipped.isEmpty
        #endif
    }

    private var isSceneAbleToRender: Bool {
        #if canImport(UIKit)
        sceneActive
        #else
        currentSceneIsActive()
        #endif
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
        #if canImport(AppKit)
        sceneActive = currentSceneIsActive()
        #endif
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
        #if canImport(UIKit)
        let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        #else
        let link = displayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        #endif
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
        #if canImport(AppKit)
        // NSView.displayLink does not invoke while the view is hidden or off-display.
        // Keep that link so AppKit can resume without a layout pass.
        if window != nil, cadenceLink != nil, !isEffectivelyVisible {
            isDriving = false
            lastStepNow = nil
            return
        }
        #endif
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
        #if canImport(UIKit)
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        #else
        let scale = max(window?.backingScaleFactor ?? 1, 1)
        #endif
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
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tintUIColor.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return OrbTint(
            red: Float(r),
            green: Float(g),
            blue: Float(b),
            isDark: isDarkBackground
        )
        #else
        let rgb = tintNSColor.usingColorSpace(.deviceRGB) ?? tintNSColor
        return OrbTint(
            red: Float(rgb.redComponent),
            green: Float(rgb.greenComponent),
            blue: Float(rgb.blueComponent),
            isDark: isDarkBackground
        )
        #endif
    }

    private var systemReduceMotionEnabled: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    private func invalidateStillFrame() {
        stillFramePresented = false
        updateRunning()
    }

    private func currentSceneIsActive() -> Bool {
        #if canImport(UIKit)
        if let state = window?.windowScene?.activationState {
            return state == .foregroundActive
        }
        return UIApplication.shared.applicationState != .background
        #else
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && !(NSApp?.isHidden ?? false)
        #endif
    }

    private func listenForLifecycle() {
        let center = NotificationCenter.default
        #if canImport(UIKit)
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
        #else
        defaultObserverTokens.append(contentsOf: [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sceneActive = false
                    self?.updateRunning()
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sceneActive = true
                    self?.updateRunning()
                }
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
        workspaceObserverTokens.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            }
        )
        #endif
    }

    private func refreshVisibilityObservation() {
        clearVisibilityObservation()
        guard window != nil else { return }

        #if canImport(UIKit)
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
        #else
        observeHostWindow(window)
        var ancestor: NSView? = superview
        while let view = ancestor {
            observeVisibilityKeyPath(view, \.isHidden)
            observeVisibilityKeyPath(view, \.alphaValue)
            observeVisibilityKeyPath(view, \.bounds)
            observeVisibilityKeyPath(view, \.frame)
            if let clip = view as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                clipBoundsTokens.append(
                    NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification,
                        object: clip,
                        queue: nil
                    ) { [weak self] _ in
                        Self.deliverVisibilityPing(self)
                    }
                )
            }
            ancestor = view.superview
        }
        #endif
    }

    private func clearVisibilityObservation() {
        for observation in visibilityObservations {
            observation.invalidate()
        }
        visibilityObservations = []
        let center = NotificationCenter.default
        for token in windowObserverTokens {
            center.removeObserver(token)
        }
        windowObserverTokens = []
        for token in clipBoundsTokens {
            center.removeObserver(token)
        }
        clipBoundsTokens = []
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

    #if canImport(AppKit)
    private func observeHostWindow(_ window: NSWindow?) {
        guard let window else { return }
        observeVisibilityKeyPath(window, \.isVisible)
        observeVisibilityKeyPath(window, \.occlusionState)
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExposeNotification,
        ]
        for name in names {
            windowObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: nil
                ) { [weak self] _ in
                    Self.deliverVisibilityPing(self)
                }
            )
        }
    }
    #endif

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
        #if canImport(UIKit)
        let colors = accentUIColors
        let resolved: [SIMD3<Float>] = (0..<4).map { index in
            let color = index < colors.count ? colors[index] : tintUIColor
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD3(Float(r), Float(g), Float(b))
        }
        return OrbPalette(accents: resolved)
        #else
        let colors = accentNSColors
        let resolved: [SIMD3<Float>] = (0..<4).map { index in
            let raw = index < colors.count ? colors[index] : tintNSColor
            let rgb = raw.usingColorSpace(.deviceRGB) ?? raw
            return SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
        }
        return OrbPalette(accents: resolved)
        #endif
    }

    #if canImport(UIKit)
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
    #else
    private static func tintComponentsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
        return left.redComponent == right.redComponent
            && left.greenComponent == right.greenComponent
            && left.blueComponent == right.blueComponent
            && left.alphaComponent == right.alphaComponent
    }

    private static func accentColorsEqual(_ lhs: [NSColor], _ rhs: [NSColor]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { tintComponentsEqual($0, $1) }
    }
    #endif

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

struct OrbView: View {
    var style: OrbStyle
    var sizeClass: OrbSizeClass
    var tint: Color
    var voiceSpectrum: VoiceSpectrumFrame = .zero
    var isActive: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID

    var body: some View {
        OrbRepresentable(
            style: style,
            sizeClass: sizeClass,
            tint: tint,
            accents: [
                theme.accent.blue,
                theme.accent.cyan,
                theme.accent.purple,
                theme.accent.orange,
            ],
            voiceSpectrum: voiceSpectrum,
            isActive: isActive,
            isDarkBackground: colorScheme == .dark
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .id(themeID)
    }
}

#if canImport(UIKit)
private struct OrbRepresentable: UIViewRepresentable {
    var style: OrbStyle
    var sizeClass: OrbSizeClass
    var tint: Color
    var accents: [Color]
    var voiceSpectrum: VoiceSpectrumFrame
    var isActive: Bool
    var isDarkBackground: Bool

    func makeUIView(context: Context) -> OrbMetalView {
        let view = OrbMetalView(style: style, sizeClass: sizeClass)
        apply(view)
        return view
    }

    func updateUIView(_ uiView: OrbMetalView, context: Context) {
        apply(uiView)
    }

    static func dismantleUIView(_ uiView: OrbMetalView, coordinator: ()) {
        uiView.stopAndDismantle()
    }

    private func apply(_ view: OrbMetalView) {
        view.style = style
        view.sizeClass = sizeClass
        view.tintUIColor = UIColor(tint)
        view.accentUIColors = accents.map { UIColor($0) }
        view.voiceSpectrum = voiceSpectrum
        view.isAnimationEnabled = isActive
        view.isDarkBackground = isDarkBackground
        view.honorsSystemReduceMotion = true
    }
}
#else
private struct OrbRepresentable: NSViewRepresentable {
    var style: OrbStyle
    var sizeClass: OrbSizeClass
    var tint: Color
    var accents: [Color]
    var voiceSpectrum: VoiceSpectrumFrame
    var isActive: Bool
    var isDarkBackground: Bool

    func makeNSView(context: Context) -> OrbMetalView {
        let view = OrbMetalView(style: style, sizeClass: sizeClass)
        apply(view)
        return view
    }

    func updateNSView(_ nsView: OrbMetalView, context: Context) {
        apply(nsView)
    }

    static func dismantleNSView(_ nsView: OrbMetalView, coordinator: ()) {
        nsView.stopAndDismantle()
    }

    private func apply(_ view: OrbMetalView) {
        view.style = style
        view.sizeClass = sizeClass
        view.tintNSColor = NSColor(tint)
        view.accentNSColors = accents.map { NSColor($0) }
        view.voiceSpectrum = voiceSpectrum
        view.isAnimationEnabled = isActive
        view.isDarkBackground = isDarkBackground
        view.honorsSystemReduceMotion = true
    }
}
#endif
