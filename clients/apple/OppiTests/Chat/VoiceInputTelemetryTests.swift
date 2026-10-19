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
            "ui_locale": "en-US",
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
            .dictationResultUpdates,
            value: -10,
            annotation: VoiceMetricAnnotation(engine: "remote", locale: "ja-JP", source: "mic"),
            status: "error",
            extraTags: ["host": "mac-studio"]
        )

        let samples = recorder.samples
        #expect(samples.count == 1)
        #expect(samples[0].metric == .dictationResultUpdates)
        #expect(samples[0].value == 0)
        #expect(samples[0].unit == .count)
        #expect(samples[0].tags == [
            "engine": "remote",
            "locale": "ja-JP",
            "ui_locale": "ja-JP",
            "source": "mic",
            "status": "error",
            "host": "mac-studio",
        ])
    }

    @Test func recordRatioMetricClampsNegativeValuesAndUsesRatioUnit() {
        let recorder = TestMetricRecorder.install()
        defer { recorder.uninstall() }

        VoiceInputTelemetry.recordRatioMetric(
            .dictationPreviewFinalDelta,
            value: -0.2,
            annotation: VoiceMetricAnnotation(engine: "remote", locale: "en-US", source: "composer"),
            status: "ok",
            extraTags: ["provider_id": "oppi_server_dictation"]
        )

        let samples = recorder.samples
        #expect(samples.count == 1)
        #expect(samples[0].metric == .dictationPreviewFinalDelta)
        #expect(samples[0].value == 0)
        #expect(samples[0].unit == .ratio)
        #expect(samples[0].tags["ui_locale"] == "en-US")
        #expect(samples[0].tags["provider_id"] == "oppi_server_dictation")
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
