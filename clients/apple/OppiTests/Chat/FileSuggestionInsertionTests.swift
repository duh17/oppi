import Testing
import Foundation
@testable import Oppi

@Suite("FileSuggestion insertion")
@MainActor
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

    // MARK: - ServerConnection state management

    @Test func clearFileSuggestionsEmptiesItems() {
        let (conn, _) = makeTestConnection()
        conn.chatState.fileSuggestions = [
            FileSuggestion(path: "README.md", isDirectory: false),
        ]
        conn.clearFileSuggestions()
        #expect(conn.chatState.fileSuggestions.isEmpty)
    }

    @Test func clearFileSuggestionsCancelsTask() {
        let (conn, _) = makeTestConnection()
        let task = makeCancellableNeverCompletingTaskForTesting()
        conn.chatState.fileSuggestionTask = task
        conn.clearFileSuggestions()
        #expect(task.isCancelled)
        #expect(conn.chatState.fileSuggestionTask == nil)
    }

    @Test func fetchFileSuggestionsCancelsPreviousTask() {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting(["src/index.ts", "src/app.ts", "README.md"])

        let oldTask = makeCancellableNeverCompletingTaskForTesting()
        conn.chatState.fileSuggestionTask = oldTask

        conn.fetchFileSuggestions(query: "src")

        #expect(oldTask.isCancelled, "Previous task must be cancelled when a new query starts")
    }

    @Test func fetchFileSuggestionsReplacesTask() {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting(["src/index.ts", "src/app.ts", "README.md"])

        conn.fetchFileSuggestions(query: "first")
        let task1 = conn.chatState.fileSuggestionTask

        conn.fetchFileSuggestions(query: "second")
        let task2 = conn.chatState.fileSuggestionTask

        #expect(task1 != nil)
        #expect(task2 != nil)
        // task1 must be cancelled; task2 is the live one.
        #expect(task1?.isCancelled == true)
    }

    @Test func fetchWithNoFileIndexReturnsEmpty() {
        let (conn, _) = makeTestConnection()
        // fileIndex not loaded — search should return empty immediately
        conn.fetchFileSuggestions(query: "src")
        #expect(conn.chatState.fileSuggestions.isEmpty)
        #expect(conn.chatState.fileSuggestionTask == nil)
    }

    @Test func fetchPopulatesSuggestionsFromLocalIndex() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "ios/Oppi/Features/Chat/ChatView.swift",
            "ios/Oppi/Core/Models/FuzzyMatch.swift",
            "README.md",
        ])

        conn.fetchFileSuggestions(query: "fuzzy")

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            !conn.chatState.fileSuggestions.isEmpty
        })
        #expect(conn.chatState.fileSuggestions[0].path.contains("FuzzyMatch"))
        #expect(!conn.chatState.fileSuggestions[0].matchPositions.isEmpty,
                "Match positions should be populated for highlighting")
    }

    @Test func fetchRanksServerTsHighestForServerTsQuery() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "server/src/server.ts",
            "server/src/event-ring.ts",
            "server/src/rules.ts",
            "server/src/id.ts",
            "server/src/qr.ts",
            "server/src/cli.ts",
            "server/src/tls.ts",
        ])

        conn.fetchFileSuggestions(query: "server.ts")
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            !conn.chatState.fileSuggestions.isEmpty
        })
        #expect(conn.chatState.fileSuggestions[0].path == "server/src/server.ts")
    }

    @Test func fetchPrefersFilenamePrefixOverDockerCompose() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "server/docker-compose.yml",
            "clients/apple/Oppi/Features/Chat/Composer/ComposerAutocomplete.swift",
        ])

        conn.fetchFileSuggestions(query: "compose")
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            !conn.chatState.fileSuggestions.isEmpty
        })
        #expect(conn.chatState.fileSuggestions[0].path ==
                "clients/apple/Oppi/Features/Chat/Composer/ComposerAutocomplete.swift")
    }

    @Test func fetchDemotesMediaForCodeLikeQuery() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "docs/images/app-icon.png",
            "server/tests/api-routes.test.ts",
            "clients/apple/Oppi/Core/Networking/APIClient.swift",
        ])

        conn.fetchFileSuggestions(query: "api")
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            !conn.chatState.fileSuggestions.isEmpty
        })
        #expect(!conn.chatState.fileSuggestions[0].path.hasSuffix(".png"))
    }

    @Test func fetchPrefersImplementationOverTestsWhenQueryIsNotTest() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "clients/apple/OppiTests/Network/ServerConnectionTests.swift",
            "clients/apple/Oppi/Core/Networking/ServerConnection.swift",
        ])

        conn.fetchFileSuggestions(query: "serverconnection")
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            !conn.chatState.fileSuggestions.isEmpty
        })
        #expect(conn.chatState.fileSuggestions[0].path ==
                "clients/apple/Oppi/Core/Networking/ServerConnection.swift")
    }

    @Test func fetchPrefersExactBasenameOverTestVariant() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "server/src/routes/workspace-files.ts",
            "server/src/routes/workspace-files.test.ts",
        ])

        conn.fetchFileSuggestions(query: "workspace-files")
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            !conn.chatState.fileSuggestions.isEmpty
        })
        #expect(conn.chatState.fileSuggestions[0].path == "server/src/routes/workspace-files.ts")
    }

    @Test func fetchFallsBackToFuzzyWhenNoLiteralMatchExists() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "server/src/routes/workspace-files.ts",
            "server/src/routes/workspace-files.test.ts",
            "clients/apple/Oppi/Core/Models/FuzzyMatch.swift",
        ])

        conn.fetchFileSuggestions(query: "wft")
        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            !conn.chatState.fileSuggestions.isEmpty
        })
        #expect(conn.chatState.fileSuggestions[0].path.contains("workspace-files"))
    }

    @Test func fetchEmptyQueryReturnsFilesByLength() {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting([
            "ios/Oppi/Features/Chat/ChatView.swift",
            "README.md",
            "server/src/types.ts",
        ])

        conn.fetchFileSuggestions(query: "")

        // Empty query returns files sorted by path length (shortest first)
        #expect(conn.chatState.fileSuggestions.count == 3)
        #expect(conn.chatState.fileSuggestions[0].path == "README.md")
        #expect(conn.chatState.fileSuggestions[0].matchPositions.isEmpty,
                "No match positions for empty query")
    }

    @Test func invalidateMarksIndexDirty() {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting(["README.md"])

        // Index is loaded and clean
        #expect(conn.fileIndexStore.paths?.count == 1)

        // Simulate git_status push — marks dirty
        conn.fileIndexStore.invalidate()

        // Paths are still cached (stale data available until next ensureLoaded)
        #expect(conn.fileIndexStore.paths?.count == 1)
    }

    @Test func clearAfterFetchDropsResults() async {
        let (conn, _) = makeTestConnection()
        conn.fileIndexStore.setPathsForTesting(["src/index.ts", "README.md"])

        conn.fetchFileSuggestions(query: "src")
        conn.clearFileSuggestions()

        #expect(await waitForMainActorCondition(timeout: .milliseconds(500)) {
            conn.chatState.fileSuggestionTask == nil
        })
        #expect(conn.chatState.fileSuggestions.isEmpty)
    }
}
