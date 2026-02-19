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
