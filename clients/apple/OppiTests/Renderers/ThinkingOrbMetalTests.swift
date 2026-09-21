import Foundation
import Metal
import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("ThinkingOrbMetalRenderer")
struct ThinkingOrbMetalRendererTests {
    @Test func offscreenEncodeCompletesOnTheGPU() throws {
        let built = ThinkingOrbMetalRenderer.make()
        guard let renderer = built.renderer else {
            Issue.record("Metal unavailable: \(built.unavailableReason ?? "unknown")")
            return
        }
        let frame = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: 16,
            geometryTime: 0.6
        )
        guard let texture = renderer.makeOffscreenTexture(width: 48, height: 48, renderTarget: true) else {
            Issue.record("failed to allocate offscreen texture")
            return
        }
        let cost = renderer.encodeOffscreen(
            dots: frame.dots,
            designSize: 16,
            texture: texture,
            tint: .darkFallback,
            waitUntilCompleted: true
        )
        #expect(cost.submitted)
        #expect(cost.completed)
        #expect(cost.status == .completed)
        #expect(renderer.inFlightCount == 0)
        #expect(renderer.freeSlotCount == ThinkingOrbMetalRenderer.ringSize)
    }

    @Test func injectedEncodeFailureReleasesTheRingSlot() throws {
        let built = ThinkingOrbMetalRenderer.make()
        guard let renderer = built.renderer else {
            Issue.record("Metal unavailable: \(built.unavailableReason ?? "unknown")")
            return
        }
        let frame = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: 16,
            geometryTime: 0.4
        )
        guard let texture = renderer.makeOffscreenTexture(width: 32, height: 32, renderTarget: true) else {
            Issue.record("failed to allocate offscreen texture")
            return
        }
        let before = renderer.freeSlotCount
        renderer.encodeFault = .nilEncoder
        let cost = renderer.encodeOffscreen(
            dots: frame.dots,
            designSize: 16,
            texture: texture,
            tint: .darkFallback,
            waitUntilCompleted: false
        )
        #expect(!cost.submitted)
        #expect(!cost.completed)
        #expect(cost.errorDescription == "makeRenderCommandEncoder returned nil")
        #expect(renderer.freeSlotCount == before)
        #expect(renderer.inFlightCount == 0)

        renderer.encodeFault = .none
        let recovered = renderer.encodeOffscreen(
            dots: frame.dots,
            designSize: 16,
            texture: texture,
            tint: .darkFallback,
            waitUntilCompleted: true
        )
        #expect(recovered.submitted)
        #expect(recovered.completed)
        #expect(renderer.freeSlotCount == before)
    }
}

@Suite("ThinkingOrbMetalView lifecycle")
@MainActor
struct ThinkingOrbMetalViewLifecycleTests {
    @Test func mountedViewSubmitsAndCompletesLiveDrawables() async throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }

        let completed = try await waitForCompletions(on: harness.view, minimum: 2)
        #expect(completed >= 2)
        #expect(harness.view.framesSubmitted >= completed)
        #expect(harness.view.isDriving)
        #expect(harness.view.unavailableReason == nil)
        #expect(harness.view.frame.origin == CGPoint(x: 18, y: 18))
    }

    @Test func layoutDoesNotResetParentRelativeFrame() throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        harness.view.setNeedsLayout()
        harness.view.layoutIfNeeded()
        harness.host.view.layoutIfNeeded()
        #expect(harness.view.frame == CGRect(x: 18, y: 18, width: 16, height: 16))
    }

    @Test func hidingTheViewStopsTheDisplayClock() async throws {
        let harness = try makeOrbHarness(style: .composing, side: 44)
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        #expect(harness.view.isDriving)

        harness.view.isHidden = true
        #expect(!harness.view.isDriving)

        let submitted = harness.view.framesSubmitted
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.view.framesSubmitted == submitted)
    }

    @Test func hidingTheWindowStopsAndShowingRestartsWithoutLayout() async throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        #expect(harness.view.isDriving)
        harness.window.isHidden = true
        try await waitUntilStopped(harness.view)
        #expect(!harness.view.isDriving)
        let submitted = harness.view.framesSubmitted
        harness.window.isHidden = false
        #expect(harness.view.isDriving)
        #expect(harness.view.framesSubmitted == submitted)
    }

    @Test func hidingAnAncestorStopsAndUnhidingRestartsWithoutLayout() async throws {
        let harness = try makeOrbHarness(style: .searching, side: 16)
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        harness.container.isHidden = true
        try await waitUntilStopped(harness.view)
        #expect(!harness.view.isDriving)
        harness.container.isHidden = false
        #expect(harness.view.isDriving)
    }

    @Test func ancestorAlphaStopsAndRestoresWithoutLayout() async throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        harness.container.alpha = 0
        try await waitUntilStopped(harness.view)
        #expect(!harness.view.isDriving)
        harness.container.alpha = 1
        #expect(harness.view.isDriving)
    }

    @Test func scrollingOffscreenStopsAndReentryRestartsWithoutLayout() async throws {
        let harness = try makeOrbScrollHarness()
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        #expect(harness.view.isDriving)
        harness.scroll?.contentOffset = CGPoint(x: 0, y: 240)
        try await waitUntilStopped(harness.view)
        #expect(!harness.view.isEffectivelyVisible)
        #expect(!harness.view.isDriving)
        harness.scroll?.contentOffset = .zero
        #expect(harness.view.isEffectivelyVisible)
        #expect(harness.view.isDriving)
    }

    @Test func nestedClippedAncestorsUseAccumulatedIntersection() throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        outer.clipsToBounds = true
        let inner = UIView(frame: CGRect(x: 0, y: 100, width: 80, height: 80))
        inner.clipsToBounds = true
        harness.view.removeFromSuperview()
        harness.view.frame = CGRect(x: 0, y: -150, width: 16, height: 200)
        inner.addSubview(harness.view)
        outer.addSubview(inner)
        harness.container.addSubview(outer)
        harness.container.layoutIfNeeded()
        #expect(!harness.view.isEffectivelyVisible)
    }

    @Test func reduceMotionPaintsOneStillFrameThenResumes() async throws {
        let harness = try makeOrbHarness(style: .searching, side: 16)
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        let liveSubmitted = harness.view.framesSubmitted
        harness.view.forceReduceMotion = true
        #expect(!harness.view.isDriving)
        #expect(harness.view.framesSubmitted == liveSubmitted + 1)
        let frozenSubmitted = harness.view.framesSubmitted
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.view.framesSubmitted == frozenSubmitted)

        harness.view.forceReduceMotion = false
        #expect(harness.view.isDriving)
    }

    @Test func freezeResumeFreezePresentsANewStillFrame() async throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        let liveSubmitted = harness.view.framesSubmitted
        harness.view.forceReduceMotion = true
        #expect(harness.view.framesSubmitted == liveSubmitted + 1)
        let frozenSubmitted = harness.view.framesSubmitted
        harness.view.forceReduceMotion = false
        #expect(harness.view.isDriving)
        harness.view.forceReduceMotion = true
        #expect(!harness.view.isDriving)
        #expect(harness.view.framesSubmitted == frozenSubmitted + 1)
    }

    @Test func frozenResizePresentsOneRightSizeStill() async throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        harness.view.forceReduceMotion = true
        let submitted = harness.view.framesSubmitted
        #expect(submitted >= 1)
        let scale = harness.window.screen.scale
        harness.view.frame = CGRect(x: 18, y: 18, width: 32, height: 32)
        harness.view.layoutIfNeeded()
        #expect(harness.view.framesSubmitted == submitted + 1)
        let metal = try #require(harness.view.layer as? CAMetalLayer)
        #expect(metal.drawableSize == CGSize(width: 32 * scale, height: 32 * scale))
        #expect(!harness.view.isDriving)
    }

    @Test func frozenZeroBoundsPresentsOnceAfterFirstRealLayout() throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        let orb = ThinkingOrbMetalView(style: .working, sizeClass: .workingCompact)
        orb.forceReduceMotion = true
        orb.tintUIColor = .white
        orb.frame = .zero
        harness.container.addSubview(orb)
        #expect(orb.framesSubmitted == 0)
        orb.frame = CGRect(x: 18, y: 18, width: 16, height: 16)
        orb.layoutIfNeeded()
        #expect(orb.framesSubmitted == 1)
        #expect(!orb.isDriving)
        orb.stopAndDismantle()
        orb.removeFromSuperview()
    }

    @Test func frozenTintChangeSubmitsAnotherStillFrame() async throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        harness.view.forceReduceMotion = true
        let submitted = harness.view.framesSubmitted
        #expect(submitted >= 1)
        harness.view.tintUIColor = .red
        #expect(harness.view.framesSubmitted == submitted + 1)
        #expect(!harness.view.isDriving)
    }

    @Test func equivalentFrozenTintDoesNotResubmit() throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        harness.view.forceReduceMotion = true
        harness.view.tintUIColor = .red
        let submitted = harness.view.framesSubmitted
        harness.view.tintUIColor = .red
        #expect(harness.view.framesSubmitted == submitted)
    }

    @Test func hiddenFrozenTintUpdateDoesNotSubmitUntilReappearance() throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        harness.view.forceReduceMotion = true
        let submitted = harness.view.framesSubmitted
        harness.view.isHidden = true
        harness.view.tintUIColor = .red
        #expect(harness.view.framesSubmitted == submitted)
        harness.view.isHidden = false
        #expect(harness.view.framesSubmitted == submitted + 1)
        #expect(!harness.view.isDriving)
    }

    @Test func backgroundFrozenTintUpdateDoesNotSubmitUntilActive() throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        harness.view.forceReduceMotion = true
        let submitted = harness.view.framesSubmitted
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        harness.view.tintUIColor = .systemBlue
        #expect(harness.view.framesSubmitted == submitted)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(harness.view.framesSubmitted == submitted + 1)
        #expect(!harness.view.isDriving)
    }

    @Test func audioOnlyChromeUpdatesDoNotResubmitFrozenOrb() throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        let chrome = MicButtonChromeView()
        chrome.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        harness.container.addSubview(chrome)
        chrome.apply(
            isRecording: true,
            isProcessing: false,
            audioLevel: 0.2,
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 44,
            animated: false
        )
        chrome.layoutIfNeeded()
        let orb = try #require(firstSubview(of: chrome, type: ThinkingOrbMetalView.self))
        orb.forceReduceMotion = true
        #expect(orb.framesSubmitted >= 1)
        let submitted = orb.framesSubmitted
        chrome.apply(
            isRecording: true,
            isProcessing: false,
            audioLevel: 0.9,
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 44,
            animated: false
        )
        #expect(orb.framesSubmitted == submitted)
        #expect(orb.audioLevel == 0.9)
    }

    @Test func removingTheViewAllowsDeallocation() async throws {
        weak var weakView: ThinkingOrbMetalView?
        do {
            let harness = try makeOrbHarness(style: .working, side: 16)
            weakView = harness.view
            _ = try await waitForCompletions(on: harness.view, minimum: 1)
            tearDown(harness)
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))
        #expect(weakView == nil)
    }

    @Test func foreignSceneNotificationDoesNotPauseOwningOrb() async throws {
        let harness = try makeOrbHarness(style: .working, side: 16)
        defer { tearDown(harness) }
        _ = try await waitForCompletions(on: harness.view, minimum: 1)
        #expect(harness.view.isDriving)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: nil)
        #expect(harness.view.isDriving)
    }
}

@Suite("Mic button orb layout")
@MainActor
struct MicButtonOrbLayoutTests {
    @Test func standardAndExpandedDiametersStayExact() {
        #expect(micButtonFitSize(diameter: ComposerInputMetrics.controlDiameter) == CGSize(width: 44, height: 44))
        #expect(micButtonFitSize(diameter: 32) == CGSize(width: 32, height: 32))
    }

    @Test func composingOrbHasNoLanguageOrCloudOverlay() {
        let host = UIHostingController(
            rootView: MicButtonLabel(
                isRecording: true,
                isProcessing: false,
                audioLevel: 0.4,
                languageLabel: "EN",
                accentColor: .blue,
                engineBadge: .onDevice,
                diameter: 44,
                dictationStyle: .composing
            )
        )
        host.view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        host.view.layoutIfNeeded()
        let labels = allLabels(in: host.view).filter { !$0.isHidden }
        #expect(!labels.contains { $0.text == "EN" })
        #expect(firstSubview(of: host.view, type: UIImageView.self)?.isHidden != false
            || firstSubview(of: host.view, type: UIImageView.self)?.image == nil)
    }

    @Test func preparingDoesNotFeedVoiceIntoTheOrb() {
        let chrome = MicButtonChromeView()
        chrome.apply(
            isRecording: false,
            isProcessing: false,
            audioLevel: 0.9,
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 44,
            animated: false,
            isPreparing: true
        )
        let orb = firstSubview(of: chrome, type: ThinkingOrbMetalView.self)
        #expect(orb?.isHidden == false)
        #expect(orb?.audioLevel == 0)
        #expect(chrome.intrinsicContentSize == CGSize(width: 44, height: 44))
        let labels = allLabels(in: chrome).filter { !$0.isHidden }
        #expect(!labels.contains { $0.text == "EN" })
    }

    @Test func uikitChromeKeepsHitTargetAndDoesNotGrow() {
        let chrome = MicButtonChromeView()
        chrome.apply(
            isRecording: true,
            isProcessing: false,
            audioLevel: 0.4,
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 44,
            animated: false
        )
        #expect(chrome.intrinsicContentSize == CGSize(width: 44, height: 44))
        chrome.apply(
            isRecording: true,
            isProcessing: false,
            audioLevel: 1,
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 32,
            animated: false
        )
        #expect(chrome.intrinsicContentSize == CGSize(width: 32, height: 32))
    }
}

@Suite("Working indicator metal size")
@MainActor
struct WorkingIndicatorMetalSizeTests {
    @Test func nativeMetalStyleKeepsTheSixteenPointSpinner() {
        let key = AppPreferenceStore.Appearance.spinnerStyleKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        AppPreferenceStore.Appearance.setSpinnerStyle(.working)
        let view = WorkingIndicatorTimelineRowConfiguration(
            modelId: nil,
            workingState: nil
        ).makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let metal = firstSubview(of: view, type: ThinkingOrbMetalView.self)
        #expect(metal != nil)
        #expect(metal?.bounds.size == CGSize(width: 16, height: 16))
        #expect(metal?.isHidden == false)
    }

    @Test func extensionHiddenIndicatorHidesTheMetalOrb() {
        let key = AppPreferenceStore.Appearance.spinnerStyleKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        AppPreferenceStore.Appearance.setSpinnerStyle(.working)
        let view = WorkingIndicatorTimelineRowConfiguration(
            modelId: nil,
            workingState: ExtensionWorkingState(
                message: "Waiting for tools",
                indicator: ExtensionUIWorkingIndicator(frames: [], intervalMs: nil)
            )
        ).makeContentView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let metal = firstSubview(of: view, type: ThinkingOrbMetalView.self)
        #expect(metal?.isHidden == true)
    }
}

private struct OrbHarness {
    let window: UIWindow
    let host: UIViewController
    let container: UIView
    let view: ThinkingOrbMetalView
    var scroll: UIScrollView?
}

@MainActor
private func makeOrbHarness(style: ThinkingOrbStyle, side: CGFloat) throws -> OrbHarness {
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first
    else {
        throw TestHostError.missingScene
    }
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
    let host = UIViewController()
    window.rootViewController = host
    let container = UIView(frame: host.view.bounds)
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.view.addSubview(container)
    let view = ThinkingOrbMetalView(
        style: style,
        sizeClass: style.isVoiceReactive
            ? .dictation(side: Double(side))
            : .working(side: Double(side))
    )
    view.frame = CGRect(x: 18, y: 18, width: side, height: side)
    view.tintUIColor = .white
    view.isDarkBackground = true
    container.addSubview(view)
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    view.layoutIfNeeded()
    return OrbHarness(window: window, host: host, container: container, view: view, scroll: nil)
}

@MainActor
private func makeOrbScrollHarness() throws -> OrbHarness {
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first
    else {
        throw TestHostError.missingScene
    }
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
    let host = UIViewController()
    window.rootViewController = host
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.view.addSubview(container)
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
    scroll.clipsToBounds = true
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.contentSize = CGSize(width: 80, height: 480)
    container.addSubview(scroll)
    let view = ThinkingOrbMetalView(style: .working, sizeClass: .workingCompact)
    view.translatesAutoresizingMaskIntoConstraints = true
    view.frame = CGRect(x: 18, y: 18, width: 16, height: 16)
    view.tintUIColor = .white
    view.isDarkBackground = true
    scroll.addSubview(view)
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    scroll.layoutIfNeeded()
    view.layoutIfNeeded()
    return OrbHarness(window: window, host: host, container: container, view: view, scroll: scroll)
}

@MainActor
private func tearDown(_ harness: OrbHarness) {
    harness.view.stopAndDismantle()
    harness.view.removeFromSuperview()
    harness.container.removeFromSuperview()
    harness.window.rootViewController = nil
    harness.window.isHidden = true
}

@MainActor
private func waitForCompletions(on view: ThinkingOrbMetalView, minimum: Int) async throws -> Int {
    let deadline = ContinuousClock.now + .seconds(1.2)
    while ContinuousClock.now < deadline {
        if view.framesCompleted >= minimum {
            return view.framesCompleted
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(16))
    }
    if view.framesCompleted >= minimum {
        return view.framesCompleted
    }
    throw TestHostError.timeout(orbTimeoutMessage(view, expected: "framesCompleted >= \(minimum)"))
}

@MainActor
private func waitUntilStopped(_ view: ThinkingOrbMetalView) async throws {
    let deadline = ContinuousClock.now + .seconds(1.2)
    while ContinuousClock.now < deadline {
        if !view.isDriving { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(16))
    }
    if view.isDriving {
        throw TestHostError.timeout(orbTimeoutMessage(view, expected: "isDriving == false"))
    }
}

@MainActor
private func orbTimeoutMessage(_ view: ThinkingOrbMetalView, expected: String) -> String {
    let metal = view.layer as? CAMetalLayer
    return """
    expected \(expected); driving=\(view.isDriving) submitted=\(view.framesSubmitted) \
    completed=\(view.framesCompleted) skipped=\(view.framesSkipped) \
    failed=\(view.framesFailed) visible=\(view.isEffectivelyVisible) \
    windowHidden=\(view.window?.isHidden ?? true) \
    drawable=\(String(describing: metal?.drawableSize)) \
    device=\(metal?.device != nil) unavailable=\(view.unavailableReason ?? "nil")
    """
}

@MainActor
private func micButtonFitSize(diameter: CGFloat) -> CGSize {
    let label = MicButtonLabel(
        isRecording: true,
        isProcessing: false,
        audioLevel: 0.35,
        languageLabel: "EN",
        accentColor: .blue,
        engineBadge: .onDevice,
        diameter: diameter,
        dictationStyle: .composing
    )
    let host = UIHostingController(rootView: label)
    host.safeAreaRegions = []
    return host.sizeThatFits(in: CGSize(width: 400, height: 400))
}

private func firstSubview<T: UIView>(of root: UIView, type: T.Type) -> T? {
    if let match = root as? T { return match }
    for child in root.subviews {
        if let match = firstSubview(of: child, type: type) { return match }
    }
    return nil
}

private func allLabels(in root: UIView) -> [UILabel] {
    var labels: [UILabel] = []
    if let label = root as? UILabel { labels.append(label) }
    for child in root.subviews {
        labels.append(contentsOf: allLabels(in: child))
    }
    return labels
}

private enum TestHostError: Error, CustomStringConvertible {
    case missingScene
    case timeout(String)

    var description: String {
        switch self {
        case .missingScene: "missing scene"
        case .timeout(let detail): detail
        }
    }
}
