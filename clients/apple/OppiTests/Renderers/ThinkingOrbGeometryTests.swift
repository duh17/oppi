import Foundation
import Testing
@testable import Oppi

@Suite("ThinkingOrbGeometry")
struct ThinkingOrbGeometryTests {
    @Test func fiveStylesProduceBoundedFiniteDots() {
        let styles = ThinkingOrbStyle.allCases
        #expect(styles == [.working, .searching, .solving, .composing, .breathing])
        for style in styles {
            let sizeClass: ThinkingOrbSizeClass = style.isVoiceReactive ? .dictationStandard : .workingCompact
            let size = sizeClass.designSize
            let frame = ThinkingOrbGeometry.frame(
                style: style,
                sizeClass: sizeClass,
                size: size,
                geometryTime: 1.25,
                audioLevel: 0.4
            )
            #expect(!frame.dots.isEmpty)
            for dot in frame.dots {
                #expect(dot.x.isFinite && dot.y.isFinite && dot.z.isFinite)
                #expect(dot.r.isFinite && dot.r > 0)
                #expect(dot.a.isFinite && dot.a >= 0 && dot.a <= 1)
                #expect(dot.white.isFinite)
                #expect(dot.accent.isFinite && dot.accent >= 0 && dot.accent <= 1)
                #expect(dot.palette.isFinite && dot.palette >= 0 && dot.palette <= 3)
                #expect(dot.x >= -1 && dot.x <= size + 1)
                #expect(dot.y >= -1 && dot.y <= size + 1)
            }
        }
    }

    @Test func compactWorkingCountsStayWellBelowTheLargeSpecimen() {
        let working = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: ThinkingOrbSizeClass.workingCompact.designSize,
            geometryTime: 0.8
        )
        let composing = ThinkingOrbGeometry.frame(
            style: .composing,
            sizeClass: .dictationStandard,
            size: 44,
            geometryTime: 0.8,
            audioLevel: 0.5
        )
        let breathing = ThinkingOrbGeometry.frame(
            style: .breathing,
            sizeClass: .dictationExpanded,
            size: 32,
            geometryTime: 0.8,
            audioLevel: 0.5
        )
        #expect(working.dots.count < 80)
        #expect(composing.dots.count < 200)
        #expect(breathing.dots.count < 160)
        #expect(working.dots.count != 566)
        #expect(composing.dots.count != 566)
    }

    @Test func dictationSilhouetteStaysInsideTheCircularControl() {
        for sizeClass in [ThinkingOrbSizeClass.dictationExpanded, .dictationStandard] {
            let size = sizeClass.designSize
            let radius = size / 2
            for style in [ThinkingOrbStyle.composing, .breathing] {
                for audio in [Float(0), 0.2, 1] {
                    let frame = ThinkingOrbGeometry.frame(
                        style: style,
                        sizeClass: sizeClass,
                        size: size,
                        geometryTime: 2.4,
                        audioLevel: audio
                    )
                    for dot in frame.dots {
                        let dx = dot.x - radius
                        let dy = dot.y - radius
                        let extent = (dx * dx + dy * dy).squareRoot() + dot.r
                        #expect(extent <= radius + 0.75)
                    }
                }
            }
        }
    }

    @Test func workingIndicatorTimeScaleIsHalfOriginalWithoutDroppingFrameRate() {
        let compact = ThinkingOrbSizeClass.workingCompact
        let preview = ThinkingOrbSizeClass.workingPreview
        let scale = ThinkingOrbPresets.workingMotionScale
        #expect(scale == 0.5)
        #expect(ThinkingOrbPresets.resolve(.working, compact).speed == 3.9 * scale)
        #expect(ThinkingOrbPresets.resolve(.working, preview).speed == 3.9 * scale)
        #expect(ThinkingOrbPresets.resolve(.searching, compact).speed == 2.665 * scale)
        #expect(ThinkingOrbPresets.resolve(.searching, preview).speed == 2.665 * scale)
        #expect(ThinkingOrbPresets.resolve(.solving, compact).speed == 1.95 * scale)
        #expect(ThinkingOrbPresets.resolve(.solving, preview).speed == 1.95 * scale)
        #expect(ThinkingOrbPresets.resolve(.composing, .dictationStandard).speed == 2.34)
        #expect(ThinkingOrbPresets.resolve(.composing, .dictationExpanded).speed == 2.34)
        #expect(ThinkingOrbPresets.resolve(.breathing, .dictationStandard).speed == 2.8)
        #expect(ThinkingOrbPresets.resolve(.breathing, .dictationExpanded).speed == 2.8)
        #expect(ThinkingOrbDisplayPolicy.activeFramesPerSecond == 60)
        #expect(ThinkingOrbDisplayPolicy.constrainedFramesPerSecond == 30)
        #expect(
            ThinkingOrbDisplayPolicy.preferredFramesPerSecond(
                isLowPowerModeEnabled: false,
                thermalState: .nominal
            ) == 60
        )
    }

    @Test func compactWorkingFootprintIsEighteenPoints() {
        #expect(ThinkingOrbSizeClass.workingCompact.designSize == 18)
        #expect(ThinkingOrbSizeClass.workingPreview.designSize == 20)
        #expect(ThinkingOrbSizeClass.working(side: 18) == .workingCompact)
        #expect(ThinkingOrbSizeClass.working(side: 16) == .workingCompact)
        #expect(ThinkingOrbSizeClass.working(side: 20) == .workingPreview)
    }

    @Test func workingStylesColorASubsetOfDotsFromThePalette() {
        let working = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: 18,
            geometryTime: 0.8
        )
        let searching = ThinkingOrbGeometry.frame(
            style: .searching,
            sizeClass: .workingCompact,
            size: 18,
            geometryTime: 1.2
        )
        let solving = ThinkingOrbGeometry.frame(
            style: .solving,
            sizeClass: .workingCompact,
            size: 18,
            geometryTime: 0.4
        )
        let composing = ThinkingOrbGeometry.frame(
            style: .composing,
            sizeClass: .dictationStandard,
            size: 44,
            geometryTime: 0.8
        )
        #expect(working.dots.contains { $0.accent >= 0.8 })
        #expect(working.dots.contains { $0.accent == 0 })
        #expect(Set(working.dots.filter { $0.accent >= 0.8 }.map(\.palette)).count >= 2)
        #expect(searching.dots.contains { $0.accent > 0.2 })
        #expect(solving.dots.contains { $0.accent >= 0.2 })
        #expect(composing.dots.allSatisfy { $0.accent == 0 })
    }

    @Test func workingGeometryIgnoresAudioLevel() {
        let size = ThinkingOrbSizeClass.workingCompact.designSize
        let quiet = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: size,
            geometryTime: 1.1,
            audioLevel: 0
        )
        let loud = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: size,
            geometryTime: 1.1,
            audioLevel: 1
        )
        #expect(quiet.dots.count == loud.dots.count)
        for (left, right) in zip(quiet.dots, loud.dots) {
            #expect(left == right)
        }
    }

    @Test func composingVoiceChangesAmplitudeNotClock() {
        let quiet = ThinkingOrbGeometry.frame(
            style: .composing,
            sizeClass: .dictationStandard,
            size: 44,
            geometryTime: 1.7,
            audioLevel: 0,
            zSorted: false
        )
        let loud = ThinkingOrbGeometry.frame(
            style: .composing,
            sizeClass: .dictationStandard,
            size: 44,
            geometryTime: 1.7,
            audioLevel: 1,
            zSorted: false
        )
        #expect(quiet.dots.count == loud.dots.count)
        var maxDelta = 0.0
        for (left, right) in zip(quiet.dots, loud.dots) {
            let delta = hypot(left.x - right.x, left.y - right.y)
            maxDelta = max(maxDelta, delta)
            // Depth shading can nudge radius slightly; voice must not pulse size.
            #expect(abs(left.r - right.r) < 0.08)
        }
        #expect(maxDelta > 1.5)
        #expect(maxDelta < 10)
    }

    @Test func quietDictationMotionIsPerceptibleAtProductionSizes() {
        for style in [ThinkingOrbStyle.composing, .breathing] {
            for sizeClass in [ThinkingOrbSizeClass.dictationExpanded, .dictationStandard] {
                let size = sizeClass.designSize
                let speed = ThinkingOrbPresets.resolve(style, sizeClass).speed
                let t0 = 0.7 * speed
                let t1 = 1.7 * speed
                let first = ThinkingOrbGeometry.frame(
                    style: style,
                    sizeClass: sizeClass,
                    size: size,
                    geometryTime: t0,
                    audioLevel: 0,
                    zSorted: false
                )
                let second = ThinkingOrbGeometry.frame(
                    style: style,
                    sizeClass: sizeClass,
                    size: size,
                    geometryTime: t1,
                    audioLevel: 0,
                    zSorted: false
                )
                let motion = orbPointDisplacement(first, second)
                print(
                    "quiet \(style.rawValue) \(Int(size))pt mean/max \(motion.mean)/\(motion.max)pt"
                )
                #expect(
                    motion.mean >= 1.2,
                    "\(style.rawValue) \(Int(size))pt 1s quiet mean \(motion.mean)pt"
                )
                #expect(
                    motion.max >= 2.0,
                    "\(style.rawValue) \(Int(size))pt 1s quiet max \(motion.max)pt"
                )
                #expect(
                    motion.max < 12,
                    "\(style.rawValue) \(Int(size))pt 1s quiet max \(motion.max)pt is violent"
                )
            }
        }
    }

    @Test func modestVoiceDeformsDictationOrbsByMoreThanAPoint() {
        let voice = smoothedVoice(raw: 0.2, seconds: 1)
        #expect(voice > 0.12)
        for style in [ThinkingOrbStyle.composing, .breathing] {
            for sizeClass in [ThinkingOrbSizeClass.dictationExpanded, .dictationStandard] {
                let size = sizeClass.designSize
                let speed = ThinkingOrbPresets.resolve(style, sizeClass).speed
                let t = 0.7 * speed
                let quiet = ThinkingOrbGeometry.frame(
                    style: style,
                    sizeClass: sizeClass,
                    size: size,
                    geometryTime: t,
                    audioLevel: 0,
                    zSorted: false
                )
                let speaking = ThinkingOrbGeometry.frame(
                    style: style,
                    sizeClass: sizeClass,
                    size: size,
                    geometryTime: t,
                    audioLevel: voice,
                    zSorted: false
                )
                #expect(quiet.dots.count == speaking.dots.count)
                let motion = orbPointDisplacement(quiet, speaking)
                print(
                    "modest-voice \(style.rawValue) \(Int(size))pt mean/max \(motion.mean)/\(motion.max)pt audio=\(voice)"
                )
                #expect(
                    motion.mean >= 0.85,
                    "\(style.rawValue) \(Int(size))pt modest-voice mean \(motion.mean)pt"
                )
                #expect(
                    motion.max >= 1.4,
                    "\(style.rawValue) \(Int(size))pt modest-voice max \(motion.max)pt"
                )
                #expect(
                    motion.max < 8,
                    "\(style.rawValue) \(Int(size))pt modest-voice max \(motion.max)pt is violent"
                )
            }
        }
    }

    @Test func stylesAreVisuallyDistinctAtTheSameTime() {
        let size = 44.0
        let frames = ThinkingOrbStyle.allCases.map {
            ThinkingOrbGeometry.frame(
                style: $0,
                sizeClass: $0.isVoiceReactive ? .dictationStandard : .workingPreview,
                size: size,
                geometryTime: 0.9
            )
        }
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let sameCount = frames[i].dots.count == frames[j].dots.count
                let sameFirst = frames[i].dots.first == frames[j].dots.first
                #expect(!(sameCount && sameFirst))
            }
        }
    }
}

@Suite("VoiceLevelSmoother")
struct VoiceLevelSmootherTests {
    @Test func outputStaysFiniteAndBounded() {
        var smoother = VoiceLevelSmoother()
        for raw in [-2, 0, 0.02, 0.16, 0.9, 4, Float.nan] as [Float] {
            let value = smoother.step(raw: raw, dt: 1.0 / 60.0)
            #expect(value.isFinite)
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test func thirtyAndSixtyFpsAgreeAfterTheSameElapsedTime() {
        var at60 = VoiceLevelSmoother()
        var at30 = VoiceLevelSmoother()
        let elapsed: TimeInterval = 0.40
        let frames60 = Int((elapsed * 60).rounded())
        let frames30 = Int((elapsed * 30).rounded())
        var last60: Float = 0
        var last30: Float = 0
        for _ in 0..<frames60 {
            last60 = at60.step(raw: 0.85, dt: 1.0 / 60.0)
        }
        for _ in 0..<frames30 {
            last30 = at30.step(raw: 0.85, dt: 1.0 / 30.0)
        }
        #expect(abs(last60 - last30) < 0.03)
    }

    @Test func quietSpeechSurvivesTheNoiseFloor() {
        var smoother = VoiceLevelSmoother()
        var value: Float = 0
        for _ in 0..<30 {
            value = smoother.step(raw: 0.16, dt: 1.0 / 60.0)
        }
        #expect(value > 0.08)
        #expect(value < 0.16)
    }
}

@Suite("ThinkingOrbDisplayPolicy")
struct ThinkingOrbDisplayPolicyTests {
    @Test func prefersSixtyUnlessConstrained() {
        #expect(
            ThinkingOrbDisplayPolicy.preferredFramesPerSecond(
                isLowPowerModeEnabled: false,
                thermalState: .nominal
            ) == 60
        )
        #expect(
            ThinkingOrbDisplayPolicy.preferredFramesPerSecond(
                isLowPowerModeEnabled: true,
                thermalState: .nominal
            ) == 30
        )
        #expect(
            ThinkingOrbDisplayPolicy.preferredFramesPerSecond(
                isLowPowerModeEnabled: false,
                thermalState: .serious
            ) == 30
        )
        #expect(
            ThinkingOrbDisplayPolicy.preferredFramesPerSecond(
                isLowPowerModeEnabled: false,
                thermalState: .critical
            ) == 30
        )
    }
}

@Suite("ThinkingOrbAttribution")
struct ThinkingOrbAttributionTests {
    @Test func noticeIncludesBothCopyrightsAndAdaptation() {
        #expect(ThinkingOrbAttribution.licenseText.contains("Haplo LLC"))
        #expect(ThinkingOrbAttribution.licenseText.contains("Jakub Antalik"))
        #expect(ThinkingOrbAttribution.licenseText.contains("MIT License"))
        #expect(ThinkingOrbAttribution.summary.contains("Jakub Antalik"))
        #expect(ThinkingOrbAttribution.summary.contains("Haplo LLC"))
        #expect(ThinkingOrbAttribution.summary.contains("Metal"))
        #expect(ThinkingOrbAttribution.originalDesignURLString == "https://github.com/Jakubantalik/thinking-orbs")
        #expect(ThinkingOrbAttribution.swiftPortURLString == "https://github.com/haplollc/ThinkingOrbs")
    }

    @Test func acknowledgmentsViewNamesRolesAndBothRepositories() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Shared/Renderers/Orbs/ThinkingOrbAcknowledgmentsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("Jakub Antalik — original thinking-orbs designs and engine"))
        #expect(source.contains("Haplo LLC — Swift ThinkingOrbs port"))
        #expect(source.contains("originalDesignURL"))
        #expect(source.contains("swiftPortURL"))
        #expect(source.contains("licenseText"))
    }
}

private func orbPointDisplacement(_ a: ThinkingOrbFrame, _ b: ThinkingOrbFrame) -> (mean: Double, max: Double) {
    let deltas = zip(a.dots, b.dots).map { hypot($0.x - $1.x, $0.y - $1.y) }
    let mean = deltas.reduce(0, +) / Double(max(deltas.count, 1))
    return (mean, deltas.max() ?? 0)
}

private func smoothedVoice(raw: Float, seconds: TimeInterval) -> Float {
    var smoother = VoiceLevelSmoother()
    let dt = 1.0 / 60.0
    let frames = Int((seconds / dt).rounded())
    var value: Float = 0
    for _ in 0..<frames {
        value = smoother.step(raw: raw, dt: dt)
    }
    return value
}
