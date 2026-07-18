import Testing
@testable import Oppi

// swiftlint:disable large_tuple

@Suite("ComposerAutocomplete")
struct ComposerAutocompleteTests {

    @Test func slashContextAtMessageStart() {
        #expect(ComposerAutocomplete.context(for: "/co") == .slash(query: "co"))
    }

    @Test func slashContextNotTriggeredMidSentence() {
        #expect(ComposerAutocomplete.context(for: "please /co") == .none)
    }

    @Test func slashContextEndsAfterWhitespace() {
        #expect(ComposerAutocomplete.context(for: "/co ") == .none)
    }

    @Test func atFileContextDetectedForTrailingToken() {
        #expect(ComposerAutocomplete.context(for: "open @src") == .atFile(query: "src"))
    }

    @Test func slashSuggestionsDedupedAndSorted() {
        let commands = makeSlashCommands([
            ("copy", "Copy message", "prompt"),
            ("compact", "Compact context", "prompt"),
            ("copy", "Copy duplicate", "extension"),
        ])

        let suggestions = ComposerAutocomplete.slashSuggestions(query: "co", commands: commands)
        #expect(suggestions.map(\.name) == ["compact", "copy"])
    }

    @Test func insertSlashCommandReplacesCurrentToken() {
        let updated = ComposerAutocomplete.insertSlashCommand(named: "compact", into: "/co")
        #expect(updated == "/compact ")
    }

    @Test func insertSlashCommandNoOpOutsideSlashContext() {
        let unchanged = ComposerAutocomplete.insertSlashCommand(named: "compact", into: "hello /co")
        #expect(unchanged == "hello /co")
    }

    @Test func slashSuggestionsRequireServerCommands() {
        let suggestions = ComposerAutocomplete.slashSuggestions(query: "comp", commands: [])
        #expect(suggestions.isEmpty)
    }

    @Test func atFileContextDetectedMidSentence() {
        #expect(ComposerAutocomplete.context(for: "look at @src/chat") == .atFile(query: "src/chat"))
    }

    @Test func atFileContextWithEmptyQuery() {
        #expect(ComposerAutocomplete.context(for: "@") == .atFile(query: ""))
    }

    @Test func atFileContextEndsAfterWhitespace() {
        #expect(ComposerAutocomplete.context(for: "@src/chat ") == .none)
    }

    // MARK: - Fuzzy Match

    @Test func fuzzyMatchFindsNonContiguousMatches() {
        let commands = makeSlashCommands([
            ("compact", "Compact context", "prompt"),
            ("copy", "Copy message", "prompt"),
        ])
        let suggestions = ComposerAutocomplete.slashSuggestions(query: "cmpct", commands: commands)
        #expect(suggestions.map(\.name) == ["compact"])
    }

    @Test func fuzzyMatchRanksContiguousPrefixHigher() {
        let commands = makeSlashCommands([
            ("disco", "Discover something", "prompt"),
            ("compact", "Compact context", "prompt"),
            ("copy", "Copy message", "prompt"),
        ])
        let suggestions = ComposerAutocomplete.slashSuggestions(query: "co", commands: commands)
        #expect(suggestions.count == 3)
        #expect(suggestions[0].name == "compact")
        #expect(suggestions[1].name == "copy")
        #expect(suggestions[2].name == "disco")
    }

    @Test func fuzzyMatchHandlesSubsequenceTypoPatterns() {
        let commands = makeSlashCommands([
            ("check_agents", "Check agents", "prompt"),
            ("compact", "Compact context", "prompt"),
        ])
        let suggestions = ComposerAutocomplete.slashSuggestions(query: "chek", commands: commands)
        #expect(suggestions.map(\.name) == ["check_agents"])
    }

    @Test func emptyQueryReturnsAllSortedAlphabetically() {
        let commands = makeSlashCommands([
            ("copy", "Copy message", "prompt"),
            ("ask", "Ask question", "prompt"),
            ("build", "Build project", "prompt"),
        ])
        let suggestions = ComposerAutocomplete.slashSuggestions(query: "", commands: commands)
        #expect(suggestions.map(\.name) == ["ask", "build", "copy"])
    }

    @Test func noMatchReturnsEmpty() {
        let commands = makeSlashCommands([
            ("compact", "Compact context", "prompt"),
            ("copy", "Copy message", "prompt"),
        ])
        let suggestions = ComposerAutocomplete.slashSuggestions(query: "xyz", commands: commands)
        #expect(suggestions.isEmpty)
    }

    // MARK: - Busy Mode (Steering / Follow-up)

    @Test func atFileAvailableWhenBusy() {
        #expect(
            ComposerAutocomplete.context(for: "open @src", isBusy: true)
            == .atFile(query: "src")
        )
    }

    @Test func atFileWithEmptyQueryAvailableWhenBusy() {
        #expect(
            ComposerAutocomplete.context(for: "@", isBusy: true)
            == .atFile(query: "")
        )
    }

    @Test func slashAvailableWhenBusy() {
        #expect(
            ComposerAutocomplete.context(for: "/co", isBusy: true)
            == .slash(query: "co")
        )
    }

    @Test func slashAllowedWhenNotBusy() {
        #expect(
            ComposerAutocomplete.context(for: "/co", isBusy: false)
            == .slash(query: "co")
        )
    }

    @Test func atFileAvailableWhenNotBusy() {
        #expect(
            ComposerAutocomplete.context(for: "@src/chat", isBusy: false)
            == .atFile(query: "src/chat")
        )
    }

    @Test func plainTextReturnsNoneWhenBusy() {
        #expect(
            ComposerAutocomplete.context(for: "just some text", isBusy: true)
            == .none
        )
    }

    @Test @MainActor func fileSuggestionQueryFiresWhenBusy() {
        var receivedQuery: String??
        var callCount = 0
        ComposerShared.notifyFileSuggestionContext(
            for: "check @main",
            isBusy: true,
            onFileSuggestionQuery: { q in receivedQuery = q; callCount += 1 }
        )
        #expect(callCount == 1)
        #expect(receivedQuery == "main")
    }

    @Test @MainActor func fileSuggestionQueryClearedForPlainTextWhenBusy() {
        var called = false
        var receivedNil = false
        ComposerShared.notifyFileSuggestionContext(
            for: "just text",
            isBusy: true,
            onFileSuggestionQuery: { q in called = true; receivedNil = (q == nil) }
        )
        #expect(called)
        #expect(receivedNil) // query should be nil for plain text
    }

    // File suggestion insertion, model, and parsing tests live in
    // FileSuggestionInsertionTests.swift (27 tests with thorough edge cases).

    private func makeSlashCommands(
        _ commands: [(name: String, description: String, source: String)]
    ) -> [SlashCommand] {
        commands.compactMap { command in
            SlashCommand(.object([
                "name": .string(command.name),
                "description": .string(command.description),
                "source": .string(command.source),
            ]))
        }
    }
}
