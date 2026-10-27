import Foundation
import Testing
@testable import Oppi

@Suite("VoiceInputTelemetry")
struct VoiceInputTelemetryTests {
    @Test func userFacingMessagePrefersVoiceInputErrorDescription() {
        let message = VoiceInputTelemetry.userFacingMessage(
            for: VoiceInputError.serverNotConnected
        )
        #expect(message.contains("not connected"))
    }

    @Test func userFacingMessageFallsBackToLocalizedError() {
        let message = VoiceInputTelemetry.userFacingMessage(
            for: TestVoiceError("custom localized")
        )
        #expect(message == "custom localized")
    }

    /// Every event of a take carries the same engine, locale, backend, and
    /// route, so a dashboard can group any of them by `stt_backend` or
    /// `stt_model` without losing rows. (A 16-tag cap once dropped these at
    /// random.)
    @Test func everyEventOfATakeCarriesTheSameIdentityTags() {
        var take = VoiceTakeTelemetry(voiceEngine: .server, locale: "en-US", trigger: "composer_mic")
        take.modelPath = .dictationAudioWs
        take.provider = VoiceProviderTelemetry(
            sttProvider: "oppi_server_dictation",
            sttProviderKind: .localServer,
            sttBackend: "mlx-server",
            sttModel: "parakeet-tdt-0.6b-v3"
        )
        take.route = VoiceAudioRouteTelemetry(routeMetadata: [
            "category": "AVAudioSessionCategoryPlayAndRecord",
            "mode": "AVAudioSessionModeDefault",
            "input_ports": "MicrophoneBuiltIn",
            "output_ports": "Speaker",
            "session_hz": "48000.0",
        ])

        let events: [any TelemetryEvent] = [
            take.setupEvent(timings: VoiceSetupTimings(totalMs: 310), includesPhases: true, status: .ok),
            take.firstResultEvent(latencyMs: 420, resultType: "volatile"),
            take.endEvent(
                finalizeMs: 210, sessionMs: 5400, audioDurationMs: 5100,
                resultUpdates: 14, previewFinalDeltaRatio: 0.08, inputLevelPeakRatio: 0.62
            ),
            take.captureErrorEvent(errorKind: .capturePipelineDead),
            take.cancelEvent(),
        ]

        for event in events {
            let tags = event.tagValues
            #expect(tags["voice_engine"] == "server", "\(type(of: event))")
            #expect(tags["stt_backend"] == "mlx-server", "\(type(of: event))")
            #expect(tags["stt_model"] == "parakeet-tdt-0.6b-v3", "\(type(of: event))")
            #expect(tags["trigger"] == "composer_mic", "\(type(of: event))")
            #expect(tags["audio_inputs"] == "MicrophoneBuiltIn", "\(type(of: event))")
        }
    }

    @Test func failedSetupReportsOnlyItsTotal() {
        let take = VoiceTakeTelemetry(voiceEngine: .speech, locale: "ja-JP", trigger: "test")
        let event = take.setupEvent(
            timings: VoiceSetupTimings(modelReadyMs: 40, totalMs: 900),
            includesPhases: false,
            status: .error,
            errorKind: .timeout
        )

        #expect(event.fieldValues == ["total_ms": 900])
        #expect(event.tagValues["status"] == "error")
        #expect(event.tagValues["error_kind"] == "timeout")
    }

    @Test func successfulSetupReportsEveryPhaseInOneEvent() {
        let take = VoiceTakeTelemetry(voiceEngine: .dictation, locale: "en-US", trigger: "test")
        let event = take.setupEvent(
            timings: VoiceSetupTimings(
                modelReadyMs: 40, transcriberCreateMs: 20, analyzerStartMs: 15,
                audioSessionMs: 90, audioStartMs: 60, totalMs: 310
            ),
            includesPhases: true,
            status: .ok
        )

        #expect(event.fieldValues == [
            "total_ms": 310, "model_ready_ms": 40, "transcriber_create_ms": 20,
            "analyzer_start_ms": 15, "audio_session_ms": 90, "audio_start_ms": 60,
        ])
    }

    @Test func routePortListsJoinWithASlashAndKeepTheFallbackFlag() {
        var route = VoiceAudioRouteTelemetry(routeMetadata: [
            "input_ports": "BluetoothHFP,MicrophoneBuiltIn",
            "output_ports": "",
        ])
        #expect(route.inputs == "BluetoothHFP/MicrophoneBuiltIn")
        #expect(route.outputs == nil)

        route.builtInFallback = true
        let refreshed = route.refreshed(from: ["input_ports": "MicrophoneBuiltIn"])
        #expect(refreshed.inputs == "MicrophoneBuiltIn")
        #expect(refreshed.builtInFallback)
        // The slash survives the server's name-tag sanitizer; a comma would not.
        #expect(TelemetryName.sanitize("BluetoothHFP/MicrophoneBuiltIn") == "BluetoothHFP/MicrophoneBuiltIn")
        #expect(TelemetryName.sanitize("BluetoothHFP,MicrophoneBuiltIn") == "unknown")
    }

    @Test func negativeDurationsClampToZero() {
        let take = VoiceTakeTelemetry(voiceEngine: .speech, locale: "en-US", trigger: "test")
        #expect(take.prewarmEvent(durationMs: -5, status: .ok).fieldValues == ["duration_ms": 0])
        #expect(take.firstResultEvent(latencyMs: -1, resultType: "final").fieldValues == ["duration_ms": 0])
    }
}
