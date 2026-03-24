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

    // MARK: - Position Correctness

    /// Verify that each position index points to a character matching the query (case-insensitive).
    @Test func matchPositionsPointToCorrectCharacters() {
        let cases: [(query: String, candidate: String)] = [
            ("fbv", "FileBrowserView.swift"),
            ("api", "ios/Oppi/Core/Networking/APIClient.swift"),
            ("index", "src/index.ts"),
            ("readme", "README.md"),
            ("ts", "server/src/types.ts"),
        ]
        for (query, candidate) in cases {
            let result = FuzzyMatch.match(query: query, candidate: candidate)
            #expect(result != nil, "Expected match for '\(query)' in '\(candidate)'")
            guard let result else { continue }
            #expect(result.positions.count == query.count,
                    "Position count \(result.positions.count) != query length \(query.count)")
            let candidateBytes = Array(candidate.utf8)
            let queryLower = Array(query.lowercased().utf8)
            for (i, pos) in result.positions.enumerated() {
                #expect(pos >= 0 && pos < candidateBytes.count,
                        "Position \(pos) out of bounds for '\(candidate)' (len \(candidateBytes.count))")
                let actual = candidateBytes[pos] | 0x20 // ASCII lowercase
                let expected = queryLower[i]
                #expect(actual == expected,
                        "Position \(pos) in '\(candidate)' is '\(UnicodeScalar(candidateBytes[pos]))' but expected '\(UnicodeScalar(expected))' for query '\(query)'[\(i)]")
            }
        }
    }

    /// Verify search() returns the same positions as match() for each result.
    @Test func searchPositionsMatchDirectMatch() {
        let candidates = [
            "ios/Oppi/Features/FileBrowser/FileBrowserView.swift",
            "ios/Oppi/Features/FileBrowser/FileBrowserContentView.swift",
            "ios/Oppi/Core/Networking/APIClient.swift",
            "ios/Oppi/Core/Models/WorkspaceFiles.swift",
            "server/src/routes/workspace-files.ts",
            "server/src/routes/workspace-files.test.ts",
            "server/src/types.ts",
            "README.md",
        ]
        let queries = ["fbv", "api", "wft", "types"]
        for query in queries {
            let searchResults = FuzzyMatch.search(query: query, candidates: candidates)
            for result in searchResults {
                let direct = FuzzyMatch.match(query: query, candidate: result.path)
                #expect(direct != nil, "search() returned '\(result.path)' for '\(query)' but match() says nil")
                guard let direct else { continue }
                #expect(result.score == direct.score,
                        "Score mismatch for '\(query)' in '\(result.path)': search=\(result.score) vs match=\(direct.score)")
                #expect(result.positions == direct.positions,
                        "Position mismatch for '\(query)' in '\(result.path)': search=\(result.positions) vs match=\(direct.positions)")
            }
        }
    }

    /// Verify search() never returns empty positions for matched candidates.
    @Test func searchPositionsNeverEmpty() {
        let candidates = [
            "ios/Oppi/Features/FileBrowser/FileBrowserView.swift",
            "ios/Oppi/Core/Networking/APIClient.swift",
            "server/src/types.ts",
            "README.md",
            "package.json",
        ]
        let queries = ["fbv", "api", "ts", "read", "json"]
        for query in queries {
            let results = FuzzyMatch.search(query: query, candidates: candidates)
            for result in results {
                #expect(!result.positions.isEmpty,
                        "Empty positions for '\(query)' matching '\(result.path)'")
                #expect(result.positions.count == query.count,
                        "Position count \(result.positions.count) != query length \(query.count) for '\(query)' in '\(result.path)'")
            }
        }
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

    // MARK: - Realistic Repo Index

    /// Tests search against a realistic file index (mirrors oppi repo structure).
    /// Validates the full pipeline: search returns results, positions are valid,
    /// and highlighted characters match the query.
    @Test func realisticRepoSearch() {
        let index = [
            "ios/Oppi/Features/FileBrowser/FileBrowserView.swift",
            "ios/Oppi/Features/FileBrowser/FileBrowserContentView.swift",
            "ios/Oppi/Features/FileBrowser/HTMLPreviewView.swift",
            "ios/Oppi/Features/Chat/ChatView.swift",
            "ios/Oppi/Features/Chat/Timeline/Tool/ToolTimelineRowContent.swift",
            "ios/Oppi/Features/Settings/SettingsView.swift",
            "ios/Oppi/Core/Networking/APIClient.swift",
            "ios/Oppi/Core/Networking/ServerConnection.swift",
            "ios/Oppi/Core/Models/WorkspaceFiles.swift",
            "ios/Oppi/Core/Models/FuzzyMatch.swift",
            "ios/Oppi/Core/Runtime/TimelineReducer.swift",
            "ios/OppiTests/Models/FuzzyMatchTests.swift",
            "ios/OppiTests/Models/WorkspaceFilesTests.swift",
            "server/src/routes/workspace-files.ts",
            "server/src/routes/workspace-files.test.ts",
            "server/src/server.ts",
            "server/src/types.ts",
            "server/src/policy.ts",
            "README.md",
            "ARCHITECTURE.md",
            "package.json",
            ".gitignore",
        ]

        let queries: [(query: String, mustContain: String)] = [
            ("fbv", "FileBrowserView"),
            ("chat", "ChatView"),
            ("settings", "SettingsView"),
            ("api", "APIClient"),
            ("fuzzy", "FuzzyMatch"),
            ("timeline", "TimelineReducer"),
            ("types", "types.ts"),
            ("readme", "README"),
        ]

        for (query, mustContain) in queries {
            let results = FuzzyMatch.search(query: query, candidates: index, limit: 10)
            #expect(!results.isEmpty, "No results for query '\(query)'")
            guard !results.isEmpty else { continue }

            // Top result should contain the expected string
            let topContains = results[0].path.contains(mustContain)
            #expect(topContains,
                    "Top result for '\(query)' is '\(results[0].path)', expected to contain '\(mustContain)'")

            // All results should have valid positions
            for result in results {
                #expect(result.positions.count == query.count,
                        "'\(query)' in '\(result.path)': positions count \(result.positions.count) != \(query.count)")
                let bytes = Array(result.path.utf8)
                let qLower = Array(query.lowercased().utf8)
                for (i, pos) in result.positions.enumerated() {
                    #expect(pos >= 0 && pos < bytes.count,
                            "Position \(pos) out of range for '\(result.path)' (length \(bytes.count))")
                    guard pos < bytes.count else { continue }
                    let actual = bytes[pos] | 0x20
                    #expect(actual == qLower[i],
                            "Position \(pos) in '\(result.path)' has byte \(bytes[pos]) ('\(UnicodeScalar(bytes[pos]))'), expected \(qLower[i]) ('\(UnicodeScalar(qLower[i]))') for query '\(query)'[\(i)]")
                }
            }
        }
    }

    /// Test that HighlightedPathText renders correctly by validating position-to-scalar mapping.
    /// FuzzyMatch returns UTF-8 byte positions; the view uses unicode scalar positions.
    @Test func positionsWorkAsUnicodeScalarIndices() {
        // For ASCII paths, byte index == scalar index
        let candidate = "ios/Oppi/Core/Models/FuzzyMatch.swift"
        let result = FuzzyMatch.match(query: "fuzzy", candidate: candidate)
        #expect(result != nil)
        guard let result else { return }

        let scalars = Array(candidate.unicodeScalars)
        for pos in result.positions {
            #expect(pos < scalars.count,
                    "Position \(pos) exceeds scalar count \(scalars.count) for '\(candidate)'")
        }

        // Verify the highlighted scalars match the query chars
        let highlighted = result.positions.map { String(scalars[$0]).lowercased() }
        #expect(highlighted == ["f", "u", "z", "z", "y"])
    }

    /// Positions must be valid unicode scalar indices, even for non-ASCII paths.
    @Test func nonASCIIPathPositionsAreScalarIndices() {
        // é is 2 bytes in UTF-8 but 1 unicode scalar — positions after it must be scalar indices
        let candidate = "docs/café/readme.md"
        let result = FuzzyMatch.match(query: "readme", candidate: candidate)
        #expect(result != nil)
        guard let result else { return }

        // Positions should be valid unicode scalar indices
        let scalars = Array(candidate.unicodeScalars)
        #expect(result.positions.count == 6)
        let highlighted = result.positions.map { idx -> String in
            guard idx < scalars.count else { return "OUT_OF_BOUNDS" }
            return String(scalars[idx]).lowercased()
        }
        #expect(highlighted == ["r", "e", "a", "d", "m", "e"],
                "Expected scalar positions for 'readme' in '\(candidate)', got \(highlighted)")
    }

    /// search() also returns scalar positions for non-ASCII paths.
    @Test func searchNonASCIIPositionsAreScalarIndices() {
        let candidates = ["docs/café/readme.md", "src/index.ts"]
        let results = FuzzyMatch.search(query: "readme", candidates: candidates)
        #expect(!results.isEmpty)
        let hit = results.first { $0.path.contains("café") }
        #expect(hit != nil)
        guard let hit else { return }

        let scalars = Array(hit.path.unicodeScalars)
        let highlighted = hit.positions.map { idx -> String in
            guard idx < scalars.count else { return "OUT_OF_BOUNDS" }
            return String(scalars[idx]).lowercased()
        }
        #expect(highlighted == ["r", "e", "a", "d", "m", "e"])
    }

    /// ASCII paths should still work (fast path — no conversion needed).
    @Test func asciiPathPositionsUnchanged() {
        let candidate = "src/components/Button.tsx"
        let result = FuzzyMatch.match(query: "button", candidate: candidate)
        #expect(result != nil)
        guard let result else { return }

        let scalars = Array(candidate.unicodeScalars)
        let highlighted = result.positions.map { String(scalars[$0]).lowercased() }
        #expect(highlighted == ["b", "u", "t", "t", "o", "n"])
    }
}
