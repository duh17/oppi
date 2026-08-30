import Foundation
import Testing
@testable import Oppi

@Suite("Mac composer slash autocomplete")
struct MacComposerAutocompleteTests {
    @Test func slashContextTriggersOnlyAtMessageStart() {
        #expect(ComposerAutocomplete.context(for: "/") == .slash(query: ""))
        #expect(ComposerAutocomplete.context(for: "/co") == .slash(query: "co"))
        #expect(ComposerAutocomplete.context(for: "please /co") == .none)
        #expect(ComposerAutocomplete.context(for: "/co ") == .none)
    }

    @Test func slashSuggestionsStayAvailableWhileBusy() {
        #expect(
            ComposerAutocomplete.context(for: "/compact", isBusy: true) == .slash(query: "compact")
        )
    }

    @Test func slashSuggestionsRankAndInsertFromSharedModel() {
        let commands = makeSlashCommands([
            ("copy", "Copy message", "prompt"),
            ("compact", "Compact context", "prompt"),
            ("copy", "Copy duplicate", "extension"),
        ])

        let suggestions = ComposerAutocomplete.slashSuggestions(query: "co", commands: commands)
        #expect(suggestions.map(\.name) == ["compact", "copy"])
        #expect(ComposerAutocomplete.insertSlashCommand(named: "compact", into: "/co") == "/compact ")
        #expect(ComposerAutocomplete.insertSlashCommand(named: "compact", into: "hello /co") == "hello /co")
    }

    @Test func emptyServerCommandsStillOfferLocalCompact() {
        let commands = ComposerAutocomplete.availableCommands(from: [])
        #expect(commands.map(\.name) == ["compact"])
        #expect(commands.first?.source == .builtin)

        let suggestions = ComposerAutocomplete.slashSuggestions(
            query: "",
            commands: commands
        )
        #expect(suggestions.map(\.name) == ["compact"])
    }

    @Test func recognizedSlashCommandQueuesFollowUpWhenBusy() {
        let commands = makeSlashCommands([
            ("check_agents", "Check agent status", "extension"),
        ])

        #expect(
            ComposerAutocomplete.streamingBehavior(
                for: "/check_agents now",
                isBusy: true,
                selected: .steer,
                commands: commands
            ) == .followUp
        )
        #expect(
            ComposerAutocomplete.streamingBehavior(
                for: "please compact",
                isBusy: true,
                selected: .steer,
                commands: commands
            ) == .steer
        )
    }

    @Test func fileMentionTokenStaysSharedWithSlashParser() {
        #expect(ComposerAutocomplete.context(for: "/compact") == .slash(query: "compact"))
        #expect(ComposerAutocomplete.context(for: "please inspect @Sources/App") == .atFile(query: "Sources/App"))
    }

    @Test func composerSourcePaintsSlashPaletteAndKeepsCmdReturnSend() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionComposerBar.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("ComposerAutocomplete.context(for: draft"))
        #expect(source.contains("ComposerAutocomplete.slashSuggestions"))
        #expect(source.contains("MacSlashCommandSuggestionList"))
        #expect(source.contains("insertSlashCommand"))
        #expect(source.contains(".keyboardShortcut(.return, modifiers: .command)"))
        #expect(!source.contains("NSEvent.addLocalMonitor"))
        #expect(!source.contains("NSEvent.addGlobalMonitor"))
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
