import Foundation
import Testing
@testable import Oppi

@Suite("RemoteASRVoiceProvider")
@MainActor
struct RemoteASRVoiceProviderTests {
    @Test func prepareSessionRequiresEndpoint() async {
        let provider = RemoteASRVoiceProvider()

        await #expect(throws: VoiceInputError.self) {
            try await provider.prepareSession(
                context: VoiceProviderContext(
                    locale: Locale(identifier: "en-US"),
                    source: "test",
                    remoteEndpoint: nil
                )
            )
        }
    }

    @Test func prepareSessionUsesDefaultChunkProfileForNonCJKLocale() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "en-US"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )

        #expect(preparation.audioFormat == nil)
        #expect(preparation.pathTag == "remote")
        #expect(preparation.setupMetricTags["chunk_profile"] == "default")
        #expect(preparation.setupMetricTags["chunk_interval_ms"] == "1800")
        #expect(preparation.setupMetricTags["chunk_overlap_ms"] == "500")
        #expect(preparation.setupMetricTags["chunk_timeout_ms"] == "10000")
        #expect(preparation.setupMetricTags["stt_profile"] == "dictation")
        #expect(preparation.setupMetricTags["dictation_cleanup"] == "1")
        #expect(preparation.setupMetricTags["overlap_text_words"] == "20")
        #expect(preparation.setupMetricTags["language_hint"] == "auto")
    }

    @Test func prepareSessionUsesCJKChunkProfileForJapaneseLocale() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "ja-JP"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )

        #expect(preparation.setupMetricTags["chunk_profile"] == "cjk")
        #expect(preparation.setupMetricTags["chunk_interval_ms"] == "2000")
        #expect(preparation.setupMetricTags["chunk_overlap_ms"] == "500")
        #expect(preparation.setupMetricTags["chunk_timeout_ms"] == "10000")
    }

    @Test func makeSessionRequiresEndpoint() throws {
        let provider = RemoteASRVoiceProvider()

        #expect(throws: VoiceInputError.self) {
            try provider.makeSession(
                context: VoiceProviderContext(
                    locale: Locale(identifier: "en-US"),
                    source: "test",
                    remoteEndpoint: nil
                ),
                preparation: VoiceProviderPreparation(
                    audioFormat: nil,
                    pathTag: "remote",
                    setupMetricTags: [:]
                )
            )
        }
    }

    @Test func makeSessionCanBeCancelledBeforeStart() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "en-US"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )

        let session = try provider.makeSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "en-US"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            ),
            preparation: preparation
        )

        await session.cancel()
    }

    // MARK: - CJK locale detection

    @Test func prepareSessionUsesCJKProfileForChineseLocale() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "zh-CN"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )
        #expect(preparation.setupMetricTags["chunk_profile"] == "cjk")
        #expect(preparation.setupMetricTags["chunk_interval_ms"] == "2000")
    }

    @Test func prepareSessionUsesCJKProfileForKoreanLocale() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "ko-KR"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )
        #expect(preparation.setupMetricTags["chunk_profile"] == "cjk")
    }

    @Test func prepareSessionUsesDefaultProfileForGermanLocale() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "de-DE"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )
        #expect(preparation.setupMetricTags["chunk_profile"] == "default")
    }

    @Test func prepareSessionUsesDefaultProfileForSpanishLocale() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "es-ES"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )
        #expect(preparation.setupMetricTags["chunk_profile"] == "default")
    }

    // MARK: - Provider identity

    @Test func providerIdIsRemoteASR() {
        let provider = RemoteASRVoiceProvider()
        #expect(provider.id == .remoteASR)
    }

    @Test func providerEngineIsRemoteASR() {
        let provider = RemoteASRVoiceProvider()
        #expect(provider.engine == .remoteASR)
    }

    // MARK: - invalidateCache and cancelPreparation are no-ops

    @Test func invalidateCacheDoesNotCrash() {
        let provider = RemoteASRVoiceProvider()
        provider.invalidateCache()
    }

    @Test func cancelPreparationDoesNotCrash() {
        let provider = RemoteASRVoiceProvider()
        provider.cancelPreparation()
    }

    // MARK: - prewarm

    @Test func prewarmDoesNotThrow() async throws {
        let provider = RemoteASRVoiceProvider()
        try await provider.prewarm(
            context: VoiceProviderContext(
                locale: Locale(identifier: "en-US"),
                source: "test",
                remoteEndpoint: nil
            )
        )
        // prewarm is a no-op — just verify it doesn't throw
    }

    // MARK: - Metric tags completeness

    @Test func prepareSessionIncludesAllExpectedMetricTags() async throws {
        let provider = RemoteASRVoiceProvider()
        let preparation = try await provider.prepareSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "en-US"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            )
        )

        let tags = preparation.setupMetricTags
        let expectedKeys = [
            "chunk_profile", "chunk_interval_ms", "chunk_overlap_ms",
            "chunk_timeout_ms", "stt_profile", "dictation_cleanup",
            "overlap_text_words", "language_hint",
        ]
        for key in expectedKeys {
            #expect(tags[key] != nil, "Missing expected metric tag: \(key)")
        }
    }

    @Test func makeSessionProducesSessionWithEventAndAudioStreams() throws {
        let provider = RemoteASRVoiceProvider()
        let session = try provider.makeSession(
            context: VoiceProviderContext(
                locale: Locale(identifier: "en-US"),
                source: "test",
                remoteEndpoint: URL(string: "http://localhost:8321")
            ),
            preparation: VoiceProviderPreparation(
                audioFormat: nil,
                pathTag: "remote",
                setupMetricTags: [:]
            )
        )
        // Verify the session has the expected async streams
        _ = session.events
        _ = session.audioLevels
    }
}
