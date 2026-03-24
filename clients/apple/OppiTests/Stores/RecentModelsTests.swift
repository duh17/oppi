import Foundation
import Testing
@testable import Oppi

@Suite("RecentModels")
@MainActor
struct RecentModelsTests {
    // Use a unique key per test run to avoid polluting real UserDefaults
    private func cleanup() {
        UserDefaults.standard.removeObject(forKey: "RecentModelIDs")
    }

    @Test func recordAndLoadRoundTrip() {
        cleanup()
        RecentModels.record("anthropic/claude-sonnet-4")
        let loaded = RecentModels.load()
        #expect(loaded == ["anthropic/claude-sonnet-4"])
        cleanup()
    }

    @Test func mostRecentAppearsFirst() {
        cleanup()
        RecentModels.record("anthropic/claude-sonnet-4")
        RecentModels.record("openai-codex/gpt-5.3-codex")
        let loaded = RecentModels.load()
        #expect(loaded == ["openai-codex/gpt-5.3-codex", "anthropic/claude-sonnet-4"])
        cleanup()
    }

    @Test func duplicateMovesToFront() {
        cleanup()
        RecentModels.record("anthropic/claude-sonnet-4")
        RecentModels.record("openai-codex/gpt-5.3-codex")
        RecentModels.record("anthropic/claude-sonnet-4")
        let loaded = RecentModels.load()
        #expect(loaded == ["anthropic/claude-sonnet-4", "openai-codex/gpt-5.3-codex"])
        cleanup()
    }

    @Test func capsAtFiveEntries() {
        cleanup()
        for i in 1...7 {
            RecentModels.record("provider/model-\(i)")
        }
        let loaded = RecentModels.load()
        #expect(loaded.count == 5)
        #expect(loaded.first == "provider/model-7")
        #expect(!loaded.contains("provider/model-1"))
        #expect(!loaded.contains("provider/model-2"))
        cleanup()
    }

    // Regression: the picker must match recorded IDs against server-format models
    // where model.id already contains the provider prefix (e.g. "anthropic/claude-opus-4-6").
    @Test func recentLookupMatchesServerFormatModels() {
        cleanup()

        // Server sends models with prefixed IDs
        let serverModels = [
            ModelInfo(id: "anthropic/claude-opus-4-6", name: "claude-opus-4-6", provider: "anthropic", contextWindow: 200_000),
            ModelInfo(id: "openai-codex/gpt-5.3-codex", name: "gpt-5.3-codex", provider: "openai-codex", contextWindow: 272_000),
        ]

        // Record uses ModelSwitchPolicy.fullModelID (the correct path)
        let recordedId = ModelSwitchPolicy.fullModelID(for: serverModels[0])
        RecentModels.record(recordedId)

        // Picker lookup must use the same fullModelID — not naive "provider/id" concat
        let recentIds = RecentModels.load()
        let lookup = Dictionary(
            serverModels.map { (ModelSwitchPolicy.fullModelID(for: $0), $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let matched = recentIds.compactMap { lookup[$0] }

        #expect(matched.count == 1)
        #expect(matched[0].id == "anthropic/claude-opus-4-6")
        cleanup()
    }

    // Regression: naive "provider/id" concat double-prefixes server-format IDs.
    @Test func naiveConcatWouldDoublePrefix() {
        let model = ModelInfo(
            id: "anthropic/claude-opus-4-6",
            name: "claude-opus-4-6",
            provider: "anthropic",
            contextWindow: 200_000
        )

        // This is what the old broken code did:
        let naiveId = "\(model.provider)/\(model.id)"
        #expect(naiveId == "anthropic/anthropic/claude-opus-4-6", "naive concat double-prefixes")

        // This is what fullModelID correctly produces:
        let correctId = ModelSwitchPolicy.fullModelID(for: model)
        #expect(correctId == "anthropic/claude-opus-4-6")

        #expect(naiveId != correctId, "mismatch proves the bug")
    }
}
