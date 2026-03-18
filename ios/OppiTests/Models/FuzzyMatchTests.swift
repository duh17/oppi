import Testing
@testable import Oppi

@Suite("FuzzyMatch")
struct FuzzyMatchTests {

    // MARK: - Basic Matching

    @Test func exactSubstringMatches() {
        let result = FuzzyMatch.match(query: "index", candidate: "src/index.ts")
        #expect(result != nil)
        if let result { #expect(result.score > 0) }
    }

    @Test func fuzzyNonContiguousMatch() {
        // "fbv" should match FileBrowserView.swift
        let result = FuzzyMatch.match(query: "fbv", candidate: "FileBrowserView.swift")
        #expect(result != nil)
    }

    @Test func caseInsensitiveMatch() {
        let lower = FuzzyMatch.match(query: "readme", candidate: "README.md")
        let upper = FuzzyMatch.match(query: "README", candidate: "README.md")
        #expect(lower != nil)
        #expect(upper != nil)
    }

    @Test func noMatchWhenCharsAbsent() {
        let result = FuzzyMatch.match(query: "xyz", candidate: "src/index.ts")
        #expect(result == nil)
    }

    @Test func noMatchWhenQueryLongerThanCandidate() {
        let result = FuzzyMatch.match(query: "abcdefg", candidate: "abc")
        #expect(result == nil)
    }

    @Test func emptyQueryReturnsNil() {
        let result = FuzzyMatch.match(query: "", candidate: "file.txt")
        #expect(result == nil)
    }

    @Test func emptyCandidateReturnsNil() {
        let result = FuzzyMatch.match(query: "a", candidate: "")
        #expect(result == nil)
    }

    // MARK: - Scoring Quality

    @Test func exactPrefixScoresHigherThanDeepMatch() {
        let prefix = FuzzyMatch.match(query: "app", candidate: "App.tsx")
        let deep = FuzzyMatch.match(query: "app", candidate: "src/components/wrapper/app-loader.ts")
        #expect(prefix != nil)
        #expect(deep != nil)
        if let prefix, let deep {
            #expect(prefix.score > deep.score)
        }
    }

    @Test func consecutiveMatchScoresHigherThanScattered() {
        let consecutive = FuzzyMatch.match(query: "index", candidate: "src/index.ts")
        let scattered = FuzzyMatch.match(query: "index", candidate: "src/impl/node/dev/exec.ts")
        #expect(consecutive != nil)
        // Scattered may or may not match depending on char availability
        if let consecutive, let scattered {
            #expect(consecutive.score > scattered.score)
        }
    }

    @Test func filenameMatchScoresHigherThanDirectoryMatch() {
        let filename = FuzzyMatch.match(query: "app", candidate: "src/App.tsx")
        let directory = FuzzyMatch.match(query: "app", candidate: "app/src/index.ts")
        #expect(filename != nil)
        #expect(directory != nil)
        if let filename, let directory {
            #expect(filename.score > directory.score)
        }
    }

    @Test func camelCaseBoundaryMatch() {
        // "FBV" should match at camelCase boundaries of FileBrowserView
        let result = FuzzyMatch.match(query: "FBV", candidate: "FileBrowserView.swift")
        #expect(result != nil)
        if let result {
            // Should match at positions 0, 4, 11 (F, B, V)
            #expect(result.positions.count == 3)
        }
    }

    @Test func pathSeparatorBoundaryMatch() {
        // "si" matching at path boundaries: src/index.ts
        let result = FuzzyMatch.match(query: "si", candidate: "src/index.ts")
        #expect(result != nil)
    }

    // MARK: - Match Positions

    @Test func positionsAreStrictlyIncreasing() {
        let result = FuzzyMatch.match(query: "fbv", candidate: "FileBrowserView.swift")
        #expect(result != nil)
        if let result {
            let positions = result.positions
            for i in 1..<positions.count {
                #expect(positions[i] > positions[i - 1])
            }
        }
    }

    @Test func positionsCountEqualsQueryLength() {
        let result = FuzzyMatch.match(query: "test", candidate: "src/testing/utils.ts")
        #expect(result != nil)
        if let result {
            #expect(result.positions.count == 4)
        }
    }

    // MARK: - Search (Batch)

    @Test func searchReturnsMatchesSortedByScore() {
        let candidates = [
            "src/components/deep/wrapper/AppButton.tsx",
            "App.tsx",
            "src/App.tsx",
            "docs/api-reference.md",
        ]
        let results = FuzzyMatch.search(query: "app", candidates: candidates)
        #expect(!results.isEmpty)
        // Scores should be descending
        for i in 1..<results.count {
            #expect(results[i].score <= results[i - 1].score)
        }
    }

    @Test func searchRespectsLimit() {
        let candidates = (0..<200).map { "file\($0).txt" }
        let results = FuzzyMatch.search(query: "file", candidates: candidates, limit: 10)
        #expect(results.count == 10)
    }

    @Test func searchFiltersNonMatches() {
        let candidates = ["match.txt", "nomatch.txt", "other.rs"]
        let results = FuzzyMatch.search(query: "match", candidates: candidates)
        #expect(results.count == 2) // "match.txt" and "nomatch.txt" both contain "match"
    }

    @Test func searchEmptyQueryReturnsEmpty() {
        let results = FuzzyMatch.search(query: "", candidates: ["file.txt"])
        #expect(results.isEmpty)
    }

    // MARK: - Realistic File Paths

    @Test func realWorldFileDiscovery() {
        let candidates = [
            "ios/Oppi/Features/FileBrowser/FileBrowserView.swift",
            "ios/Oppi/Features/FileBrowser/FileBrowserContentView.swift",
            "ios/Oppi/Features/FileBrowser/HTMLPreviewView.swift",
            "ios/Oppi/Core/Networking/APIClient.swift",
            "ios/Oppi/Core/Models/WorkspaceFiles.swift",
            "server/src/routes/workspace-files.ts",
            "server/src/routes/workspace-files.test.ts",
            "server/src/types.ts",
            "README.md",
            "package.json",
        ]

        // "wft" should match workspace-files.test.ts well
        let wft = FuzzyMatch.search(query: "wft", candidates: candidates)
        #expect(!wft.isEmpty)
        #expect(wft[0].path.contains("workspace-files"))

        // "fbv" should prefer FileBrowserView
        let fbv = FuzzyMatch.search(query: "fbv", candidates: candidates)
        #expect(!fbv.isEmpty)
        #expect(fbv[0].path.contains("FileBrowserView"))

        // "api" should find APIClient
        let api = FuzzyMatch.search(query: "api", candidates: candidates)
        #expect(!api.isEmpty)
        #expect(api[0].path.contains("APIClient"))
    }
}
