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

    @Test func breathingInputHoldsAStandingShapeAtDistantTimes() {
        let input = VoiceSpectrumFrame(level: 1, bands: SIMD8(0.8, 0.4, 0.2, 0.7, 0.9, 0, 0, 0))
        for style in [ThinkingOrbStyle.breathing] {
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
                for time in [0.0, 1.7, 120.0] {
                    let idle = frame(style, size, time: style == .composing ? time : 0.6)
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
                // Composing keeps treble ripples small; Breathing retains its larger roughness.
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

    @Test func sameBandsKeepComposingRestrainedAndDistinctFromBreathing() {
        let voice = VoiceSpectrumFrame(bands: SIMD8(0.6, 0.3, 0.5, 0.2, 0.4, 0, 0, 0))
        for size in sizes {
            let composing = frame(.composing, size, voice)
            let sphere = frame(.breathing, size, voice)
            #expect(composing.dots != sphere.dots)
            #expect(composing.dots.filter { $0.a >= 0.4 }.allSatisfy {
                projectedRadius($0, size.designSize) > size.designSize * 0.06
            }, "The sash leaves open space through its center")
            #expect(sphere.dots.contains { projectedRadius($0, size.designSize) < size.designSize * 0.1 })
            let composingTravel = displacements(frame(.composing, size), composing).map { length($0) }
            let breathingTravel = displacements(frame(.breathing, size), sphere).map { length($0) }
            #expect((composingTravel.max() ?? 0) < (breathingTravel.max() ?? 0))
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

    @Test func fluxChangesComposingDotRadiusAndBreathingAccentButNeverPositions() {
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

    @Test func composingQuietMatchesPinnedUpstreamSashOracle() {
        // Generated by compiling the unmodified OrbEngine/OrbPresets from
        // haplollc/ThinkingOrbs e2c07bbdec4db797fb302300ef0159b1806a909f,
        // OrbPresets.resolve(.composing, .regular).frame(size: 44, t: 0).
        // Sorted samples include ghost, far/near, center/edge lanes. These
        // numbers are NOT derived from Oppi's builder or its earlier ports.
        let oracle: [(Int, Double, Double, Double, Double, Double, Double)] = [
            (0, 25.659142103415356, 21.075977535511367, -16.739846521164203, 0.3, 0.78, 0.1026932915309987),
            (37, 26.80673369729434, 31.42359475208977, -13.511357189848889, 0.3362726354562842, 0.48958616443862213, 0.46378746171592855),
            (80, 24.43213672548319, 34.328859017555864, -11.685441637943656, 0.3097846732115062, 0.5643588088780656, 0.4957090622737123),
            (150, 9.031713445660737, 29.51447441769235, -8.355945073442655, 0.40332260547097937, 0.4234911373052089, 0.553917044170583),
            (240, 5.069919765828949, 22.567476277089877, -2.74152401767172, 0.4541868711013282, 0.3842386529072132, 0.6520712584323125),
            (300, 36.70773308716401, 30.64519007464264, 1.8463141688351419, 0.4113569544649034, 0.4563293055277546, 0.73227821973488),
            (400, 37.60294843651849, 23.092906481879687, 7.0582685914614185, 0.5476288593092902, 0.2913275588507277, 0.8233963040465284),
            (500, 17.1794075265542, 10.18652845832057, 11.474727811102447, 0.6304801312851167, 0.20197901407677515, 0.9006071295647281),
            (565, 22.0, 18.95398998965966, 16.88749309450359, 0.5614852527619381, 0.263493678275595, 0.9952358932605523),
        ]
        let dots = ThinkingOrbGeometry.frame(style: .composing, sizeClass: .dictationStandard,
                                             size: 44, geometryTime: 0).dots
        #expect(dots.count == 566)
        guard dots.count == 566 else { return }
        for (i, x, y, z, r, white, alpha) in oracle {
            let actual = dots[i]
            #expect(abs(actual.x - x) < 1e-10 && abs(actual.y - y) < 1e-10 && abs(actual.z - z) < 1e-10)
            #expect(abs(actual.r - r) < 1e-10 && abs(actual.white - white) < 1e-10 && abs(actual.a - alpha) < 1e-10)
        }
        for size in sizes {
            let raw = frame(.composing, size, time: 0).dots
            #expect(raw.count == 38 + 12 * 44)
            #expect(raw.allSatisfy { abs(radialLength($0, size.designSize) - 0.39 * size.designSize) < 1e-9 })
            let sash = raw.dropFirst(38)
            // Original's nearest sash center is ~.06923 * size, not a circular .14 hole.
            #expect(sash.allSatisfy { projectedRadius($0, size.designSize) > 0.06 * size.designSize })
            #expect(sash.contains { $0.z > 0.3 * size.designSize } && sash.contains { $0.z < -0.3 * size.designSize })
        }
        #expect(frame(.composing, .workingCompact, time: 0).dots.count == 8 + 10 * 20)
    }

    @Test func composingFrontParticlesAreLargerAndBrighterThanTheRear() {
        for size in sizes {
            let dots = frame(.composing, size).dots
            let front = dots.filter { $0.a >= 0.4 && $0.z > size.designSize * 0.2 }
            let back = dots.filter { $0.a >= 0.4 && $0.z < -size.designSize * 0.2 }
            #expect(!front.isEmpty && !back.isEmpty, "True front/back sphere depth, not band shading")
            guard !front.isEmpty && !back.isEmpty else { continue }
            #expect((front.map(\.r).min() ?? 0) > (back.map(\.r).max() ?? 0))
            #expect((front.map(\.a).min() ?? 0) > (back.map(\.a).max() ?? 0))
            #expect((front.map(\.white).reduce(0, +) / Double(front.count))
                < (back.map(\.white).reduce(0, +) / Double(back.count)))
            #expect(dots.allSatisfy { $0.r >= 0.3 && $0.a >= 0.1 && $0.a <= 1 })
            let sorted = ThinkingOrbGeometry.frame(
                style: .composing, sizeClass: size, size: size.designSize, geometryTime: 0.6
            ).dots
            #expect(sorted.count == dots.count)
            #expect(zip(sorted, sorted.dropFirst()).allSatisfy { $0.z <= $1.z }, "Front dots paint over the rear")
        }
    }

    @Test func composingPreservesOriginalPlaneAnglesLaneGapsAndSphereDuringSpeech() {
        for size in sizes {
            let side = size.designSize
            for time in [0.0, 1.7, 10.0, 120.0] {
                let idle = frame(.composing, size, time: time)
                for voice in bandCubeSamples {
                    let live = frame(.composing, size, voice, time: time)
                    #expect(live.dots.count == 566)
                    guard live.dots.count == 566 else { continue }
                    #expect(displacements(idle, live).allSatisfy { length($0) < side * 0.14 })
                    #expect(zip(idle.dots.prefix(38), live.dots.prefix(38)).allSatisfy { $0 == $1 }, "Ghost sphere anchors orientation")
                    var prior = [Double](repeating: -.infinity, count: 44)
                    for lane in 0..<12 {
                        for k in 0..<44 {
                            let dot = live.dots[38 + lane * 44 + k]
                            let x = dot.x - side / 2, y = side / 2 - dot.y
                            // Invert the upstream fixed camera (.3) + plane (.55).
                            let along = y * cos(0.85) + dot.z * sin(0.85)
                            let normal = -y * sin(0.85) + dot.z * cos(0.85)
                            let angle = Double(k) / 44 * 2 * Double.pi
                            #expect(abs(atan2(sin(atan2(along, x) - angle), cos(atan2(along, x) - angle))) < 1e-10,
                                    "No rotation, tumble, or angular lane lag")
                            let offset = normal / hypot(x, along)
                            #expect(offset - prior[k] > 0.035, "Original ordered lanes keep their gaps")
                            prior[k] = offset
                            #expect(abs(radialLength(dot, side) - side * 0.39) < 1e-9)
                        }
                    }
                }
            }
        }
    }

    @Test func composingCompleteDotsStayInCanvasAcrossTheBandCube() {
        for size in sizes + [.workingCompact, .workingPreview] {
            // Unlike a sampled bound alone, this covers every phase and input:
            // all centers lie on .39 * side, depth <= 1, edge taper <= 1.
            let multiplier = size == .workingCompact || size == .workingPreview ? 1.073 : 0.85
            let maximumRadius = max(0.3, 2.8 * multiplier * pow(size.designSize / 300, 0.6) * 1.2)
            #expect(0.39 * size.designSize + maximumRadius
                < size.designSize / 2 - 2 * Double(Float(size.designSize).ulp))
            for sample in bandCubeSamples {
                // Include both ends of flux and the extremes of the calm-sea phase.
                for (time, flux) in [(0.0, Float(0)), (Double.pi / 0.32, Float(30)),
                                     (3 * Double.pi / 0.32, Float(30)), (120.0, Float(30))] {
                    var voice = sample
                    voice.flux = flux
                    let dots = ThinkingOrbGeometry.frame(
                        style: .composing, sizeClass: size, size: size.designSize,
                        geometryTime: time, voiceSpectrum: voice
                    ).dots
                    #expect(!dots.isEmpty)
                    #expect(dots.allSatisfy {
                        $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.r.isFinite
                            && $0.x - $0.r >= 0 && $0.y - $0.r >= 0
                            && $0.x + $0.r <= size.designSize && $0.y + $0.r <= size.designSize
                    })
                    #expect(dots.allSatisfy {
                        let x = Float($0.x), y = Float($0.y), r = Float($0.r)
                        let side = Float(size.designSize)
                        return x - r >= 0 && y - r >= 0 && x + r <= side && y + r <= side && r >= 0.3
                    }, "Bounds and minimum dot size must survive Metal's Float conversion")
                }
            }
        }
    }

    @Test func composingCalmSeaIsSubtleSlowContinuousAndWeakerThanSpeech() {
        for size in sizes {
            let start = frame(.composing, size, time: 0)
            var peak = 0.0
            for tick in 0...160 {
                let time = Double(tick) / 4
                let idle = frame(.composing, size, time: time)
                peak = max(peak, displacements(start, idle).map { length($0) }.max() ?? 0)
                let next = frame(.composing, size, time: time + 1.0 / 60)
                #expect(displacements(idle, next).allSatisfy { length($0) < 0.003 })
                #expect(zip(idle.dots, next.dots).allSatisfy { abs($0.r - $1.r) < 0.001 })
            }
            #expect(peak > 0.05 && peak < size.designSize * 0.018, "Small but nonzero calm-sea undulation")
            let voice = VoiceSpectrumFrame(bands: SIMD8(0.8, 0.2, 0, 0, 0.2, 0, 0, 0))
            let spoken = displacements(start, frame(.composing, size, voice, time: 0)).map { length($0) }.max() ?? 0
            #expect(spoken > 3 * peak)
        }
    }

    @Test func composingUpperBandsMakeSmallerCoherentOutOfPlaneRipples() {
        for size in sizes {
            let idle = frame(.composing, size)
            var previousPeak = Double.infinity
            for band in 1..<5 {
                var input = VoiceSpectrumFrame.zero
                input.bands[band] = 1
                let live = frame(.composing, size, input)
                let peak = displacements(idle, live).map { length($0) }.max() ?? 0
                #expect(peak > size.designSize * 0.008 && peak < previousPeak)
                previousPeak = peak
                guard live.dots.count == 566 else { Issue.record("Missing upstream lanes"); continue }
                // Inverse projection measures out-of-plane motion, not a radial swell.
                func offset(_ dot: ThinkingOrbDot) -> Double {
                    let x = dot.x - size.designSize / 2, y = size.designSize / 2 - dot.y
                    return (-y * sin(0.85) + dot.z * cos(0.85)) / hypot(x, y * cos(0.85) + dot.z * sin(0.85))
                }
                let travel = (0..<44).map { offset(live.dots[38 + $0]) - offset(idle.dots[38 + $0]) }
                #expect(travel.contains { $0 > 0.025 } && travel.contains { $0 < -0.025 })
                for lane in 1..<12 {
                    #expect((0..<44).allSatisfy { k in
                        abs(offset(live.dots[38 + lane * 44 + k]) - offset(idle.dots[38 + lane * 44 + k]) - travel[k]) < 1e-10
                    }, "Every lane shares the spectral ripple; no added lane-lag twist")
                }
            }
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
                let quiet = frame(style, size, time: 120)
                let final = frame(style, size, settled, time: 120)
                #expect(displacements(quiet, final).allSatisfy { length($0) < 0.00001 })
                #expect(zip(quiet.dots, final.dots).allSatisfy { abs($0.r - $1.r) < 0.00001 })
            }
        }
    }

    private var bandCubeSamples: [VoiceSpectrumFrame] {
        // All corners plus intermediate gains; also exercise saturated flux.
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
