import Testing
@testable import Oppi

@Suite("FileSuggestion ranking")
struct FileSuggestionRankingTests {
    @Test func emptyQueryReturnsFilesByLength() {
        let paths = [
            "ios/Oppi/Features/Chat/ChatView.swift",
            "README.md",
            "server/src/types.ts",
        ]

        let results = FileSuggestion.ranked(query: "", paths: paths, limit: 2)

        #expect(results.map(\.path) == ["README.md", "server/src/types.ts"])
        #expect(results[0].matchPositions.isEmpty)
    }

    @Test func ranksServerTsHighestForServerTsQuery() {
        let paths = [
            "server/src/server.ts",
            "server/src/event-ring.ts",
            "server/src/rules.ts",
            "server/src/id.ts",
            "server/src/qr.ts",
            "server/src/cli.ts",
            "server/src/tls.ts",
        ]

        let results = FileSuggestion.ranked(query: "server.ts", paths: paths)

        #expect(results.first?.path == "server/src/server.ts")
        #expect(results.first?.matchPositions.isEmpty == false)
    }

    @Test func prefersFilenamePrefixOverDockerCompose() {
        let paths = [
            "server/docker-compose.yml",
            "clients/apple/Oppi/Features/Chat/Composer/ComposerAutocomplete.swift",
        ]

        let results = FileSuggestion.ranked(query: "compose", paths: paths)

        #expect(results.first?.path ==
                "clients/apple/Oppi/Features/Chat/Composer/ComposerAutocomplete.swift")
    }

    @Test func demotesMediaForCodeLikeQuery() {
        let paths = [
            "docs/images/app-icon.png",
            "server/tests/api-routes.test.ts",
            "clients/apple/Oppi/Core/Networking/APIClient.swift",
        ]

        let results = FileSuggestion.ranked(query: "api", paths: paths)

        #expect(results.first?.path.hasSuffix(".png") == false)
    }

    @Test func prefersImplementationOverTestsWhenQueryIsNotTest() {
        let paths = [
            "clients/apple/OppiTests/Network/ServerConnectionTests.swift",
            "clients/apple/Oppi/Core/Networking/ServerConnection.swift",
        ]

        let results = FileSuggestion.ranked(query: "serverconnection", paths: paths)

        #expect(results.first?.path ==
                "clients/apple/Oppi/Core/Networking/ServerConnection.swift")
    }

    @Test func prefersExactBasenameOverTestVariant() {
        let paths = [
            "server/src/routes/workspace-files.ts",
            "server/src/routes/workspace-files.test.ts",
        ]

        let results = FileSuggestion.ranked(query: "workspace-files", paths: paths)

        #expect(results.first?.path == "server/src/routes/workspace-files.ts")
    }

    @Test func fallsBackToFuzzyWhenNoLiteralMatchExists() {
        let paths = [
            "server/src/routes/workspace-files.ts",
            "server/src/routes/workspace-files.test.ts",
            "clients/apple/Oppi/Core/Models/FuzzyMatch.swift",
        ]

        let results = FileSuggestion.ranked(query: "wft", paths: paths)

        #expect(results.first?.path.contains("workspace-files") == true)
        #expect(results.first?.matchPositions.isEmpty == false)
    }

    @Test func emptyPathsAndNonPositiveLimitReturnEmpty() {
        #expect(FileSuggestion.ranked(query: "src", paths: []).isEmpty)
        #expect(FileSuggestion.ranked(query: "src", paths: ["src/index.ts"], limit: 0).isEmpty)
    }
}
