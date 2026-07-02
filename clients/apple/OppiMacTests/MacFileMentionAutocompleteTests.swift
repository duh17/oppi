import Testing
@testable import Oppi

@Suite("Mac file mention autocomplete")
struct MacFileMentionAutocompleteTests {
    @Test func detectsActiveAtTokenAtEndOfDraft() {
        #expect(MacFileMentionAutocomplete.activeToken(in: "please inspect @Sources/App") == "Sources/App")
        #expect(MacFileMentionAutocomplete.activeToken(in: "@") == "")
        #expect(MacFileMentionAutocomplete.activeToken(in: "please inspect @Sources/App ") == nil)
        #expect(MacFileMentionAutocomplete.activeToken(in: "no mention") == nil)
    }

    @Test func insertsSuggestionByReplacingActiveToken() {
        let suggestion = MacFileMentionSuggestion(path: "Sources/App/main.swift", score: 1)

        #expect(
            MacFileMentionAutocomplete.insert(suggestion, into: "please inspect @Sources/App") ==
            "please inspect @Sources/App/main.swift "
        )
        #expect(MacFileMentionAutocomplete.insert(suggestion, into: "no mention") == "no mention")
    }

    @Test func suggestionsPreferExactAndFilenameMatches() {
        let paths = [
            "server/src/server.ts",
            "server/src/event-ring.ts",
            "clients/apple/OppiMac/Views/MacSessionShellViews.swift",
            "README.md",
        ]

        let serverResults = MacFileMentionAutocomplete.suggestions(for: "server.ts", paths: paths)
        let shellResults = MacFileMentionAutocomplete.suggestions(for: "session", paths: paths)

        #expect(serverResults.first?.path == "server/src/server.ts")
        #expect(shellResults.first?.path == "clients/apple/OppiMac/Views/MacSessionShellViews.swift")
    }

    @Test func emptyQueryReturnsShortReadablePaths() {
        let paths = [
            "clients/apple/OppiMac/Views/MacSessionShellViews.swift",
            "README.md",
            "server/src/server.ts",
        ]

        let results = MacFileMentionAutocomplete.suggestions(for: "", paths: paths, limit: 2)

        #expect(results.map(\.path) == ["README.md", "server/src/server.ts"])
    }
}
