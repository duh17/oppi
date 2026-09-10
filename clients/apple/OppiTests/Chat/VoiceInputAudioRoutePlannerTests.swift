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
        #expect(plan.category == .record)
        #expect(plan.mode == .default)
        // High-quality Bluetooth is documented for input+output categories, not
        // input-only .record. No AirPods-specific option may break built-in capture.
        #expect(plan.options == [.allowBluetoothHFP])
        #expect(plan.preferredInputUID == testCase.uid)
        #expect(plan.preferredDataSourceName == testCase.source)
        #expect(plan.preferredPolarPattern == testCase.polar)
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
            setCategory: { mode, options in
                #expect(mode == .default)
                categories.append(options)
            },
            setActive: { active, options in
                activations.append(active)
                #expect(options.isEmpty)
            }
        )
        #expect(!fallback)
        #expect(categories == [[.allowBluetoothHFP]])
        #expect(activations == [true])
    }

    @Test @MainActor func captureFallbackStartsDirectlyWithMeasurementAndNoBluetooth() throws {
        var activationCount = 0
        var categoryCount = 0
        let fallback = try VoiceInputSystemAccess.configureAndActivate(
            preferBuiltIn: true,
            setCategory: { mode, options in
                categoryCount += 1
                #expect(mode == .measurement)
                #expect(options.isEmpty)
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

    // These exercise the production sequence, not a disconnected list of action
    // names. setCategory itself can throw before we ever get to setActive.
    @Test(arguments: [true, false]) @MainActor
    func bluetoothConfigurationFailureRetriesWithoutBluetooth(failCategory: Bool) throws {
        var events: [String] = []
        var categories: [AVAudioSession.CategoryOptions] = []
        var activationAttempts = 0
        let fallback = try VoiceInputSystemAccess.configureAndActivate(
            setCategory: { mode, options in
                #expect(mode == (options.isEmpty ? .measurement : .default))
                categories.append(options)
                events.append(options.isEmpty ? "builtInCategory" : "bluetoothCategory")
                if failCategory && !options.isEmpty { throw TestVoiceError("category rejected") }
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
        #expect(categories == [[.allowBluetoothHFP], []])
        #expect(events == (failCategory
            ? ["bluetoothCategory", "deactivate", "builtInCategory", "activate"]
            : ["bluetoothCategory", "activate", "deactivate", "builtInCategory", "activate"]))
    }

    @Test(arguments: [true, false]) @MainActor
    func failedBuiltInFallbackRethrowsInsteadOfReportingCaptureStarted(failCategory: Bool) {
        var categories: [AVAudioSession.CategoryOptions] = []
        #expect(throws: TestVoiceError.self) {
            try VoiceInputSystemAccess.configureAndActivate(
                setCategory: { mode, options in
                    #expect(mode == (options.isEmpty ? .measurement : .default))
                    categories.append(options)
                    if failCategory { throw TestVoiceError("no category") }
                },
                setActive: { active, _ in
                    if active { throw TestVoiceError("no input") }
                }
            )
        }
        #expect(categories == [[.allowBluetoothHFP], []])
    }
}
#endif
