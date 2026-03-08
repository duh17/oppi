import Foundation

enum VoiceMetricPhase: String, Sendable {
    case prewarm
    case modelReady = "model_ready"
    case transcriberCreate = "transcriber_create"
    case analyzerStart = "analyzer_start"
    case audioStart = "audio_start"
    case total
    case firstResult = "first_result"
}

struct VoiceMetricAnnotation: Sendable {
    let engine: String
    let locale: String
    let source: String

    func tags(
        phase: VoiceMetricPhase? = nil,
        status: String? = nil,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var tags: [String: String] = [
            "engine": engine,
            "locale": locale,
            "source": source,
        ]

        if let phase {
            tags["phase"] = phase.rawValue
        }
        if let status {
            tags["status"] = status
        }

        for (key, value) in extra {
            guard !key.isEmpty else { continue }
            tags[key] = value
        }

        return tags
    }
}

enum VoiceInputTelemetry {
    static func userFacingMessage(for error: Error) -> String {
        if let voiceError = error as? VoiceInputError,
           let description = voiceError.errorDescription,
           !description.isEmpty {
            return description
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }

    static func metricErrorKind(for error: Error) -> String {
        if let voiceError = error as? VoiceInputError {
            return voiceError.telemetryCategory
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "network"
            case .cancelled:
                return "cancelled"
            default:
                return "url_error"
            }
        }

        if error is DecodingError {
            return "decode"
        }

        return "other"
    }

    static func recordRemoteChunkTelemetry(
        _ chunk: VoiceRemoteChunkTelemetry,
        annotation: VoiceMetricAnnotation
    ) {
        var tags = chunk.tags
        tags["chunk_status"] = chunk.status.rawValue
        tags["chunk_final"] = chunk.isFinal ? "1" : "0"
        if let errorCategory = chunk.errorCategory {
            tags["error_category"] = errorCategory
        }

        recordMetric(
            .voiceRemoteChunkAudioMs,
            valueMs: chunk.audioDurationMs,
            annotation: annotation,
            status: chunk.status.rawValue,
            extraTags: tags
        )

        if chunk.wavBytes > 0 {
            recordCountMetric(
                .voiceRemoteChunkBytes,
                value: chunk.wavBytes,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
        }

        if let uploadDurationMs = chunk.uploadDurationMs {
            recordMetric(
                .voiceRemoteChunkUploadMs,
                valueMs: uploadDurationMs,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
        }

        if let textLength = chunk.textLength, textLength > 0 {
            recordCountMetric(
                .voiceRemoteChunkChars,
                value: textLength,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
        }

        if chunk.status == .error {
            recordCountMetric(
                .voiceRemoteChunkError,
                value: 1,
                annotation: annotation,
                status: chunk.status.rawValue,
                extraTags: tags
            )
        }
    }

    static func recordMetric(
        _ metric: ChatMetricName,
        valueMs: Int,
        annotation: VoiceMetricAnnotation,
        phase: VoiceMetricPhase? = nil,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        let tags = annotation.tags(phase: phase, status: status, extra: extraTags)
        let clampedValue = max(0, valueMs)

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: metric,
                value: Double(clampedValue),
                unit: .ms,
                tags: tags
            )
        }
    }

    static func recordCountMetric(
        _ metric: ChatMetricName,
        value: Int,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        let tags = annotation.tags(status: status, extra: extraTags)
        let clampedValue = max(0, value)

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: metric,
                value: Double(clampedValue),
                unit: .count,
                tags: tags
            )
        }
    }
}
