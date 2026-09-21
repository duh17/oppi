import AppKit
import QuartzCore
import Testing
@testable import Oppi

@Suite("Mac thinking orb Metal host")
@MainActor
struct MacThinkingOrbMetalTests {
    @Test func macOffscreenEncodeCompletesOnTheGPU() throws {
        let built = ThinkingOrbMetalRenderer.make()
        guard let renderer = built.renderer else {
            Issue.record("Metal unavailable: \(built.unavailableReason ?? "unknown")")
            return
        }
        let design = ThinkingOrbSizeClass.workingCompact.designSize
        let frame = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: design,
            geometryTime: 0.6
        )
        guard let texture = renderer.makeOffscreenTexture(width: 48, height: 48, renderTarget: true) else {
            Issue.record("failed to allocate offscreen texture")
            return
        }
        let cost = renderer.encodeOffscreen(
            dots: frame.dots,
            designSize: design,
            texture: texture,
            tint: .darkFallback,
            waitUntilCompleted: true
        )
        #expect(cost.submitted)
        #expect(cost.completed)
        #expect(renderer.inFlightCount == 0)
    }

    @Test func mountedMacViewSubmitsAndCompletesDrawables() async throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        #expect(harness.view.unavailableReason == nil)
        #expect(harness.view.window != nil)
        #expect(harness.window.isVisible)
        #expect(harness.view.frame.origin == CGPoint(x: 18, y: 18))
        let metal = try #require(harness.view.layer as? CAMetalLayer)
        #expect(metal.device != nil)
        let completed = try await waitForMacCompletions(on: harness.view, minimum: 2)
        #expect(completed >= 2)
        #expect(harness.view.framesSubmitted >= completed)
        #expect(harness.view.isDriving)
    }

    @Test func hidingTheMacWindowStopsAndShowingRestartsWithoutLayout() async throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        _ = try await waitForMacCompletions(on: harness.view, minimum: 1)
        #expect(harness.view.isDriving)
        harness.window.orderOut(nil)
        try await waitUntilMacStopped(harness.view)
        #expect(!harness.view.isDriving)
        harness.window.makeKeyAndOrderFront(nil)
        harness.window.orderFrontRegardless()
        try await waitUntilMacDriving(harness.view)
        #expect(harness.view.isDriving)
    }

    @Test func hidingAMacAncestorStopsAndUnhidingRestartsWithoutLayout() async throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        _ = try await waitForMacCompletions(on: harness.view, minimum: 1)
        harness.container.isHidden = true
        try await waitUntilMacStopped(harness.view)
        #expect(!harness.view.isDriving)
        harness.container.isHidden = false
        #expect(harness.view.isDriving)
    }

    @Test func macAncestorAlphaStopsAndRestoresWithoutLayout() async throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        _ = try await waitForMacCompletions(on: harness.view, minimum: 1)
        harness.container.alphaValue = 0
        try await waitUntilMacStopped(harness.view)
        #expect(!harness.view.isDriving)
        harness.container.alphaValue = 1
        #expect(harness.view.isDriving)
    }

    @Test func macClipViewScrollStopsAndReentryRestartsWithoutLayout() async throws {
        let harness = try makeMacOrbClipHarness()
        defer { tearDown(harness) }
        _ = try await waitForMacCompletions(on: harness.view, minimum: 1)
        #expect(harness.view.isDriving)
        harness.clip?.scroll(to: NSPoint(x: 0, y: 240))
        try await waitUntilMacStopped(harness.view)
        #expect(!harness.view.isEffectivelyVisible)
        #expect(!harness.view.isDriving)
        harness.clip?.scroll(to: .zero)
        #expect(harness.view.isEffectivelyVisible)
        #expect(harness.view.isDriving)
    }

    @Test func macNestedClippedAncestorsUseAccumulatedIntersection() throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        outer.wantsLayer = true
        outer.clipsToBounds = true
        let inner = NSView(frame: NSRect(x: 0, y: 100, width: 80, height: 80))
        inner.wantsLayer = true
        inner.clipsToBounds = true
        harness.view.removeFromSuperview()
        harness.view.frame = NSRect(x: 0, y: -150, width: 16, height: 200)
        inner.addSubview(harness.view)
        outer.addSubview(inner)
        harness.container.addSubview(outer)
        harness.container.layoutSubtreeIfNeeded()
        #expect(!harness.view.isEffectivelyVisible)
    }

    @Test func freezeResumeFreezePresentsANewMacStillFrame() async throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        _ = try await waitForMacCompletions(on: harness.view, minimum: 1)
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

    @Test func hiddenFrozenMacTintUpdateDoesNotSubmitUntilReappearance() async throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        harness.view.forceReduceMotion = true
        let submitted = harness.view.framesSubmitted
        harness.view.isHidden = true
        harness.view.tintNSColor = .red
        #expect(harness.view.framesSubmitted == submitted)
        harness.view.isHidden = false
        #expect(harness.view.framesSubmitted == submitted + 1)
        #expect(!harness.view.isDriving)
    }

    @Test func equivalentFrozenMacTintDoesNotResubmit() throws {
        let harness = try makeMacOrbHarness()
        defer { tearDown(harness) }
        harness.view.forceReduceMotion = true
        harness.view.tintNSColor = .red
        let submitted = harness.view.framesSubmitted
        harness.view.tintNSColor = .red
        #expect(harness.view.framesSubmitted == submitted)
    }

    @Test func removingTheMacViewStopsTheClock() throws {
        let harness = try makeMacOrbHarness()
        #expect(harness.view.window != nil)
        harness.view.removeFromSuperview()
        #expect(!harness.view.isDriving)
        #expect(harness.view.window == nil)
        tearDown(harness)
    }
}

@MainActor
private struct MacOrbHarness {
    let window: NSWindow
    let container: NSView
    let view: ThinkingOrbMetalView
    var clip: NSClipView?
}

@MainActor
private func makeMacOrbHarness() throws -> MacOrbHarness {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.isOpaque = false
    window.backgroundColor = .black
    if let screen = NSScreen.main ?? NSScreen.screens.first {
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24))
    }
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
    content.wantsLayer = true
    window.contentView = content
    let view = ThinkingOrbMetalView(style: .working, sizeClass: .workingCompact)
    view.frame = NSRect(x: 18, y: 18, width: 16, height: 16)
    view.tintNSColor = .white
    view.isDarkBackground = true
    content.addSubview(view)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    content.layoutSubtreeIfNeeded()
    view.layout()
    return MacOrbHarness(window: window, container: content, view: view, clip: nil)
}

@MainActor
private func makeMacOrbClipHarness() throws -> MacOrbHarness {
    let harness = try makeMacOrbHarness()
    let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
    clip.wantsLayer = true
    clip.postsBoundsChangedNotifications = true
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 480))
    document.wantsLayer = true
    clip.documentView = document
    harness.view.removeFromSuperview()
    document.addSubview(harness.view)
    harness.view.frame = NSRect(x: 18, y: 18, width: 16, height: 16)
    harness.container.addSubview(clip)
    clip.scroll(to: .zero)
    harness.container.layoutSubtreeIfNeeded()
    harness.view.layout()
    return MacOrbHarness(
        window: harness.window,
        container: harness.container,
        view: harness.view,
        clip: clip
    )
}

@MainActor
private func tearDown(_ harness: MacOrbHarness) {
    harness.view.stopAndDismantle()
    harness.view.removeFromSuperview()
    harness.window.orderOut(nil)
    harness.window.close()
}

@MainActor
private func waitForMacCompletions(on view: ThinkingOrbMetalView, minimum: Int) async throws -> Int {
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
    throw MacOrbHostError.timeout(macTimeoutMessage(view, expected: "framesCompleted >= \(minimum)"))
}

@MainActor
private func waitUntilMacStopped(_ view: ThinkingOrbMetalView) async throws {
    let deadline = ContinuousClock.now + .seconds(1.2)
    while ContinuousClock.now < deadline {
        if !view.isDriving { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(16))
    }
    if view.isDriving {
        throw MacOrbHostError.timeout(macTimeoutMessage(view, expected: "isDriving == false"))
    }
}

@MainActor
private func waitUntilMacDriving(_ view: ThinkingOrbMetalView) async throws {
    let deadline = ContinuousClock.now + .seconds(1.2)
    while ContinuousClock.now < deadline {
        if view.isDriving { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(16))
    }
    if !view.isDriving {
        throw MacOrbHostError.timeout(macTimeoutMessage(view, expected: "isDriving == true"))
    }
}

@MainActor
private func macTimeoutMessage(_ view: ThinkingOrbMetalView, expected: String) -> String {
    let metal = view.layer as? CAMetalLayer
    let window = view.window
    return """
    expected \(expected); driving=\(view.isDriving) submitted=\(view.framesSubmitted) \
    completed=\(view.framesCompleted) skipped=\(view.framesSkipped) failed=\(view.framesFailed) \
    visible=\(view.isEffectivelyVisible) windowVisible=\(window?.isVisible ?? false) \
    miniaturized=\(window?.isMiniaturized ?? true) occlusion=\(window?.occlusionState.rawValue ?? 0) \
    drawable=\(String(describing: metal?.drawableSize)) device=\(metal?.device != nil) \
    unavailable=\(view.unavailableReason ?? "nil")
    """
}

private enum MacOrbHostError: Error, CustomStringConvertible {
    case timeout(String)

    var description: String {
        switch self {
        case .timeout(let detail): detail
        }
    }
}
