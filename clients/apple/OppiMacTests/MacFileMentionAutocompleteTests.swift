import Foundation
import Testing
@testable import Oppi

@Suite("Mac file mention autocomplete")
struct MacFileMentionAutocompleteTests {
    @Test func detectsActiveAtTokenAtEndOfDraft() {
        #expect(ComposerAutocomplete.context(for: "please inspect @Sources/App") == .atFile(query: "Sources/App"))
        #expect(ComposerAutocomplete.context(for: "@") == .atFile(query: ""))
        #expect(ComposerAutocomplete.context(for: "please inspect @Sources/App ") == .none)
        #expect(ComposerAutocomplete.context(for: "no mention") == .none)
    }

    @Test func insertsSuggestionByReplacingActiveToken() {
        let suggestion = FileSuggestion(path: "Sources/App/main.swift", isDirectory: false)

        #expect(
            ComposerAutocomplete.insertFileMention(
                path: suggestion.path,
                isDirectory: suggestion.isDirectory,
                into: "please inspect @Sources/App"
            ) == "please inspect @Sources/App/main.swift "
        )
        #expect(
            ComposerAutocomplete.insertFileMention(
                path: suggestion.path,
                isDirectory: suggestion.isDirectory,
                into: "no mention"
            ) == "no mention"
        )
    }

    @Test func composerUsesSharedFileMentionAPIs() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionComposerBar.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("ComposerAutocomplete.context(for: draft)"))
        #expect(source.contains("case .atFile(let query)"))
        #expect(source.contains("FileSuggestion.ranked(query: query, paths: store.fileIndexPaths)"))
        #expect(source.contains("ComposerAutocomplete.insertFileMention("))
        #expect(!source.contains("MacFileMentionAutocomplete"))
    }
}
