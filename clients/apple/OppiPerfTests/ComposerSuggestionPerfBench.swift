import Foundation
import Testing
@testable import Oppi

/// Keystroke-to-ranked-list microbench for `@file` and `/command` suggestions.
///
/// Runs in the OppiPerfTests Debug configuration (`-Onone`). Numbers are a
/// simulator regression signal, not device Release.
///
/// Slice A: precomputed `FileSuggestionIndex`, lazy empty-query order,
/// `FileSuggestionRanker`, off-main ranking. Slash scenarios time
/// `SlashCommandSuggestionIndex.suggestions` (uncached). `slash_body_reeval`
/// is the last-query cache hit path.
///
/// Index size matches the server cap `MAX_INDEX_PATHS` (50,000) in
/// `server/src/routes/workspace-files.ts`.
///
/// Output: `COMPOSER_SUGGESTION_BENCH` lines plus `METRIC` microseconds
/// for autoresearch. Report median and p95 in milliseconds.
@Suite("ComposerSuggestionPerfBench", .tags(.perf), .serialized)
struct ComposerSuggestionPerfBench {
    private static let pathCount = 50_000
    private static let limit = ComposerAutocomplete.maxSuggestions
    private static let warmupIterations = 2
    private static let iterations = 7

    /// Typed `@` sequence after the leading `@`. Empty string is `@` alone.
    private static let atQueries = ["", "c", "ch", "cha", "chat", "chatv"]

    /// Typed `/` sequence after the leading `/`. Empty string is `/` alone.
    private static let slashQueries = ["", "c", "co", "com", "comp", "compa"]

    private static let paths: [String] = generatePaths(count: pathCount)
    private static let fileIndex = FileSuggestionIndex(paths: paths)
    private static let commands: [SlashCommand] = generateCommands()
    private static let slashIndex = SlashCommandSuggestionIndex(commands: commands)

    // MARK: - Scenarios

    @Test("METRIC composer_suggest_index_build")
    func indexBuild() {
        let paths = Self.paths
        let sample = Self.measure {
            Self.blackHole(FileSuggestionIndex(paths: paths))
        }
        Self.report(scenario: "index_build", sample: sample)
        #expect(sample.medianMs > 0)
    }

    @Test("METRIC composer_suggest_at_empty")
    func atEmptyQuery() {
        let paths = Self.paths
        let sample = Self.measure {
            Self.blackHole(Self.rankFiles(query: "", paths: paths))
        }
        Self.report(scenario: "at_empty", sample: sample)
        #expect(sample.medianMs > 0)
    }

    @Test("METRIC composer_suggest_at_typed_sequence")
    func atTypedSequence() {
        let paths = Self.paths
        for query in Self.atQueries where !query.isEmpty {
            let sample = Self.measure {
                Self.blackHole(Self.rankFiles(query: query, paths: paths))
            }
            Self.report(scenario: "at_query_\(query)", sample: sample)
            #expect(sample.medianMs >= 0)
        }

        let sequence = Self.measure {
            let ranker = FileSuggestionRanker(index: Self.fileIndex)
            for query in Self.atQueries {
                Self.blackHole(ranker.ranked(query: query, limit: Self.limit))
            }
        }
        Self.report(scenario: "at_typed_sequence", sample: sequence)
        #expect(sequence.medianMs > 0)
    }

    @Test("METRIC composer_suggest_slash_empty")
    func slashEmptyQuery() {
        let sample = Self.measure {
            Self.blackHole(Self.rankSlashUncached(query: ""))
        }
        Self.report(scenario: "slash_empty", sample: sample)
        #expect(sample.medianMs >= 0)
    }

    @Test("METRIC composer_suggest_slash_typed_sequence")
    func slashTypedSequence() {
        for query in Self.slashQueries where !query.isEmpty {
            let sample = Self.measure {
                Self.blackHole(Self.rankSlashUncached(query: query))
            }
            Self.report(scenario: "slash_query_\(query)", sample: sample)
            #expect(sample.medianMs >= 0)
        }

        let sequence = Self.measure {
            for query in Self.slashQueries {
                Self.blackHole(Self.rankSlashUncached(query: query))
            }
        }
        Self.report(scenario: "slash_typed_sequence", sample: sequence)
        #expect(sequence.medianMs >= 0)
    }

    @Test("METRIC composer_suggest_slash_body_reeval")
    func slashBodyReeval() {
        let commands = Self.commands
        // Same query as a SwiftUI body re-render: ranking must stay cheap
        // when the command list and query have not changed.
        let sample = Self.measure {
            for _ in 0..<20 {
                Self.blackHole(Self.rankSlashCached(query: "co", commands: commands))
            }
        }
        Self.report(scenario: "slash_body_reeval_x20", sample: sample)
        #expect(sample.medianMs >= 0)
    }

    // MARK: - Ranking under test

    /// First-keystroke `@file` ranking (fresh ranker, no prior pool).
    /// `at_typed_sequence` uses one `FileSuggestionRanker` across queries.
    private static func rankFiles(query: String, paths _: [String]) -> [FileSuggestion] {
        FileSuggestionRanker(index: fileIndex).ranked(query: query, limit: limit)
    }

    /// Uncached `/command` ranking against a prebuilt index.
    private static func rankSlashUncached(query: String) -> [SlashCommand] {
        slashIndex.suggestions(query: query)
    }

    /// Production `/command` ranking. Cached per command list + last query.
    private static func rankSlashCached(query: String, commands: [SlashCommand]) -> [SlashCommand] {
        ComposerAutocomplete.slashSuggestions(query: query, commands: commands)
    }

    // MARK: - Timing

    private struct Sample {
        var medianMs: Double
        var p95Ms: Double
    }

    private static func measure(_ block: () -> Void) -> Sample {
        var timings: [Double] = []
        timings.reserveCapacity(warmupIterations + iterations)
        for i in 0..<(warmupIterations + iterations) {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            if i >= warmupIterations {
                timings.append(Double(end &- start) / 1_000_000)
            }
        }
        timings.sort()
        return Sample(medianMs: percentile(timings, 0.5), p95Ms: percentile(timings, 0.95))
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let rank = Int((Double(values.count - 1) * p).rounded())
        return values[min(max(rank, 0), values.count - 1)]
    }

    private static func report(scenario: String, sample: Sample) {
        print(
            "COMPOSER_SUGGESTION_BENCH scenario=\(scenario) source=\(rankingSource) paths=\(paths.count) commands=\(commands.count) warmup=\(warmupIterations) iterations=\(iterations) median_ms=\(ms(sample.medianMs)) p95_ms=\(ms(sample.p95Ms))"
        )
        print(String(format: "METRIC composer_suggest_\(scenario)_median_ms=%.3f", sample.medianMs))
        print(String(format: "METRIC composer_suggest_\(scenario)_p95_ms=%.3f", sample.p95Ms))
    }

    private static let rankingSource = "FileSuggestionRanker + slash cache"

    private static func ms(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    @inline(never)
    private static func blackHole<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }

    // MARK: - Synthetic fixtures

    /// Realistic 50k-path workspace: nested source, tests, media, directories.
    private static func generatePaths(count: Int) -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(count)

        let anchors = [
            "README.md",
            "package.json",
            "clients/apple/Oppi/Features/Chat/ChatView.swift",
            "clients/apple/Oppi/Features/Chat/Composer/ChatInputBar.swift",
            "clients/apple/Oppi/Features/Chat/Composer/ChatComposer.swift",
            "clients/apple/OppiCore/Models/ChatMessage.swift",
            "clients/apple/OppiTests/Chat/ChatViewTests.swift",
            "server/src/chat.ts",
            "server/src/routes/chat.ts",
            "server/src/routes/workspace-files.ts",
            "docs/images/chat-icon.png",
            "clients/apple/Oppi/Features/Chat/",
        ]
        paths.append(contentsOf: anchors)

        let roots = [
            "clients/apple/Oppi",
            "clients/apple/OppiCore",
            "clients/apple/OppiTests",
            "server/src",
            "server/tests",
            "docs",
            "pi-extensions",
            "protocol",
        ]
        let dirs = ["Features", "Models", "Stores", "routes", "utils", "components", "Chat", "Composer"]
        let names = [
            "View", "Store", "Client", "Parser", "Index", "Session",
            "Workspace", "Terminal", "Connection", "Ranking",
        ]
        let exts = ["swift", "ts", "tsx", "js", "json", "md", "png", "yml", "h", "m"]

        var i = 0
        while paths.count < count {
            let root = roots[i % roots.count]
            let dir = dirs[i % dirs.count]
            let name = names[i % names.count]
            let ext = exts[i % exts.count]
            let bucket = i / 80
            if i % 19 == 0 {
                paths.append("\(root)/\(dir)/tests/\(name)\(i).\(ext)")
            } else if i % 29 == 0 {
                paths.append("\(root)/\(dir)/\(name)\(bucket)/")
            } else if i % 41 == 0 {
                paths.append("docs/images/\(name.lowercased())-\(i).png")
            } else {
                paths.append("\(root)/\(dir)/\(name)\(bucket)/\(name)\(i).\(ext)")
            }
            i += 1
        }
        return paths
    }

    /// Realistic `get_commands` catalog: builtins, extensions, prompts, skills.
    private static func generateCommands() -> [SlashCommand] {
        let builtins: [(String, String)] = [
            ("compact", "Compact context"),
            ("copy", "Copy message"),
            ("share", "Share session"),
            ("model", "Switch model"),
            ("thinking", "Set thinking level"),
            ("fork", "Fork session"),
            ("resume", "Resume session"),
            ("new", "New session"),
            ("help", "Show help"),
            ("clear", "Clear context"),
        ]
        let extensions: [(String, String)] = [
            ("check_agents", "Check agent status"),
            ("browser", "Open browser"),
            ("commit", "Commit changes"),
            ("pr", "Open pull request"),
            ("deploy", "Deploy preview"),
            ("search", "Search the web"),
            ("fetch", "Fetch a URL"),
            ("plan", "Start a plan"),
            ("review", "Review the diff"),
            ("test", "Run tests"),
        ]
        let prompts: [(String, String)] = [
            ("ask", "Ask a question"),
            ("explain", "Explain the selection"),
            ("refactor", "Refactor this code"),
            ("fix", "Fix the failing test"),
            ("docs", "Write documentation"),
            ("changelog", "Draft a changelog"),
            ("clarity", "Rewrite for clarity"),
            ("clone", "Clone a pattern"),
            ("create", "Create a file"),
            ("cycle", "Cycle the approach"),
        ]
        let skills: [(String, String)] = [
            ("qa", "Run QA"),
            ("testing", "Choose a test"),
            ("writing", "Load writing skill"),
            ("oppi-dev", "Oppi local build"),
            ("release", "Cut a release"),
            ("debug", "Debug a failure"),
            ("perf", "Profile a hot path"),
            ("design", "Design a surface"),
            ("security", "Security review"),
            ("migrate", "Migrate a schema"),
        ]

        var commands: [SlashCommand] = []
        commands.append(contentsOf: builtins.map { SlashCommand(name: $0.0, description: $0.1, source: .builtin) })
        commands.append(contentsOf: extensions.map { SlashCommand(name: $0.0, description: $0.1, source: .extension) })
        commands.append(contentsOf: prompts.map { SlashCommand(name: $0.0, description: $0.1, source: .prompt) })
        commands.append(contentsOf: skills.map { SlashCommand(name: $0.0, description: $0.1, source: .skill) })
        // Duplicate names must be ignored by ranking (first source wins).
        commands.append(SlashCommand(name: "copy", description: "Copy duplicate", source: .extension))
        commands.append(SlashCommand(name: "compact", description: "Compact duplicate", source: .prompt))
        return commands
    }
}
