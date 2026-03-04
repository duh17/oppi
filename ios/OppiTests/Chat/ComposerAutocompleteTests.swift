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

    @Test func insertFileSuggestionForFile() {
        let result = ComposerAutocomplete.insertFileSuggestion(
            FileSuggestion(path: "src/chat/ChatView.swift", isDirectory: false),
            into: "open @src/chat/Chat"
        )
        #expect(result == "open @src/chat/ChatView.swift ")
    }

    @Test func insertFileSuggestionForDirectory() {
        let result = ComposerAutocomplete.insertFileSuggestion(
            FileSuggestion(path: "src/chat/", isDirectory: true),
            into: "open @src/ch"
        )
        #expect(result == "open @src/chat/")
    }

    @Test func insertFileSuggestionNoOpOutsideAtContext() {
        let result = ComposerAutocomplete.insertFileSuggestion(
            FileSuggestion(path: "README.md", isDirectory: false),
            into: "hello world"
        )
        #expect(result == "hello world")
    }

    @Test func insertFileSuggestionReplacesFullToken() {
        let result = ComposerAutocomplete.insertFileSuggestion(
            FileSuggestion(path: "README.md", isDirectory: false),
            into: "@RE"
        )
        #expect(result == "@README.md ")
    }

    @Test func fileSuggestionDisplayName() {
        #expect(FileSuggestion(path: "src/chat/ChatView.swift", isDirectory: false).displayName == "ChatView.swift")
        #expect(FileSuggestion(path: "src/chat/", isDirectory: true).displayName == "chat")
        #expect(FileSuggestion(path: "README.md", isDirectory: false).displayName == "README.md")
    }

    @Test func fileSuggestionParentPath() {
        #expect(FileSuggestion(path: "src/chat/ChatView.swift", isDirectory: false).parentPath == "src/chat/")
        #expect(FileSuggestion(path: "README.md", isDirectory: false).parentPath == nil)
    }

    @Test func fileSuggestionResultParsing() {
        let data: JSONValue = .object([
            "items": .array([
                .object(["path": .string("src/chat/ChatView.swift"), "isDirectory": .bool(false)]),
                .object(["path": .string("src/chat/"), "isDirectory": .bool(true)]),
            ]),
            "truncated": .bool(false),
        ])

        let result = FileSuggestionResult.from(data)
        #expect(result != nil)
        #expect(result?.items.count == 2)
        #expect(result?.items[0].path == "src/chat/ChatView.swift")
        #expect(result?.items[0].isDirectory == false)
        #expect(result?.items[1].path == "src/chat/")
        #expect(result?.items[1].isDirectory == true)
        #expect(result?.truncated == false)
    }

    @Test func fileSuggestionResultParsingNilData() {
        #expect(FileSuggestionResult.from(nil) == nil)
        #expect(FileSuggestionResult.from(.string("bad")) == nil)
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
