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
                #expect(dot.x >= -1 && dot.x <= size + 1)
                #expect(dot.y >= -1 && dot.y <= size + 1)
            }
        }
    }

    @Test func compactWorkingCountsStayWellBelowTheLargeSpecimen() {
        let working = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: 16,
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

    @Test func workingGeometryIgnoresAudioLevel() {
        let quiet = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: 16,
            geometryTime: 1.1,
            audioLevel: 0
        )
        let loud = ThinkingOrbGeometry.frame(
            style: .working,
            sizeClass: .workingCompact,
            size: 16,
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
            #expect(abs(left.r - right.r) < 0.02)
        }
        #expect(maxDelta > 0.02)
        #expect(maxDelta < 8)
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
