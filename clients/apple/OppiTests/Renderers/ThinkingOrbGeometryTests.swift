import Foundation
import Testing
@testable import Oppi

@Suite("ThinkingOrbGeometry")
struct ThinkingOrbGeometryTests {
    private let styles: [ThinkingOrbStyle] = [.composing, .breathing]
    private let sizes: [ThinkingOrbSizeClass] = [.dictationExpanded, .dictationStandard]

    private func frame(_ style: ThinkingOrbStyle, _ size: ThinkingOrbSizeClass,
                       _ voice: VoiceSpectrumFrame = .zero, time: Double = 0.6) -> ThinkingOrbFrame {
        ThinkingOrbGeometry.frame(style: style, sizeClass: size, size: size.designSize,
                                  geometryTime: time, voiceSpectrum: voice, zSorted: false)
    }

    @Test func dictationInputHoldsAStandingShapeAtDistantTimes() {
        let input = VoiceSpectrumFrame(level: 1, bands: SIMD8(0.8, 0.4, 0.2, 0.7, 0.9, 0, 0, 0))
        for style in styles {
            for size in sizes {
                let first = frame(style, size, input)
                let later = frame(style, size, input, time: 120)
                #expect(displacements(first, later).allSatisfy { $0 == .zero })
                #expect(zip(first.dots, later.dots).allSatisfy { $0.r == $1.r })
            }
        }
    }

    @Test func zeroBandsStayAtIdleRegardlessOfRMSAndTime() {
        for style in styles {
            for size in sizes {
                let idle = frame(style, size)
                for time in [0.0, 1.7, 120.0] {
                    let later = frame(style, size, VoiceSpectrumFrame(level: 1), time: time)
                    #expect(displacements(idle, later).allSatisfy { $0 == .zero })
                    #expect(zip(idle.dots, later.dots).allSatisfy { $0.r == $1.r })
                    #expect(zip(idle.dots, later.dots).allSatisfy { abs($0.a - $1.a) <= 0.100001 })
                }
            }
        }
    }

    @Test func lowAndHighBandsHaveDifferentDisplacementPatternsOnBothStyles() {
        for style in styles {
            for size in sizes {
                let idle = frame(style, size)
                let low = frame(style, size, VoiceSpectrumFrame(bands: SIMD8(1, 0, 0, 0, 0, 0, 0, 0)))
                let high = frame(style, size, VoiceSpectrumFrame(bands: SIMD8(0, 0, 0, 0, 1, 0, 0, 0)))
                let lowDelta = displacements(idle, low)
                let highDelta = displacements(idle, high)
                #expect(lowDelta != highDelta)
                #expect(lowDelta.contains { length($0) > 1 })
                // The band keeps treble ripples small; the sphere retains its larger roughness.
                #expect(highDelta.contains { length($0) > (style == .composing ? 0.25 : 1) })
                let dotProduct = zip(lowDelta, highDelta).reduce(0.0) { sum, pair in
                    sum + pair.0.x * pair.1.x + pair.0.y * pair.1.y + pair.0.z * pair.1.z
                }
                let energy = sqrt(lowDelta.reduce(0) { $0 + length($1) * length($1) }
                    * highDelta.reduce(0) { $0 + length($1) * length($1) })
                #expect(abs(dotProduct / energy) < 0.6, "Not just a rescaled loudness deformation")
            }
        }
    }

    @Test func sameBandsKeepCircularBandDistinctFromRadialSphere() {
        let voice = VoiceSpectrumFrame(bands: SIMD8(0.6, 0.3, 0.5, 0.2, 0.4, 0, 0, 0))
        for size in sizes {
            let band = frame(.composing, size, voice)
            let sphere = frame(.breathing, size, voice)
            #expect(band.dots != sphere.dots)
            #expect(band.dots.allSatisfy { projectedRadius($0, size.designSize) > size.designSize * 0.18 })
            #expect(sphere.dots.contains { projectedRadius($0, size.designSize) < size.designSize * 0.1 })
            let radius = size.designSize * 0.39
            let idleSphere = frame(.breathing, size)
            #expect(displacements(idleSphere, sphere).contains { length($0) > 0.5 })
            for (idle, live) in zip(idleSphere.dots, sphere.dots) {
                let a = centered(idle, size.designSize)
                let b = centered(live, size.designSize)
                #expect(length(a / length(a) - b / length(b)) < 1e-10)
                #expect(abs(length(b) - 0.94 * radius) <= 0.36 * radius + 1e-9)
            }
        }
    }

    @Test func everyBandHasItsOwnModeAndUnusedLanesAreIgnored() {
        for style in styles {
            let idle = frame(style, .dictationStandard)
            var patterns: [[SIMD3<Double>]] = []
            for band in 0..<5 {
                var input = VoiceSpectrumFrame.zero
                input.bands[band] = 1
                let delta = displacements(idle, frame(style, .dictationStandard, input))
                #expect(delta.contains { length($0) > (style == .composing ? 0.3 : 0.5) })
                #expect(!patterns.contains(delta))
                patterns.append(delta)
            }
            let unused = VoiceSpectrumFrame(bands: SIMD8(0, 0, 0, 0, 0, 1, 1, 1))
            #expect(idle.dots == frame(style, .dictationStandard, unused).dots)
        }
    }

    @Test func fluxChangesBandDotRadiusAndSphereAccentButNeverPositions() {
        for style in styles {
            let idle = frame(style, .dictationStandard)
            let onset = frame(style, .dictationStandard, VoiceSpectrumFrame(flux: 30))
            #expect(displacements(idle, onset).allSatisfy { $0 == .zero })
            if style == .composing {
                #expect(zip(idle.dots, onset.dots).contains { $0.r < $1.r })
            } else {
                #expect(zip(idle.dots, onset.dots).allSatisfy { $0.r == $1.r && $0.accent < $1.accent })
            }
        }
    }

    @Test func composingQuietIsConcentricCircularLanesWithDepth() {
        for (size, lanes, segments) in bandMeshes {
            let dots = frame(.composing, size).dots
            #expect(dots.allSatisfy {
                let radius = projectedRadius($0, size.designSize)
                return radius >= size.designSize * 0.22 && radius <= size.designSize * 0.36
            }, "Quiet must leave an open center and a round outer envelope")
            #expect(dots.count == lanes * segments, "Only annular lanes, no interior sphere ghosts")
            guard dots.count == lanes * segments else { continue }
            for lane in 0..<lanes {
                let ring = Array(dots[(lane * segments)..<((lane + 1) * segments)])
                let radii = ring.map { projectedRadius($0, size.designSize) }
                #expect((radii.max() ?? 0) - (radii.min() ?? 0) < 1e-9)
                #expect(radii.allSatisfy { $0 >= size.designSize * 0.22 && $0 <= size.designSize * 0.36 })
                let centerX = ring.map(\.x).reduce(0, +) / Double(segments)
                let centerY = ring.map(\.y).reduce(0, +) / Double(segments)
                #expect(abs(centerX - size.designSize / 2) < 1e-9)
                #expect(abs(centerY - size.designSize / 2) < 1e-9)
            }
            #expect(Set(dots.map(\.z)).count > 1, "Depth must not require tilting the circle")
            #expect(Set(dots.map(\.white)).count > 1)
        }
    }

    @Test func composingSharesRadialTravelWithoutChangingAnglesOrCrossingLanes() {
        for (size, lanes, segments) in bandMeshes {
            let idle = frame(.composing, size).dots
            guard idle.count == lanes * segments else {
                Issue.record("Unexpected band topology: \(idle.count)")
                continue
            }
            for voice in bandCubeSamples {
                let live = frame(.composing, size, voice).dots
                #expect(live.count == idle.count)
                guard live.count == idle.count else { continue }
                let angleErrors = zip(idle, live).map { a, b in
                    let c = size.designSize / 2
                    return abs(ThinkingOrbGeometry.angleDelta(atan2(a.y - c, a.x - c), atan2(b.y - c, b.x - c)))
                }
                #expect(angleErrors.allSatisfy { $0 < 1e-10 })
                for segment in 0..<segments {
                    let travel = projectedRadius(live[segment], size.designSize) - projectedRadius(idle[segment], size.designSize)
                    #expect(travel >= -0.041 * size.designSize && travel <= 0.119 * size.designSize)
                    for lane in 1..<lanes {
                        let index = lane * segments + segment
                        let gap = projectedRadius(live[index], size.designSize) - projectedRadius(live[index - segments], size.designSize)
                        let idleGap = projectedRadius(idle[index], size.designSize) - projectedRadius(idle[index - segments], size.designSize)
                        #expect(gap > 0 && abs(gap - idleGap) < 1e-9, "Shared deformation must preserve lane thickness")
                    }
                }
                // Even angular modes keep opposing points centered, including mixed spectra.
                for lane in 0..<lanes {
                    for segment in 0..<(segments / 2) {
                        let a = live[lane * segments + segment]
                        let b = live[lane * segments + segment + segments / 2]
                        #expect(abs(a.x + b.x - size.designSize) < 1e-9)
                        #expect(abs(a.y + b.y - size.designSize) < 1e-9)
                    }
                }
            }
        }
    }

    @Test func composingCompleteDotsStayInCanvasAcrossTheBandCube() {
        for size in sizes + [.workingCompact, .workingPreview] {
            for voice in bandCubeSamples {
                let dots = ThinkingOrbGeometry.frame(
                    style: .composing, sizeClass: size, size: size.designSize,
                    geometryTime: 120, voiceSpectrum: voice
                ).dots
                #expect(!dots.isEmpty)
                #expect(dots.allSatisfy {
                    $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.r.isFinite
                        && $0.x - $0.r >= 0 && $0.y - $0.r >= 0
                        && $0.x + $0.r <= size.designSize && $0.y + $0.r <= size.designSize
                })
            }
        }
    }

    @Test func composingBassSwellsWhileTrebleMakesSmallerRipples() {
        for size in sizes {
            let idle = frame(.composing, size).dots
            let bass = frame(.composing, size, VoiceSpectrumFrame(bands: SIMD8(1, 0, 0, 0, 0, 0, 0, 0))).dots
            let treble = frame(.composing, size, VoiceSpectrumFrame(bands: SIMD8(0, 0, 0, 0, 1, 0, 0, 0))).dots
            let bassTravel = zip(idle, bass).map { projectedRadius($1, size.designSize) - projectedRadius($0, size.designSize) }
            let trebleTravel = zip(idle, treble).map { projectedRadius($1, size.designSize) - projectedRadius($0, size.designSize) }
            #expect(bassTravel.allSatisfy { $0 > size.designSize * 0.04 && $0 < size.designSize * 0.06 })
            #expect(trebleTravel.contains { $0 > size.designSize * 0.007 })
            #expect(trebleTravel.contains { $0 < -size.designSize * 0.007 })
            #expect(trebleTravel.allSatisfy { abs($0) < size.designSize * 0.015 })
        }
    }

    @Test func dictationReleaseSettlesBackToQuietGeometry() {
        for style in styles {
            for size in sizes {
                var smoother = VoiceSpectrumSmoother()
                _ = smoother.step(raw: VoiceSpectrumFrame(bands: .one, flux: 30), dt: 1)
                let release = smoother.step(raw: .zero, dt: 1.0 / 60)
                #expect(displacements(frame(style, size), frame(style, size, release)).contains { length($0) > 0.5 })
                let settled = smoother.step(raw: .zero, dt: 3)
                let quiet = frame(style, size)
                let final = frame(style, size, settled, time: 120)
                #expect(displacements(quiet, final).allSatisfy { length($0) < 0.00001 })
                #expect(zip(quiet.dots, final.dots).allSatisfy { abs($0.r - $1.r) < 0.00001 })
            }
        }
    }

    private var bandMeshes: [(ThinkingOrbSizeClass, Int, Int)] {
        [(.dictationExpanded, 4, 32), (.dictationStandard, 5, 44)]
    }

    private var bandCubeSamples: [VoiceSpectrumFrame] {
        // All corners plus intermediate gains; geometry is affine in the five bands.
        (0..<32).flatMap { mask in
            [Float(0.25), 0.5, 1].map { gain in
                var bands = SIMD8<Float>.zero
                for k in 0..<5 where mask & (1 << k) != 0 { bands[k] = gain }
                return VoiceSpectrumFrame(bands: bands, flux: 30)
            }
        }
    }

    @Test func breathingIdleRadiusIsFixedAndDisplacementIsBounded() {
        for size in sizes {
            let radius = size.designSize * 0.39
            for dot in frame(.breathing, size).dots {
                #expect(abs(radialLength(dot, size.designSize) - 0.94 * radius) < 1e-9)
            }
            for dot in frame(.breathing, size, VoiceSpectrumFrame(bands: .one)).dots {
                #expect(abs(radialLength(dot, size.designSize) - 0.94 * radius) <= 0.36 * radius + 1e-9)
            }
        }
    }

    @Test func breathingRenderedDotBoundsStayInsideTheCanvasForEveryBandCombination() {
        // Every corner of the five-band input cube plus intermediate levels.
        // Radius is input-independent; radial displacement is clamped linear,
        // so the corners include each material direction's extreme excursion.
        for size in sizes {
            for mask in 0..<32 {
                for gain: Float in [0.25, 0.5, 1] {
                    var bands = SIMD8<Float>.zero
                    for k in 0..<5 where mask & (1 << k) != 0 { bands[k] = gain }
                    // Use the finalized (radius-minimum, depth-sorted) path
                    // consumed by the live Metal view, not raw builder dots.
                    let result = ThinkingOrbGeometry.frame(
                        style: .breathing, sizeClass: size, size: size.designSize,
                        geometryTime: 0.6, voiceSpectrum: VoiceSpectrumFrame(bands: bands, flux: 30)
                    )
                    let outside = result.dots.filter {
                        $0.x - $0.r < 0 || $0.y - $0.r < 0
                            || $0.x + $0.r > size.designSize
                            || $0.y + $0.r > size.designSize
                    }
                    #expect(outside.isEmpty, "\(size.designSize)pt mask=\(mask) gain=\(gain): \(outside.count) clipped dots")
                }
            }
        }
    }

    @Test func fiveStylesProduceBoundedFiniteDots() {
        #expect(ThinkingOrbStyle.allCases == [.working, .searching, .solving, .composing, .breathing])
        for style in ThinkingOrbStyle.allCases {
            let size: ThinkingOrbSizeClass = style.isVoiceReactive ? .dictationStandard : .workingCompact
            let result = frame(style, size, VoiceSpectrumFrame(level: 1, bands: .one, flux: 30))
            #expect(!result.dots.isEmpty)
            for dot in result.dots {
                #expect(dot.x.isFinite && dot.y.isFinite && dot.z.isFinite)
                #expect(dot.r.isFinite && dot.r > 0)
                #expect(dot.a.isFinite && dot.a >= 0 && dot.a <= 1)
                #expect(dot.accent >= 0 && dot.accent <= 1)
                #expect(dot.palette >= 0 && dot.palette <= 3)
                #expect(dot.x >= -1 && dot.x <= size.designSize + 1)
                #expect(dot.y >= -1 && dot.y <= size.designSize + 1)
            }
        }
    }

    @Test func workingStylesIgnoreAllSpectrumFieldsAndKeepTheirClock() {
        for style in [ThinkingOrbStyle.working, .searching, .solving] {
            let quiet = frame(style, .workingCompact)
            #expect(quiet.dots == frame(style, .workingCompact, VoiceSpectrumFrame(level: 1, bands: .one, flux: 90)).dots)
            #expect(quiet.dots != frame(style, .workingCompact, time: 8).dots)
        }
    }

    @Test func compactWorkingCountsAndTimeScaleStayUnchanged() {
        #expect(frame(.working, .workingCompact).dots.count < 80)
        #expect(ThinkingOrbSizeClass.workingCompact.designSize == 20)
        #expect(ThinkingOrbSizeClass.workingPreview.designSize == 20)
        #expect(ThinkingOrbSizeClass.working(side: 20) == .workingCompact)
        #expect(ThinkingOrbSizeClass.working(side: 24) == .workingPreview)
        #expect(ThinkingOrbPresets.workingMotionScale == 0.5)
        for size in [ThinkingOrbSizeClass.workingCompact, .workingPreview] {
            #expect(ThinkingOrbPresets.resolve(.working, size).speed == 3.9 * 0.5)
            #expect(ThinkingOrbPresets.resolve(.searching, size).speed == 2.665 * 0.5)
            #expect(ThinkingOrbPresets.resolve(.solving, size).speed == 1.95 * 0.5)
        }
    }

    @Test func allStylesKeepThemeAccentsAndDepthShading() {
        for style in ThinkingOrbStyle.allCases {
            let dots = frame(style, style.isVoiceReactive ? .dictationStandard : .workingCompact).dots
            #expect(dots.contains { $0.accent > 0.2 })
            #expect(Set(dots.map(\.white)).count > 1)
        }
    }
}

@Suite("VoiceSpectrumSmoother")
struct VoiceSpectrumSmootherTests {
    @Test func thirtyAndSixtyHzAgreeOnAttackAndReleaseForEachBand() {
        let input = VoiceSpectrumFrame(level: 0.7, bands: SIMD8(0.2, 0.4, 0.6, 0.8, 1, 0, 0, 0), flux: 25)
        var at30 = VoiceSpectrumSmoother()
        var at60 = VoiceSpectrumSmoother()
        for raw in [input, .zero] {
            for _ in 0..<12 { _ = at30.step(raw: raw, dt: 1.0 / 30) }
            for _ in 0..<24 { _ = at60.step(raw: raw, dt: 1.0 / 60) }
            for k in 0..<8 { #expect(abs(at30.current.bands[k] - at60.current.bands[k]) < 1e-6) }
            #expect(abs(at30.current.flux - at60.current.flux) < 1e-5)
        }
    }

    @Test func attackReleaseAndSilenceAreIndependentOfRMS() {
        var smoother = VoiceSpectrumSmoother()
        var input = VoiceSpectrumFrame(bands: SIMD8(1, 0, 0, 0, 0, 0, 0, 0))
        let attack = smoother.step(raw: input, dt: 0.040)
        #expect(abs(attack.bands[0] - Float(1 - exp(-1.0))) < 1e-6)
        #expect(attack.bands[1] == 0)
        input.bands = .zero
        let release = smoother.step(raw: input, dt: 0.180)
        #expect(abs(release.bands[0] - attack.bands[0] * Float(exp(-1.0))) < 1e-6)
        #expect(smoother.step(raw: input, dt: 2).bands[0] < 0.00001)
        smoother.reset()
        #expect(smoother.current == .zero)
    }

    @Test func malformedInputsStayFiniteAndUnusedLanesStayZero() {
        var smoother = VoiceSpectrumSmoother()
        let result = smoother.step(raw: VoiceSpectrumFrame(level: .nan,
            bands: SIMD8(.nan, .infinity, -2, 3, 0.2, 1, 1, 1), flux: .infinity), dt: 0.1)
        for k in 0..<8 { #expect(result.bands[k].isFinite && result.bands[k] >= 0 && result.bands[k] <= 1) }
        #expect(result.bands[5] == 0 && result.bands[6] == 0 && result.bands[7] == 0)
        #expect(result.flux == 0)
    }
}

@Suite("VoiceLevelSmoother")
struct VoiceLevelSmootherTests {
    @Test func outputStaysFiniteAndBounded() {
        var smoother = VoiceLevelSmoother()
        for raw: Float in [-2, 0, 0.02, 0.16, 0.9, 4, .nan] {
            let value = smoother.step(raw: raw, dt: 1.0 / 60)
            #expect(value.isFinite && value >= 0 && value <= 1)
        }
    }
    @Test func thirtyAndSixtyFpsAgreeAfterTheSameElapsedTime() {
        var at30 = VoiceLevelSmoother()
        var at60 = VoiceLevelSmoother()
        for _ in 0..<12 { _ = at30.step(raw: 0.85, dt: 1.0 / 30) }
        for _ in 0..<24 { _ = at60.step(raw: 0.85, dt: 1.0 / 60) }
        #expect(abs(at30.current - at60.current) < 1e-6)
    }
    @Test func quietSpeechSurvivesTheNoiseFloor() {
        var smoother = VoiceLevelSmoother()
        let value = smoother.step(raw: 0.16, dt: 0.5)
        #expect(value > 0.08 && value < 0.16)
    }
}

@Suite("ThinkingOrbDisplayPolicy")
struct ThinkingOrbDisplayPolicyTests {
    @Test func prefersSixtyUnlessConstrained() {
        #expect(ThinkingOrbDisplayPolicy.preferredFramesPerSecond(isLowPowerModeEnabled: false, thermalState: .nominal) == 60)
        #expect(ThinkingOrbDisplayPolicy.preferredFramesPerSecond(isLowPowerModeEnabled: true, thermalState: .nominal) == 30)
        #expect(ThinkingOrbDisplayPolicy.preferredFramesPerSecond(isLowPowerModeEnabled: false, thermalState: .serious) == 30)
        #expect(ThinkingOrbDisplayPolicy.preferredFramesPerSecond(isLowPowerModeEnabled: false, thermalState: .critical) == 30)
    }
}

@Suite("ThinkingOrbAttribution")
struct ThinkingOrbAttributionTests {
    @Test func noticeIncludesBothCopyrightsAndAdaptation() {
        #expect(ThinkingOrbAttribution.licenseText.contains("Haplo LLC"))
        #expect(ThinkingOrbAttribution.licenseText.contains("Jakub Antalik"))
        #expect(ThinkingOrbAttribution.licenseText.contains("MIT License"))
        #expect(ThinkingOrbAttribution.summary.contains("Metal"))
        #expect(ThinkingOrbAttribution.originalDesignURLString == "https://github.com/Jakubantalik/thinking-orbs")
        #expect(ThinkingOrbAttribution.swiftPortURLString == "https://github.com/haplollc/ThinkingOrbs")
    }
    @Test func acknowledgmentsViewNamesRolesAndBothRepositories() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Shared/Renderers/Orbs/ThinkingOrbAcknowledgmentsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("Jakub Antalik — original thinking-orbs designs and engine"))
        #expect(source.contains("Haplo LLC — Swift ThinkingOrbs port"))
        #expect(source.contains("originalDesignURL") && source.contains("swiftPortURL") && source.contains("licenseText"))
    }
}

private func centered(_ dot: ThinkingOrbDot, _ size: Double) -> SIMD3<Double> {
    SIMD3(dot.x - size / 2, dot.y - size / 2, dot.z)
}
private func projectedRadius(_ dot: ThinkingOrbDot, _ size: Double) -> Double {
    hypot(dot.x - size / 2, dot.y - size / 2)
}
private func radialLength(_ dot: ThinkingOrbDot, _ size: Double) -> Double { length(centered(dot, size)) }
private func length(_ value: SIMD3<Double>) -> Double { sqrt(value.x * value.x + value.y * value.y + value.z * value.z) }
private func displacements(_ a: ThinkingOrbFrame, _ b: ThinkingOrbFrame) -> [SIMD3<Double>] {
    zip(a.dots, b.dots).map { SIMD3($1.x - $0.x, $1.y - $0.y, $1.z - $0.z) }
}
