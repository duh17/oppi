import Testing
import Foundation
@testable import Oppi

@Suite("FileSuggestion insertion")
struct FileSuggestionInsertionTests {

    // MARK: - Insertion text output

    @Test func fileInsertionAddsTrailingSpace() {
        let suggestion = FileSuggestion(path: "ios/Oppi/ChatView.swift", isDirectory: false)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "fix @ios/Oppi/Chat")
        #expect(result == "fix @ios/Oppi/ChatView.swift ")
    }

    @Test func directoryInsertionAddsTrailingSlashNoSpace() {
        let suggestion = FileSuggestion(path: "ios/Oppi/", isDirectory: true)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "look at @ios/O")
        #expect(result == "look at @ios/Oppi/")
    }

    @Test func insertionAtStartOfMessage() {
        let suggestion = FileSuggestion(path: "README.md", isDirectory: false)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "@READ")
        #expect(result == "@README.md ")
    }

    @Test func insertionWithEmptyAtQuery() {
        let suggestion = FileSuggestion(path: "package.json", isDirectory: false)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "@")
        #expect(result == "@package.json ")
    }

    @Test func insertionLeavesLeadingTextUntouched() {
        let suggestion = FileSuggestion(path: "src/index.ts", isDirectory: false)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "please update @src/ind")
        #expect(result.hasPrefix("please update "))
        #expect(result == "please update @src/index.ts ")
    }

    @Test func insertionNoOpWhenNoAtToken() {
        let suggestion = FileSuggestion(path: "README.md", isDirectory: false)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "no trigger here")
        #expect(result == "no trigger here")
    }

    @Test func insertionNoOpAfterWhitespace() {
        // Token is complete once a space appears — no active @-token.
        let suggestion = FileSuggestion(path: "README.md", isDirectory: false)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "@old ")
        #expect(result == "@old ")
    }

    @Test func fileInsertionResultEndsWithSpace() {
        let suggestion = FileSuggestion(path: "src/utils.ts", isDirectory: false)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "@src/ut")
        #expect(result.hasSuffix(" "))
    }

    @Test func directoryInsertionResultEndsWithSlash() {
        let suggestion = FileSuggestion(path: "src/utils/", isDirectory: true)
        let result = ComposerAutocomplete.insertFileSuggestion(suggestion, into: "@src/ut")
        #expect(result.hasSuffix("/"))
        #expect(!result.hasSuffix(" "))
    }

    // MARK: - FileSuggestion model

    @Test func displayNameForNestedFile() {
        let s = FileSuggestion(path: "ios/Oppi/Chat/ChatView.swift", isDirectory: false)
        #expect(s.displayName == "ChatView.swift")
    }

    @Test func displayNameForTopLevelFile() {
        #expect(FileSuggestion(path: "Makefile", isDirectory: false).displayName == "Makefile")
    }

    @Test func displayNameForDirectory() {
        // Directory path has trailing slash — displayName strips it.
        #expect(FileSuggestion(path: "ios/Oppi/Chat/", isDirectory: true).displayName == "Chat")
    }

    @Test func displayNameForRootDirectory() {
        #expect(FileSuggestion(path: "src/", isDirectory: true).displayName == "src")
    }

    @Test func parentPathForNestedFile() {
        let s = FileSuggestion(path: "src/chat/ChatView.swift", isDirectory: false)
        #expect(s.parentPath == "src/chat/")
    }

    @Test func parentPathNilForTopLevelFile() {
        #expect(FileSuggestion(path: "README.md", isDirectory: false).parentPath == nil)
    }

    @Test func parentPathForNestedDirectory() {
        // Directory: trailing slash stripped before lastIndex search.
        let s = FileSuggestion(path: "src/chat/", isDirectory: true)
        #expect(s.parentPath == "src/")
    }

    @Test func idIsPath() {
        let s = FileSuggestion(path: "foo/bar.swift", isDirectory: false)
        #expect(s.id == "foo/bar.swift")
    }

    // MARK: - FileSuggestionResult decoding

    @Test func resultDecodesSuccessPayload() {
        let data: JSONValue = .object([
            "items": .array([
                .object(["path": .string("src/main.ts"), "isDirectory": .bool(false)]),
                .object(["path": .string("src/"), "isDirectory": .bool(true)]),
            ]),
            "truncated": .bool(true),
        ])

        let result = FileSuggestionResult.from(data)
        #expect(result != nil)
        #expect(result?.items.count == 2)
        #expect(result?.items[0].path == "src/main.ts")
        #expect(result?.items[0].isDirectory == false)
        #expect(result?.items[1].path == "src/")
        #expect(result?.items[1].isDirectory == true)
        #expect(result?.truncated == true)
    }

    @Test func resultDecodesEmptyItems() {
        let data: JSONValue = .object(["items": .array([]), "truncated": .bool(false)])
        let result = FileSuggestionResult.from(data)
        #expect(result?.items.isEmpty == true)
        #expect(result?.truncated == false)
    }

    @Test func resultSkipsMalformedItems() {
        let data: JSONValue = .object([
            "items": .array([
                .object(["path": .string("ok.swift"), "isDirectory": .bool(false)]),
                .string("bad-entry"),
                .object(["path": .string("missing-isDirectory-key")]),
            ]),
            "truncated": .bool(false),
        ])

        let result = FileSuggestionResult.from(data)
        #expect(result?.items.count == 1)
        #expect(result?.items[0].path == "ok.swift")
    }

    @Test func resultNilForNonObjectData() {
        #expect(FileSuggestionResult.from(nil) == nil)
        #expect(FileSuggestionResult.from(.string("oops")) == nil)
        #expect(FileSuggestionResult.from(.bool(true)) == nil)
    }

    @Test func resultDefaultsTruncatedToFalse() {
        // No "truncated" key — defaults to false.
        let data: JSONValue = .object(["items": .array([])])
        let result = FileSuggestionResult.from(data)
        #expect(result?.truncated == false)
    }

    // MARK: - ServerConnection state management

    @MainActor
    @Test func clearFileSuggestionsEmptiesItems() {
        let conn = makeTestConnection()
        conn.fileSuggestions = [
            FileSuggestion(path: "README.md", isDirectory: false),
        ]
        conn.clearFileSuggestions()
        #expect(conn.fileSuggestions.isEmpty)
    }

    @MainActor
    @Test func clearFileSuggestionsCancelsTask() {
        let conn = makeTestConnection()
        let task = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(60))
        }
        conn.fileSuggestionTask = task
        conn.clearFileSuggestions()
        #expect(task.isCancelled)
        #expect(conn.fileSuggestionTask == nil)
    }

    @MainActor
    @Test func fetchFileSuggestionsCancelsPreviousTask() {
        // Install a no-op send hook so sendCommandAwaitingResult doesn't fail
        // on the absent WS — the debounce sleep is cancelled before the send fires.
        let conn = makeTestConnection()
        conn._sendMessageForTesting = { _ in }

        let oldTask = Task<Void, Never> { @MainActor in
            try? await Task.sleep(for: .seconds(60))
        }
        conn.fileSuggestionTask = oldTask

        conn.fetchFileSuggestions(query: "src")

        #expect(oldTask.isCancelled, "Previous task must be cancelled when a new query starts")
    }

    @MainActor
    @Test func fetchFileSuggestionsReplacesTask() {
        let conn = makeTestConnection()
        conn._sendMessageForTesting = { _ in }

        conn.fetchFileSuggestions(query: "first")
        let task1 = conn.fileSuggestionTask

        conn.fetchFileSuggestions(query: "second")
        let task2 = conn.fileSuggestionTask

        #expect(task1 != nil)
        #expect(task2 != nil)
        // task1 must be cancelled; task2 is the live one.
        #expect(task1?.isCancelled == true)
    }

    @MainActor
    @Test func staleResponseDroppedAfterClear() async {
        // Simulate: request fires, result arrives AFTER clearFileSuggestions.
        // clearFileSuggestions cancels the task, so the result is never applied.
        let conn = makeTestConnection()
        var sentMessages: [ClientMessage] = []
        conn._sendMessageForTesting = { msg in sentMessages.append(msg) }

        conn.fetchFileSuggestions(query: "stale")
        conn.clearFileSuggestions()

        // Brief wait — debounce task should be cancelled, no message sent.
        try? await Task.sleep(for: .milliseconds(250))
        #expect(sentMessages.isEmpty, "Cancelled task must not dispatch a network message")
        #expect(conn.fileSuggestions.isEmpty)
    }
}
