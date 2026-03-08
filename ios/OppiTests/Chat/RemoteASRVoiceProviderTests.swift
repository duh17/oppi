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
}
