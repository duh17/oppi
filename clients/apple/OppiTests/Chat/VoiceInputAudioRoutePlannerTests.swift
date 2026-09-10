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
        let bluetoothHighQualityRecordingAvailable: Bool
        let expectedUID: String?
        let expectedDataSourceName: String?
        let expectedPolarPattern: AVAudioSession.PolarPattern?
        let expectBluetoothHighQualityRecording: Bool

        var testDescription: String { name }
    }

    @Test(arguments: [
        PlannerCase(
            name: "empty inputs request no preferred port",
            inputs: [],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: nil,
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "built-in front cardioid prefers front and cardioid",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "mic",
            expectedDataSourceName: "Front",
            expectedPolarPattern: .cardioid,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "front without cardioid prefers front and omits polar",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.omnidirectional]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "mic",
            expectedDataSourceName: "Front",
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "non-front cardioid is used when front has none",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Back",
                            orientation: .back,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "mic",
            expectedDataSourceName: "Back",
            expectedPolarPattern: .cardioid,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "front cardioid wins over another cardioid",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Back",
                            orientation: .back,
                            supportedPolarPatterns: [.cardioid]
                        ),
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.cardioid, .omnidirectional]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "mic",
            expectedDataSourceName: "Front",
            expectedPolarPattern: .cardioid,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "front without cardioid beats non-front cardioid",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.omnidirectional]
                        ),
                        .init(
                            name: "Back",
                            orientation: .back,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "mic",
            expectedDataSourceName: "Front",
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "no polar when cardioid is unsupported and there is no front",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Bottom",
                            orientation: .bottom,
                            supportedPolarPatterns: [.omnidirectional]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "mic",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "wired headset beats built-in mic",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
                VoiceInputAudioRouteInput(
                    uid: "headset",
                    portType: .headsetMic,
                    dataSources: []
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "headset",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "bluetoothHFP beats wired headset",
            inputs: [
                VoiceInputAudioRouteInput(
                    uid: "headset",
                    portType: .headsetMic,
                    dataSources: []
                ),
                .bluetoothHFP(uid: "airpods"),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "airpods",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "external USB input is not overridden by built-in mic",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
                VoiceInputAudioRouteInput(
                    uid: "usb",
                    portType: .usbAudio,
                    dataSources: []
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: nil,
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "first bluetoothHFP wins over built-in mic",
            inputs: [
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
                .bluetoothHFP(uid: "airpods"),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "airpods",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "bluetoothHFP still wins when it is listed first",
            inputs: [
                .bluetoothHFP(uid: "airpods"),
                .builtInMic(uid: "mic", sources: []),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "airpods",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "first bluetoothHFP wins among multiple HFP ports",
            inputs: [
                .bluetoothHFP(uid: "airpods-1"),
                .bluetoothHFP(uid: "airpods-2"),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "airpods-1",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "bluetoothHFP does not request data source or polar",
            inputs: [
                VoiceInputAudioRouteInput(
                    uid: "airpods",
                    portType: .bluetoothHFP,
                    dataSources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: false,
            expectedUID: "airpods",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: false
        ),
        PlannerCase(
            name: "high-quality recording option does not change input selection",
            inputs: [
                .bluetoothHFP(uid: "airpods"),
                .builtInMic(
                    uid: "mic",
                    sources: [
                        .init(
                            name: "Front",
                            orientation: .front,
                            supportedPolarPatterns: [.cardioid]
                        ),
                    ]
                ),
            ],
            bluetoothHighQualityRecordingAvailable: true,
            expectedUID: "airpods",
            expectedDataSourceName: nil,
            expectedPolarPattern: nil,
            expectBluetoothHighQualityRecording: true
        ),
    ])
    func planMatchesSelectionContract(_ testCase: PlannerCase) {
        let plan = VoiceInputAudioRoutePlanner.plan(
            availableInputs: testCase.inputs,
            bluetoothHighQualityRecordingAvailable: testCase.bluetoothHighQualityRecordingAvailable
        )

        #expect(plan.category == .record)
        #expect(plan.mode == .default)
        #expect(plan.options.contains(.allowBluetoothHFP))
        #expect(!plan.options.contains(.allowBluetoothA2DP))
        #expect(!plan.options.contains(.defaultToSpeaker))
        if #available(iOS 26.2, *) {
            #expect(!plan.options.contains(.farFieldInput))
        }
        #expect(
            plan.options.contains(.bluetoothHighQualityRecording)
                == testCase.expectBluetoothHighQualityRecording
        )
        #expect(plan.preferredInputUID == testCase.expectedUID)
        #expect(plan.preferredDataSourceName == testCase.expectedDataSourceName)
        #expect(plan.preferredPolarPattern == testCase.expectedPolarPattern)
    }

    @Test func stalePreferredInputResetsWhenUIDIsMissing() {
        let mic = VoiceInputAudioRouteInput.builtInMic(uid: "mic", sources: [])
        #expect(
            VoiceInputAudioRoutePlanner.shouldResetPreferredInput(
                preferredUID: "airpods",
                availableInputs: [mic]
            )
        )
        #expect(
            !VoiceInputAudioRoutePlanner.shouldResetPreferredInput(
                preferredUID: "mic",
                availableInputs: [mic]
            )
        )
        #expect(
            !VoiceInputAudioRoutePlanner.shouldResetPreferredInput(
                preferredUID: nil,
                availableInputs: [mic]
            )
        )
    }

    @Test func excludingBluetoothHFPFallsBackToBuiltInMic() {
        let inputs = [
            VoiceInputAudioRouteInput.bluetoothHFP(uid: "airpods"),
            VoiceInputAudioRouteInput.builtInMic(
                uid: "mic",
                sources: [
                    .init(
                        name: "Front",
                        orientation: .front,
                        supportedPolarPatterns: [.cardioid]
                    ),
                ]
            ),
        ]
        let plan = VoiceInputAudioRoutePlanner.plan(
            availableInputs: VoiceInputAudioRoutePlanner.excludingBluetoothHFP(inputs),
            bluetoothHighQualityRecordingAvailable: false
        )
        #expect(plan.preferredInputUID == "mic")
        #expect(plan.preferredDataSourceName == "Front")
        #expect(plan.preferredPolarPattern == .cardioid)
    }

    @Test func stalePreferredInputIsClearedBeforeActivate() {
        let mic = VoiceInputAudioRouteInput.builtInMic(uid: "mic", sources: [])
        #expect(
            VoiceInputAudioRoutePlanner.activateActions(
                preferredUID: "airpods",
                availableInputs: [mic],
                firstActivateSucceeded: true
            ) == ["resetPreferredInput", "setActive"]
        )
        #expect(
            VoiceInputAudioRoutePlanner.activateActions(
                preferredUID: "airpods",
                availableInputs: [mic],
                firstActivateSucceeded: false
            ) == ["resetPreferredInput", "setActive", "resetPreferredInput", "retrySetActive"]
        )
        #expect(
            VoiceInputAudioRoutePlanner.activateActions(
                preferredUID: "mic",
                availableInputs: [mic],
                firstActivateSucceeded: true
            ) == ["setActive"]
        )
    }
}

private extension VoiceInputAudioRouteInput {
    static func builtInMic(
        uid: String,
        sources: [VoiceInputAudioRouteDataSource]
    ) -> VoiceInputAudioRouteInput {
        VoiceInputAudioRouteInput(
            uid: uid,
            portType: .builtInMic,
            dataSources: sources
        )
    }

    static func bluetoothHFP(uid: String) -> VoiceInputAudioRouteInput {
        VoiceInputAudioRouteInput(
            uid: uid,
            portType: .bluetoothHFP,
            dataSources: []
        )
    }
}
#endif
