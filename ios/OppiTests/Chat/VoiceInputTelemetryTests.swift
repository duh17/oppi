import Foundation
import Testing
@testable import Oppi

@Suite("VoiceInputTelemetry")
struct VoiceInputTelemetryTests {
    @Test func userFacingMessagePrefersVoiceInputErrorDescription() {
        let message = VoiceInputTelemetry.userFacingMessage(
            for: VoiceInputError.remoteEndpointNotConfigured
        )
        #expect(message.contains("not configured"))
    }

    @Test func userFacingMessageFallsBackToLocalizedError() {
        let message = VoiceInputTelemetry.userFacingMessage(
            for: TestVoiceError("custom localized")
        )
        #expect(message == "custom localized")
    }

    @Test func metricErrorKindCategorizesKnownErrorTypes() {
        #expect(VoiceInputTelemetry.metricErrorKind(for: VoiceInputError.remoteDecodeFailed) == "decode")
        #expect(VoiceInputTelemetry.metricErrorKind(for: URLError(.timedOut)) == "timeout")
        #expect(VoiceInputTelemetry.metricErrorKind(for: URLError(.cannotConnectToHost)) == "network")
        #expect(VoiceInputTelemetry.metricErrorKind(for: URLError(.cancelled)) == "cancelled")
        #expect(VoiceInputTelemetry.metricErrorKind(for: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))) == "decode")
        #expect(VoiceInputTelemetry.metricErrorKind(for: NSError(domain: "test", code: 1)) == "other")
    }

    @Test func recordMetricClampsNegativeValuesAndBuildsTags() {
        let recorder = TestMetricRecorder.install()
        defer { recorder.uninstall() }

        VoiceInputTelemetry.recordMetric(
            .voiceSetupMs,
            valueMs: -5,
            annotation: VoiceMetricAnnotation(engine: "dictation", locale: "en-US", source: "composer"),
            phase: .audioStart,
            status: "ok",
            extraTags: ["path": "cold", "": "ignored"]
        )

        let samples = recorder.samples
        #expect(samples.count == 1)
        #expect(samples[0].metric == .voiceSetupMs)
        #expect(samples[0].value == 0)
        #expect(samples[0].unit == .ms)
        #expect(samples[0].tags == [
            "engine": "dictation",
            "locale": "en-US",
            "source": "composer",
            "phase": "audio_start",
            "status": "ok",
            "path": "cold",
        ])
    }

    @Test func recordCountMetricClampsNegativeValuesAndBuildsTags() {
        let recorder = TestMetricRecorder.install()
        defer { recorder.uninstall() }

        VoiceInputTelemetry.recordCountMetric(
            .voiceRemoteChunkBytes,
            value: -10,
            annotation: VoiceMetricAnnotation(engine: "remote", locale: "ja-JP", source: "mic"),
            status: "error",
            extraTags: ["host": "mac-studio"]
        )

        let samples = recorder.samples
        #expect(samples.count == 1)
        #expect(samples[0].metric == .voiceRemoteChunkBytes)
        #expect(samples[0].value == 0)
        #expect(samples[0].unit == .count)
        #expect(samples[0].tags == [
            "engine": "remote",
            "locale": "ja-JP",
            "source": "mic",
            "status": "error",
            "host": "mac-studio",
        ])
    }

    @Test func recordRemoteChunkTelemetryEmitsExpectedSuccessMetrics() {
        let recorder = TestMetricRecorder.install()
        defer { recorder.uninstall() }

        VoiceInputTelemetry.recordRemoteChunkTelemetry(
            VoiceRemoteChunkTelemetry(
                status: .success,
                isFinal: true,
                sampleCount: 32000,
                audioDurationMs: 2000,
                wavBytes: 64000,
                uploadDurationMs: 180,
                textLength: 12,
                errorCategory: nil,
                tags: ["host": "mac-studio", "chunk_profile": "default"]
            ),
            annotation: VoiceMetricAnnotation(engine: "remote", locale: "en-US", source: "composer")
        )

        let metrics = recorder.samples.map(\.metric)
        #expect(metrics == [
            .voiceRemoteChunkAudioMs,
            .voiceRemoteChunkBytes,
            .voiceRemoteChunkUploadMs,
            .voiceRemoteChunkChars,
        ])

        let audio = recorder.samples[0]
        #expect(audio.tags["chunk_status"] == "success")
        #expect(audio.tags["chunk_final"] == "1")
        #expect(audio.tags["host"] == "mac-studio")
        #expect(audio.tags["chunk_profile"] == "default")
    }

    @Test func recordRemoteChunkTelemetryEmitsErrorCounterOnlyForErrors() {
        let recorder = TestMetricRecorder.install()
        defer { recorder.uninstall() }

        VoiceInputTelemetry.recordRemoteChunkTelemetry(
            VoiceRemoteChunkTelemetry(
                status: .error,
                isFinal: false,
                sampleCount: 8000,
                audioDurationMs: 500,
                wavBytes: 16000,
                uploadDurationMs: nil,
                textLength: nil,
                errorCategory: "timeout",
                tags: ["host": "mac-studio"]
            ),
            annotation: VoiceMetricAnnotation(engine: "remote", locale: "en-US", source: "composer")
        )

        let metrics = recorder.samples.map(\.metric)
        #expect(metrics == [
            .voiceRemoteChunkAudioMs,
            .voiceRemoteChunkBytes,
            .voiceRemoteChunkError,
        ])
        #expect(recorder.samples.last?.tags["error_category"] == "timeout")
        #expect(recorder.samples.last?.value == 1)
    }
}

private struct RecordedMetric: Equatable {
    let metric: ChatMetricName
    let value: Double
    let unit: ChatMetricUnit
    let tags: [String: String]
}

private final class TestMetricRecorder {
    private(set) var samples: [RecordedMetric] = []

    static func install() -> TestMetricRecorder {
        let recorder = TestMetricRecorder()
        VoiceInputTelemetry._recordMetricForTesting = { metric, value, unit, tags in
            recorder.samples.append(.init(metric: metric, value: value, unit: unit, tags: tags))
        }
        return recorder
    }

    func uninstall() {
        VoiceInputTelemetry._recordMetricForTesting = nil
    }
}
