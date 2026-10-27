import Foundation
import Testing
@testable import Oppi

/// The Swift half of the telemetry cross-boundary golden. The generated event
/// structs must encode the same upload as `protocol/telemetry-events-upload.json`
/// (JSONEncoder, sorted keys), which the server's ingest test requires it to
/// accept in full. A change to a field, a tag, or an encoding rule shows up
/// here as a byte difference.
@Suite("Telemetry events upload contract")
struct TelemetryEventsUploadContractTests {
    private static let baseTs: Int64 = 1_793_000_000_000

    private static func goldenUpload() -> TelemetryEventUploadRequest {
        let session = "sess-golden-1"
        let events: [TelemetryEventPayload] = [
            TelemetryEventPayload(
                AppSessionLoad(durationMs: 412, items: 87, loadPath: .cacheHit),
                ts: baseTs, sessionId: session, workspaceId: "ws-golden-1"
            ),
            TelemetryEventPayload(
                AppTraceFetch(durationMs: 950.5, status: .error, errorKind: .timeout),
                ts: baseTs + 1, sessionId: session
            ),
            TelemetryEventPayload(
                AppCommand(
                    sendMs: 12, roundtripMs: 640, command: "get_queue",
                    transport: .lan, status: .ok
                ),
                ts: baseTs + 2, sessionId: session
            ),
            TelemetryEventPayload(
                AppCellConfigure(
                    durationMs: 3, expanded: true, rowType: "tool", tool: "bash",
                    contentType: "code", outputSize: TelemetryTag.OutputSize(bytes: 30_000)
                ),
                ts: baseTs + 3, sessionId: session
            ),
            TelemetryEventPayload(
                AppDictationSetup(
                    totalMs: 310, modelReadyMs: 40, transcriberCreateMs: 20,
                    analyzerStartMs: 15, audioSessionMs: 90, audioStartMs: 60,
                    audioSampleRate: 48_000,
                    voiceEngine: .server, locale: "en-US", trigger: "composer_mic",
                    modelPath: .dictationAudioWs,
                    sttProvider: "oppi_server_dictation", sttProviderKind: .localServer,
                    sttBackend: "mlx-server", sttModel: "parakeet-tdt-0.6b-v3",
                    audioCategory: "AVAudioSessionCategoryPlayAndRecord",
                    audioMode: "AVAudioSessionModeDefault",
                    audioInputs: "MicrophoneBuiltIn", audioOutputs: "Speaker",
                    status: .ok
                ),
                ts: baseTs + 4, sessionId: session
            ),
            TelemetryEventPayload(
                AppDictationEnd(
                    finalizeMs: 210, sessionMs: 5_400, audioDurationMs: 5_100,
                    resultUpdates: 14, previewFinalDeltaRatio: 0.08, inputLevelPeakRatio: 0.62,
                    voiceEngine: .speech, locale: "de-DE"
                ),
                ts: baseTs + 5
            ),
            TelemetryEventPayload(
                AppDeviceResources(
                    cpuPct: 18.25, memoryMb: 231.5, memoryAvailableMb: 1_420, thermalState: 1,
                    screen: "chat", streamState: "queueSync.initial",
                    agents: .running, voice: .off
                ),
                ts: baseTs + 6
            ),
            TelemetryEventPayload(
                // A screen label with a space is not a safe identifier: it encodes as `unknown`.
                AppMemoryWarning(
                    footprintBeforeMb: 612, footprintAfterMb: 540,
                    cacheEntries: 31, cacheBytes: 18_874_368, screen: "chat session"
                ),
                ts: baseTs + 7
            ),
            TelemetryEventPayload(
                AppMessageQueueStartMiss(queueVersion: 9, intent: .followUp),
                ts: baseTs + 8, sessionId: session
            ),
            TelemetryEventPayload(
                AppAppEventStreamDecodeError(errorKind: .decode),
                ts: baseTs + 9
            ),
            TelemetryEventPayload(
                AppTimelineJank(jankPct: 12.5, cycles: 240, hitches: 30),
                ts: baseTs + 10, sessionId: session
            ),
        ]
        return TelemetryEventUploadRequest(
            generatedAt: baseTs + 20,
            client: TelemetryClientInfo(
                kind: .ios,
                appVersion: "1.53.0",
                buildNumber: "412",
                gitCommit: "0123456789ab",
                osVersion: "26.1",
                deviceModel: "iPhone17,1",
                appInstanceId: "app-instance-golden",
                bootId: "boot-golden"
            ),
            events: events
        )
    }

    @Test func generatedStructsEncodeTheGoldenUploadByteForByte() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var encoded = try encoder.encode(Self.goldenUpload())
        encoded.append(UInt8(ascii: "\n"))

        let golden = try ProtocolFixtures.data("telemetry-events-upload.json")
        #expect(
            encoded == golden,
            "Swift encoding differs from protocol/telemetry-events-upload.json:\n\(String(decoding: encoded, as: UTF8.self))"
        )
    }

    /// The production uploader encodes compact sorted keys; its bytes carry the same content.
    @Test func uploaderEncodingMatchesTheGoldenContent() throws {
        let compact = try APIClient.telemetryEncoder.encode(Self.goldenUpload())
        let compactObject = try JSONSerialization.jsonObject(with: compact) as? NSDictionary
        let golden = try JSONSerialization.jsonObject(with: ProtocolFixtures.data("telemetry-events-upload.json")) as? NSDictionary
        #expect(compactObject == golden)
    }
}
