import AVFoundation
import Foundation
import Testing
@testable import Oppi

#if os(iOS)
@Suite("VoiceInputAudioRoutePlanner")
struct VoiceInputAudioRoutePlannerTests {
    struct PlannerCase: CustomTestStringConvertible {
        let name: String
        let inputs: [VoiceInputAudioRouteInput]
        let uid: String?
        var source: String?
        var polar: AVAudioSession.PolarPattern?
        var testDescription: String { name }
    }

    private static let frontCardioid = VoiceInputAudioRouteDataSource(
        name: "Front", orientation: .front, supportedPolarPatterns: [.cardioid]
    )
    private static let frontOmni = VoiceInputAudioRouteDataSource(
        name: "Front", orientation: .front, supportedPolarPatterns: [.omnidirectional]
    )
    private static let backCardioid = VoiceInputAudioRouteDataSource(
        name: "Back", orientation: .back, supportedPolarPatterns: [.cardioid]
    )
    private static let mic = input("mic", .builtInMic)
    private static let airpods = input("airpods", .bluetoothHFP)
    private static let headset = input("headset", .headsetMic)

    private static func input(
        _ uid: String,
        _ port: AVAudioSession.Port,
        _ sources: [VoiceInputAudioRouteDataSource] = []
    ) -> VoiceInputAudioRouteInput {
        .init(uid: uid, portType: port, dataSources: sources)
    }

    @Test(arguments: [
        PlannerCase(name: "no input", inputs: [], uid: nil),
        PlannerCase(name: "front cardioid", inputs: [input("mic", .builtInMic, [frontCardioid])],
                    uid: "mic", source: "Front", polar: .cardioid),
        PlannerCase(name: "front omni", inputs: [input("mic", .builtInMic, [frontOmni])],
                    uid: "mic", source: "Front"),
        PlannerCase(name: "non-front cardioid", inputs: [input("mic", .builtInMic, [backCardioid])],
                    uid: "mic", source: "Back", polar: .cardioid),
        PlannerCase(name: "front cardioid wins", inputs: [input("mic", .builtInMic, [backCardioid, frontCardioid])],
                    uid: "mic", source: "Front", polar: .cardioid),
        PlannerCase(name: "front omni beats back cardioid", inputs: [input("mic", .builtInMic, [frontOmni, backCardioid])],
                    uid: "mic", source: "Front"),
        PlannerCase(name: "no directional source", inputs: [input("mic", .builtInMic, [
            .init(name: "Bottom", orientation: .bottom, supportedPolarPatterns: [.omnidirectional]),
        ])], uid: "mic"),
        PlannerCase(name: "wired headset", inputs: [mic, headset], uid: "headset"),
        PlannerCase(name: "HFP beats headset", inputs: [headset, airpods], uid: "airpods"),
        PlannerCase(name: "USB isn't overridden", inputs: [mic, input("usb", .usbAudio)], uid: nil),
        PlannerCase(name: "HFP listed last", inputs: [mic, airpods], uid: "airpods"),
        PlannerCase(name: "HFP listed first", inputs: [airpods, mic], uid: "airpods"),
        PlannerCase(name: "first HFP wins", inputs: [airpods, input("other", .bluetoothHFP)], uid: "airpods"),
        PlannerCase(name: "HFP ignores polar patterns", inputs: [input("airpods", .bluetoothHFP, [frontCardioid])],
                    uid: "airpods"),
    ])
    func planMatchesSelectionContract(_ testCase: PlannerCase) {
        let plan = VoiceInputAudioRoutePlanner.plan(availableInputs: testCase.inputs)
        #expect(plan.category == .playAndRecord)
        #expect(plan.mode == .default)
        // Keep standard HFP while allowing existing background audio to duck,
        // rather than deactivating it when capture starts.
        #expect(plan.options == [.allowBluetoothHFP, .mixWithOthers, .duckOthers])
        #expect(plan.preferredInputUID == testCase.uid)
        #expect(plan.preferredDataSourceName == testCase.source)
        #expect(plan.preferredPolarPattern == testCase.polar)
    }

    @Test func activeA2DPUsesPhoneMicWithoutOfferingHigherPriorityHFP() {
        let plan = VoiceInputAudioRoutePlanner.plan(
            availableInputs: [Self.airpods, Self.mic],
            preserveA2DPOutput: true
        )

        #expect(plan.category == .playAndRecord)
        #expect(plan.mode == .default)
        #expect(plan.options == [.allowBluetoothA2DP, .mixWithOthers, .duckOthers])
        #expect(!plan.options.contains(.allowBluetoothHFP))
        #expect(plan.preferredInputUID == "mic")
    }

    @Test(arguments: [
        (hasA2DP: true, external: false, inApp: false, expected: false),
        (hasA2DP: true, external: true, inApp: false, expected: true),
        (hasA2DP: true, external: false, inApp: true, expected: true),
        (hasA2DP: false, external: true, inApp: true, expected: false),
    ])
    @MainActor
    func a2dpIsPreservedOnlyForActiveMedia(
        hasA2DP: Bool,
        external: Bool,
        inApp: Bool,
        expected: Bool
    ) {
        #expect(VoiceInputSystemAccess.shouldPreserveA2DPOutput(
            hasA2DPOutput: hasA2DP,
            externalAudioPlaying: external,
            inAppPlaybackActive: inApp
        ) == expected)
    }

    @Test func stalePreferredInputResetsWhenUIDIsMissing() {
        #expect(VoiceInputAudioRoutePlanner.shouldResetPreferredInput(preferredUID: "airpods", availableInputs: [Self.mic]))
        #expect(!VoiceInputAudioRoutePlanner.shouldResetPreferredInput(preferredUID: "mic", availableInputs: [Self.mic]))
        #expect(!VoiceInputAudioRoutePlanner.shouldResetPreferredInput(preferredUID: nil, availableInputs: [Self.mic]))
    }

    @Test func excludingBluetoothHFPFallsBackToBuiltInMic() {
        let inputs = [Self.airpods, Self.input("mic", .builtInMic, [Self.frontCardioid])]
        let plan = VoiceInputAudioRoutePlanner.plan(
            availableInputs: VoiceInputAudioRoutePlanner.excludingBluetoothHFP(inputs)
        )
        #expect(plan.preferredInputUID == "mic")
        #expect(plan.preferredDataSourceName == "Front")
        #expect(plan.preferredPolarPattern == .cardioid)
    }

    @Test @MainActor func activationUsesOnlyActivationOptions() throws {
        var categories: [AVAudioSession.CategoryOptions] = []
        var activations: [Bool] = []
        let fallback = try VoiceInputSystemAccess.configureAndActivate(
            setCategory: { category, mode, options in
                #expect(category == .playAndRecord)
                #expect(mode == .default)
                categories.append(options)
            },
            setActive: { active, options in
                activations.append(active)
                #expect(options.isEmpty)
            }
        )
        #expect(!fallback)
        #expect(categories == [[.allowBluetoothHFP, .mixWithOthers, .duckOthers]])
        #expect(activations == [true])
    }

    @Test @MainActor func activationPreservesCurrentA2DPAndExcludesHFP() throws {
        var optionsSeen: AVAudioSession.CategoryOptions = []
        let fallback = try VoiceInputSystemAccess.configureAndActivate(
            preserveA2DPOutput: true,
            setCategory: { category, mode, options in
                #expect(category == .playAndRecord)
                #expect(mode == .default)
                optionsSeen = options
            },
            setActive: { active, options in
                #expect(active)
                #expect(options.isEmpty)
            }
        )
        #expect(!fallback)
        #expect(optionsSeen == [.allowBluetoothA2DP, .mixWithOthers, .duckOthers])
    }

    @Test @MainActor func captureFallbackKeepsMixingWithBuiltInMeasurement() throws {
        var activationCount = 0
        var categoryCount = 0
        let fallback = try VoiceInputSystemAccess.configureAndActivate(
            preferBuiltIn: true,
            setCategory: { category, mode, options in
                #expect(category == .playAndRecord)
                categoryCount += 1
                #expect(mode == .measurement)
                #expect(options == [.mixWithOthers, .duckOthers])
            },
            setActive: { active, options in
                activationCount += 1
                #expect(active)
                #expect(options.isEmpty)
            }
        )
        #expect(fallback)
        #expect(categoryCount == 1)
        #expect(activationCount == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func recordingAllowsHapticsBeforeActivation(preferBuiltIn: Bool) throws {
        var events: [String] = []
        _ = try VoiceInputSystemAccess.configureAndActivate(
            preferBuiltIn: preferBuiltIn,
            setCategory: { _, _, _ in events.append("category") },
            setActive: { _, _ in events.append("activate") },
            setAllowHaptics: { allowed in
                #expect(allowed)
                events.append("haptics")
            }
        )
        #expect(events == ["haptics", "category", "activate"])
    }

    @Test @MainActor func unavailableHapticsDoNotPreventRecording() throws {
        var activated = false
        let fallback = try VoiceInputSystemAccess.configureAndActivate(
            setCategory: { _, _, _ in },
            setActive: { active, _ in activated = active },
            setAllowHaptics: { _ in throw TestVoiceError("haptics unavailable") }
        )
        #expect(activated)
        #expect(!fallback)
    }

    // These exercise the production sequence, not a disconnected list of action
    // names. setCategory itself can throw before we ever get to setActive.
    @Test(arguments: [true, false]) @MainActor
    func bluetoothConfigurationFailureRetriesWithoutBluetooth(failCategory: Bool) throws {
        var events: [String] = []
        var categories: [AVAudioSession.CategoryOptions] = []
        var activationAttempts = 0
        let fallback = try VoiceInputSystemAccess.configureAndActivate(
            setCategory: { category, mode, options in
                let usesBluetooth = options.contains(.allowBluetoothHFP)
                #expect(category == .playAndRecord)
                #expect(mode == (usesBluetooth ? .default : .measurement))
                categories.append(options)
                events.append(usesBluetooth ? "bluetoothCategory" : "builtInCategory")
                if failCategory && usesBluetooth { throw TestVoiceError("category rejected") }
            },
            setActive: { active, options in
                #expect(options == (active ? [] : .notifyOthersOnDeactivation))
                events.append(active ? "activate" : "deactivate")
                if active {
                    activationAttempts += 1
                    if !failCategory && activationAttempts == 1 { throw TestVoiceError("activation rejected") }
                }
            }
        )
        #expect(fallback)
        #expect(categories == [
            [.allowBluetoothHFP, .mixWithOthers, .duckOthers],
            [.mixWithOthers, .duckOthers],
        ])
        #expect(events == (failCategory
            ? ["bluetoothCategory", "builtInCategory", "activate"]
            : ["bluetoothCategory", "activate", "builtInCategory", "activate"]))
    }

    @Test(arguments: [true, false]) @MainActor
    func failedBuiltInFallbackRethrowsInsteadOfReportingCaptureStarted(failCategory: Bool) {
        var categories: [AVAudioSession.CategoryOptions] = []
        #expect(throws: TestVoiceError.self) {
            try VoiceInputSystemAccess.configureAndActivate(
                setCategory: { category, mode, options in
                    #expect(category == .playAndRecord)
                    #expect(mode == (options.contains(.allowBluetoothHFP) ? .default : .measurement))
                    categories.append(options)
                    if failCategory { throw TestVoiceError("no category") }
                },
                setActive: { active, _ in
                    if active { throw TestVoiceError("no input") }
                }
            )
        }
        #expect(categories == [
            [.allowBluetoothHFP, .mixWithOthers, .duckOthers],
            [.mixWithOthers, .duckOthers],
        ])
    }
}
#endif
