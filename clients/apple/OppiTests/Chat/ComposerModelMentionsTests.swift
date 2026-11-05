import Testing
import Foundation
@testable import Oppi

@Suite("Composer model mentions")
struct ComposerModelMentionsTests {
    private let catalog = [
        ModelInfo(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", provider: "anthropic", contextWindow: 200_000),
        ModelInfo(id: "claude-opus-5", name: "Claude Opus 5", provider: "anthropic", contextWindow: 200_000),
        ModelInfo(id: "gpt-5.5", name: "GPT 5.5", provider: "openai", contextWindow: 200_000),
        ModelInfo(id: "openai/gpt-5.5-mini", name: "GPT 5.5 Mini", provider: "openai", contextWindow: 200_000),
    ]

    private func ids(_ models: [ModelInfo]) -> [String] {
        models.map(ModelSwitchPolicy.fullModelID(for:))
    }

    @Test func queryMatchesNameIDAndProvider() {
        #expect(ids(ComposerModelMentions.suggestions(query: "sonnet", catalog: catalog, recentIDs: []))
            == ["anthropic/claude-sonnet-5-5"])
        #expect(ids(ComposerModelMentions.suggestions(query: "mini", catalog: catalog, recentIDs: []))
            == ["openai/gpt-5.5-mini"])
        #expect(ids(ComposerModelMentions.suggestions(query: "openai", catalog: catalog, recentIDs: []))
            == ["openai/gpt-5.5", "openai/gpt-5.5-mini"])
    }

    @Test func queryMatchesTheCanonicalIDWithItsProviderPrefix() {
        // The Sonnet id also matches by skipping a character, but only literal
        // matches show for a non-empty query.
        let result = ComposerModelMentions.suggestions(query: "anthropic/claude-o", catalog: catalog, recentIDs: [])
        #expect(ids(result) == ["anthropic/claude-opus-5"])
    }

    @Test func fuzzyOnlyMatchesAreDroppedForANonEmptyQuery() {
        // "Sora Nano" matches "son" only by skipping (s-o, then the next word's n).
        let fuzzyOnly = ModelInfo(id: "sora-nano", name: "Sora Nano", provider: "acme", contextWindow: 8_000)
        let result = ComposerModelMentions.suggestions(
            query: "son",
            catalog: [fuzzyOnly] + catalog,
            recentIDs: ["acme/sora-nano"]
        )
        #expect(ids(result) == ["anthropic/claude-sonnet-5-5"])
    }

    @Test func prefixRanksAboveWordStartAboveSubstring() {
        let substring = ModelInfo(id: "jasonic", name: "Jasonic", provider: "acme", contextWindow: 8_000)
        let wordStart = catalog[0]
        let prefix = ModelInfo(id: "sonar", name: "Sonar", provider: "acme", contextWindow: 8_000)
        let result = ComposerModelMentions.suggestions(
            query: "son",
            catalog: [substring, wordStart, prefix],
            recentIDs: [substring, wordStart].map(ModelSwitchPolicy.fullModelID(for:))
        )
        #expect(ids(result) == ["acme/sonar", "anthropic/claude-sonnet-5-5", "acme/jasonic"])
    }

    @Test func emptyQueryListsRecentModelsFirstThenTheCatalog() {
        let result = ComposerModelMentions.suggestions(
            query: "",
            catalog: catalog,
            recentIDs: ["openai/gpt-5.5-mini", "anthropic/claude-opus-5"]
        )
        #expect(ids(result) == ["openai/gpt-5.5-mini", "anthropic/claude-opus-5", "anthropic/claude-sonnet-5-5"])
    }

    @Test func recentModelBreaksATieBetweenEqualMatches() {
        let result = ComposerModelMentions.suggestions(
            query: "claude",
            catalog: catalog,
            recentIDs: ["anthropic/claude-opus-5"]
        )
        #expect(ids(result) == ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5-5"])
    }

    @Test func aRepeatedCanonicalIDShowsOnce() {
        let twice = catalog + [catalog[0]]
        let result = ComposerModelMentions.suggestions(query: "sonnet", catalog: twice, recentIDs: [])
        #expect(ids(result) == ["anthropic/claude-sonnet-5-5"])
    }

    @Test func resultsStopAtTheCap() {
        let many = (1...6).map {
            ModelInfo(id: "model-\($0)", name: "Model \($0)", provider: "acme", contextWindow: 8_000)
        }
        #expect(ComposerModelMentions.suggestions(query: "", catalog: many, recentIDs: []).count
            == ComposerModelMentions.maxSuggestions)
        #expect(ComposerModelMentions.suggestions(query: "model", catalog: many, recentIDs: []).count
            == ComposerModelMentions.maxSuggestions)
    }

    /// File-path queries stay file searches without a path rule: no model
    /// literally matches them. Model ids contain `/` and `.`, and typing one
    /// still offers its model.
    @Test func pathQueriesOfferNoModelsAndModelIDQueriesStillDo() {
        func result(_ query: String) -> [String] {
            ids(ComposerModelMentions.suggestions(query: query, catalog: catalog, recentIDs: []))
        }
        #expect(result("src/rou").isEmpty)
        #expect(result("Route.md").isEmpty)
        #expect(result("anthropic/claude-o").first == "anthropic/claude-opus-5")
        #expect(Set(result("gpt-5.")) == ["openai/gpt-5.5", "openai/gpt-5.5-mini"])
    }

    @Test func insertionReplacesTheActiveTokenWithTheCanonicalID() {
        let sonnet = catalog[0]
        #expect(ComposerModelMentions.insert(sonnet, into: "Use @son")
            == "Use anthropic/claude-sonnet-5-5 ")
        #expect(ComposerModelMentions.insert(sonnet, into: "@")
            == "anthropic/claude-sonnet-5-5 ")
        // A model id that already carries its provider is not prefixed twice.
        #expect(ComposerModelMentions.insert(catalog[3], into: "try @mini")
            == "try openai/gpt-5.5-mini ")
    }

    @Test func insertionLeavesTextWithoutAnActiveMentionAlone() {
        #expect(ComposerModelMentions.insert(catalog[0], into: "Use @son ") == "Use @son ")
        #expect(ComposerModelMentions.insert(catalog[0], into: "plain") == "plain")
    }
}
