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
        let design = ThinkingOrbSizeClass.workingCompact.designSize
        let frame = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: design,
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
            designSize: design,
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
            designSize: design,
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
        for style in [ThinkingOrbStyle.searching, .composing, .breathing] {
            let harness = try makeOrbHarness(style: style, side: style.isVoiceReactive ? 44 : 16)
            defer { tearDown(harness) }
            _ = try await waitForCompletions(on: harness.view, minimum: 1)
            let liveSubmitted = harness.view.framesSubmitted
            harness.view.forceReduceMotion = true
            #expect(!harness.view.isDriving)
            #expect(harness.view.framesSubmitted == liveSubmitted + 1)
            #expect(harness.view.lastPresentedGeometryTime == ThinkingOrbDisplayPolicy.reduceMotionTime)
            #expect(harness.view.lastPresentedSpectrum == .zero)
            let frozenSubmitted = harness.view.framesSubmitted
            harness.view.voiceSpectrum = VoiceSpectrumFrame(bands: .one, flux: 30)
            try await Task.sleep(for: .milliseconds(50))
            #expect(harness.view.framesSubmitted == frozenSubmitted, "Neither calm-sea time nor speech animates Reduce Motion")

            harness.view.forceReduceMotion = false
            #expect(harness.view.isDriving)
        }
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
            voiceSpectrum: VoiceSpectrumFrame(level: 0.2),
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
            voiceSpectrum: VoiceSpectrumFrame(level: 0.9),
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 44,
            animated: false
        )
        #expect(orb.framesSubmitted == submitted)
        #expect(orb.voiceSpectrum.level == 0.9)
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

    @Test func mountedDictationOrbConsumesLiveAudioWithoutSnappingOnRelease() async throws {
        let harness = try makeOrbHarness(style: .composing, side: 44)
        defer { tearDown(harness) }
        let renderer = try #require(harness.view.rendererForTests)
        _ = try await waitForCompletions(on: harness.view, minimum: 2)
        #expect(harness.view.isDriving)

        harness.view.voiceSpectrum = .zero
        _ = try await waitForCompletions(
            on: harness.view,
            minimum: harness.view.framesCompleted + 2
        )
        #expect(harness.view.lastPresentedSpectrum.level < 0.03)

        harness.view.voiceSpectrum = VoiceSpectrumFrame(level: 0.35, bands: SIMD8(0.8, 0.4, 0, 0, 0.3, 0, 0, 0))
        let voice = try await waitUntilPresentedAudio(on: harness.view, atLeast: 0.12)
        #expect(harness.view.isDriving)
        #expect(harness.view.voiceSpectrum.level == 0.35)
        #expect(harness.view.lastPresentedSpectrum.bands[0] > 0.4)
        let phase = harness.view.lastPresentedGeometryTime
        let quietShot = try renderOrbPixels(
            renderer: renderer,
            style: .composing,
            sizeClass: .dictationStandard,
            size: 44,
            geometryTime: phase,
            voiceSpectrum: .zero
        )
        let voiceShot = try renderOrbPixels(
            renderer: renderer,
            style: .composing,
            sizeClass: .dictationStandard,
            size: 44,
            geometryTime: phase,
            voiceSpectrum: harness.view.lastPresentedSpectrum
        )
        let changed = quietShot.changedCount(vs: voiceShot, minChannelDelta: 40)
        print(
            "mounted composing 44pt identical-phase voiceChanged=\(changed)px t=\(phase) presentedAudio=\(voice)"
        )
        #expect(
            changed >= 180,
            "mounted composing 44pt identical-phase voice changed \(changed)px at t=\(phase) audio=\(voice)"
        )

        harness.view.voiceSpectrum = .zero
        _ = try await waitForCompletions(
            on: harness.view,
            minimum: harness.view.framesCompleted + 1
        )
        #expect(harness.view.lastPresentedSpectrum.bands[0] > 0.1, "release must ease, not snap")
    }
}

@Suite("Thinking orb pixel motion")
struct ThinkingOrbPixelMotionTests {
    @Test func voiceOnVersusQuietAtIdenticalPhaseChangesPixels() throws {
        let built = ThinkingOrbMetalRenderer.make()
        guard let renderer = built.renderer else {
            Issue.record("Metal unavailable: \(built.unavailableReason ?? "unknown")")
            return
        }
        var smoother = VoiceSpectrumSmoother()
        var voice = VoiceSpectrumFrame.zero
        let input = VoiceSpectrumFrame(level: 0.2, bands: SIMD8(0.8, 0.2, 0, 0, 0.2, 0, 0, 0))
        for _ in 0..<60 {
            voice = smoother.step(raw: input, dt: 1.0 / 60.0)
        }
        for style in [ThinkingOrbStyle.composing, .breathing] {
            for sizeClass in [ThinkingOrbSizeClass.dictationExpanded, .dictationStandard] {
                let size = sizeClass.designSize
                let speed = ThinkingOrbPresets.resolve(style, sizeClass).speed
                let t0 = 0.7 * speed
                let quiet0 = try renderOrbPixels(
                    renderer: renderer,
                    style: style,
                    sizeClass: sizeClass,
                    size: size,
                    geometryTime: t0,
                    voiceSpectrum: .zero
                )
                let quiet1 = try renderOrbPixels(
                    renderer: renderer,
                    style: style,
                    sizeClass: sizeClass,
                    size: size,
                    geometryTime: 1.7 * speed,
                    voiceSpectrum: .zero
                )
                let speaking = try renderOrbPixels(
                    renderer: renderer,
                    style: style,
                    sizeClass: sizeClass,
                    size: size,
                    geometryTime: t0,
                    voiceSpectrum: voice
                )
                let idleChanged = quiet0.changedCount(vs: quiet1, minChannelDelta: 40)
                let voiceChanged = quiet0.changedCount(vs: speaking, minChannelDelta: 40)
                print(
                    "pixels \(style.rawValue) \(Int(size))pt@3x idleChanged=\(idleChanged) identical-phase voiceChanged=\(voiceChanged) opaque=\(quiet0.opaqueCount())/\(speaking.opaqueCount())"
                )
                if style == .composing {
                    #expect(idleChanged > 0 && idleChanged < voiceChanged,
                            "Composing's calm sea must be visible but gentler than speech: idle=\(idleChanged), voice=\(voiceChanged)")
                } else {
                    #expect(idleChanged == 0,
                            "Breathing stays quiet: \(Int(size))pt idle changed \(idleChanged)px")
                }
                #expect(
                    voiceChanged >= 180,
                    "\(style.rawValue) \(Int(size))pt modest voice changed \(voiceChanged)px"
                )
                #expect(quiet0.opaqueCount() > 40)
                #expect(quiet1.opaqueCount() > 40)
                #expect(speaking.opaqueCount() > 40)
            }
        }
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
                voiceSpectrum: VoiceSpectrumFrame(level: 0.4),
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

    @Test func recordingForwardsLiveAudioIntoTheOrbHost() {
        withRestoredDictationStyle {
            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.composing)
            let chrome = MicButtonChromeView()
            chrome.apply(
                isRecording: true,
                isProcessing: false,
                voiceSpectrum: VoiceSpectrumFrame(level: 0.42, bands: SIMD8(0.8, 0, 0.3, 0, 0.4, 0, 0, 0)),
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 44,
                animated: false
            )
            let orb = firstSubview(of: chrome, type: ThinkingOrbMetalView.self)
            #expect(orb?.isHidden == false)
            #expect(orb?.voiceSpectrum == VoiceSpectrumFrame(level: 0.42, bands: SIMD8(0.8, 0, 0.3, 0, 0.4, 0, 0, 0)))
            let palette = ThemeRuntimeState.currentPalette()
            #expect(orb?.accentUIColors == [palette.blue, palette.cyan, palette.purple, palette.orange].map { UIColor($0) })

            chrome.apply(
                isRecording: true,
                isProcessing: false,
                voiceSpectrum: VoiceSpectrumFrame(level: 0.18),
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 44,
                animated: false
            )
            #expect(orb?.voiceSpectrum.level == 0.18)
        }
    }

    @Test func swiftUIRecordingPresentationFeedsTheOrbHost() throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            throw TestHostError.missingScene
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        let host = UIHostingController(
            rootView: MicButtonLabel(
                isRecording: true,
                isProcessing: false,
                voiceSpectrum: VoiceSpectrumFrame(level: 0.51, bands: SIMD8(0, 0, 0.2, 0, 0.7, 0, 0, 0)),
                languageLabel: "EN",
                accentColor: .blue,
                engineBadge: .onDevice,
                diameter: 44,
                dictationStyle: .composing
            )
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let orb = firstSubview(of: host.view, type: ThinkingOrbMetalView.self)
        #expect(orb?.voiceSpectrum == VoiceSpectrumFrame(level: 0.51, bands: SIMD8(0, 0, 0.2, 0, 0.7, 0, 0, 0)))
        window.rootViewController = nil
        window.isHidden = true
    }

    @Test func preparingDoesNotFeedVoiceIntoTheOrb() {
        let chrome = MicButtonChromeView()
        chrome.apply(
            isRecording: false,
            isProcessing: false,
            voiceSpectrum: VoiceSpectrumFrame(level: 0.9, bands: .one),
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 44,
            animated: false,
            isPreparing: true
        )
        let orb = firstSubview(of: chrome, type: ThinkingOrbMetalView.self)
        #expect(orb?.isHidden == false)
        #expect(orb?.voiceSpectrum == .zero)
        #expect(chrome.intrinsicContentSize == CGSize(width: 44, height: 44))
        let labels = allLabels(in: chrome).filter { !$0.isHidden }
        #expect(!labels.contains { $0.text == "EN" })
    }

    @Test func uikitChromeKeepsHitTargetAndDoesNotGrow() {
        let chrome = MicButtonChromeView()
        chrome.apply(
            isRecording: true,
            isProcessing: false,
            voiceSpectrum: VoiceSpectrumFrame(level: 0.4),
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
            voiceSpectrum: VoiceSpectrumFrame(level: 1),
            languageLabel: "EN",
            accentColor: .systemBlue,
            engineBadge: .onDevice,
            diameter: 32,
            animated: false
        )
        #expect(chrome.intrinsicContentSize == CGSize(width: 32, height: 32))
    }

    @Test func orbListeningRemovesTheBackgroundDiscAndLegacyKeepsIt() {
        withRestoredDictationStyle {
            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.composing)
            let composing = MicButtonChromeView()
            composing.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            composing.apply(
                isRecording: true,
                isProcessing: false,
                voiceSpectrum: VoiceSpectrumFrame(level: 0.3),
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 44,
                animated: false
            )
            composing.layoutIfNeeded()
            #expect(micFillIsClear(composing))

            composing.apply(
                isRecording: false,
                isProcessing: false,
                voiceSpectrum: VoiceSpectrumFrame(level: 0.9),
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 44,
                animated: false,
                isPreparing: true
            )
            composing.layoutIfNeeded()
            #expect(micFillIsClear(composing))
            #expect(composing.intrinsicContentSize == CGSize(width: 44, height: 44))

            composing.apply(
                isRecording: false,
                isProcessing: false,
                voiceSpectrum: .zero,
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 44,
                animated: false
            )
            composing.layoutIfNeeded()
            #expect(!micFillIsClear(composing))

            composing.apply(
                isRecording: false,
                isProcessing: true,
                voiceSpectrum: .zero,
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 44,
                animated: false
            )
            composing.layoutIfNeeded()
            #expect(!micFillIsClear(composing))

            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.breathing)
            composing.apply(
                isRecording: true,
                isProcessing: false,
                voiceSpectrum: VoiceSpectrumFrame(level: 0.2),
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 32,
                animated: false
            )
            composing.layoutIfNeeded()
            #expect(micFillIsClear(composing))
            #expect(composing.intrinsicContentSize == CGSize(width: 32, height: 32))

            AppPreferenceStore.Appearance.setDictationIndicatorStyle(.ring)
            composing.apply(
                isRecording: true,
                isProcessing: false,
                voiceSpectrum: VoiceSpectrumFrame(level: 0.4),
                languageLabel: "EN",
                accentColor: .systemBlue,
                engineBadge: .onDevice,
                diameter: 44,
                animated: false
            )
            composing.layoutIfNeeded()
            #expect(!micFillIsClear(composing))
        }
    }

    @Test func swiftUIListeningOmitsTheFillDiscWhenShowingAnOrb() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Oppi/Features/Chat/Composer/MicButtonLabel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("if !showsOrb {"))
        #expect(source.contains("Circle().fill(Color.themeBgHighlight)"))
    }
}

@Suite("Working indicator metal size")
@MainActor
struct WorkingIndicatorMetalSizeTests {
    @Test func nativeMetalStyleKeepsTheTwentyPointSpinner() {
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
        #expect(metal?.bounds.size == CGSize(width: 20, height: 20))
        #expect(metal?.isHidden == false)
        let palette = ThemeRuntimeState.currentPalette()
        #expect(metal?.accentUIColors == [palette.blue, palette.cyan, palette.purple, palette.orange].map { UIColor($0) })
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
private func waitUntilPresentedAudio(
    on view: ThinkingOrbMetalView,
    atLeast minimum: Float
) async throws -> Float {
    let deadline = ContinuousClock.now + .seconds(1.2)
    while ContinuousClock.now < deadline {
        if view.lastPresentedSpectrum.level >= minimum {
            return view.lastPresentedSpectrum.level
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(16))
    }
    throw TestHostError.timeout(
        orbTimeoutMessage(view, expected: "lastPresentedAudio >= \(minimum)")
        + "; presentedAudio=\(view.lastPresentedSpectrum.level) input=\(view.voiceSpectrum)"
    )
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
        voiceSpectrum: VoiceSpectrumFrame(level: 0.35),
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

private func micFillView(in chrome: MicButtonChromeView) -> UIView? {
    chrome.subviews.first { view in
        !(view is ThinkingOrbMetalView)
            && !(view is UIImageView)
            && !(view is UILabel)
            && !(view is UIActivityIndicatorView)
    }
}

private func micFillIsClear(_ chrome: MicButtonChromeView) -> Bool {
    guard let fill = micFillView(in: chrome) else { return false }
    if fill.isHidden { return true }
    var alpha: CGFloat = 1
    fill.backgroundColor?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
    return alpha < 0.02
}

private func withRestoredDictationStyle(_ body: () -> Void) {
    let key = AppPreferenceStore.Appearance.dictationIndicatorStyleKey
    let original = UserDefaults.standard.object(forKey: key)
    defer {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    body()
}

private struct OrbPixelShot {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func opaqueCount(minAlpha: UInt8 = 24) -> Int {
        var count = 0
        var index = 3
        while index < bytes.count {
            if bytes[index] >= minAlpha { count += 1 }
            index += 4
        }
        return count
    }

    func changedCount(vs other: OrbPixelShot, minChannelDelta: Int) -> Int {
        let count = min(bytes.count, other.bytes.count)
        var changed = 0
        var index = 0
        while index < count {
            let delta = max(
                abs(Int(bytes[index]) - Int(other.bytes[index])),
                abs(Int(bytes[index + 1]) - Int(other.bytes[index + 1])),
                abs(Int(bytes[index + 2]) - Int(other.bytes[index + 2])),
                abs(Int(bytes[index + 3]) - Int(other.bytes[index + 3]))
            )
            if delta >= minChannelDelta { changed += 1 }
            index += 4
        }
        return changed
    }
}

private func renderOrbPixels(
    renderer: ThinkingOrbMetalRenderer,
    style: ThinkingOrbStyle,
    sizeClass: ThinkingOrbSizeClass,
    size: Double,
    geometryTime: Double,
    voiceSpectrum: VoiceSpectrumFrame,
    scale: Int = 3
) throws -> OrbPixelShot {
    let width = max(1, Int((size * Double(scale)).rounded()))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: width,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
        throw TestHostError.timeout("failed shared orb texture")
    }
    let frame = ThinkingOrbGeometry.frame(
        style: style,
        sizeClass: sizeClass,
        size: size,
        geometryTime: geometryTime,
        voiceSpectrum: voiceSpectrum,
        zSorted: false
    )
    let cost = renderer.encodeOffscreen(
        dots: frame.dots,
        designSize: size,
        texture: texture,
        tint: .darkFallback,
        waitUntilCompleted: true
    )
    guard cost.completed else {
        throw TestHostError.timeout(cost.errorDescription ?? "orb encode did not complete")
    }
    var bytes = [UInt8](repeating: 0, count: width * width * 4)
    bytes.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        texture.getBytes(
            base,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, width),
            mipmapLevel: 0
        )
    }
    return OrbPixelShot(width: width, height: width, bytes: bytes)
}
