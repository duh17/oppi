import Testing
import Foundation
@testable import Oppi

/// Benchmarks for the markdown streaming parse pipeline:
/// incremental parse, full parse, FlatSegment build, FNV-1a hash, and cache lookup.
///
/// Measures the hot path that runs every 33ms during LLM streaming:
/// `buildSegmentsIncremental → parseCommonMark → FlatSegment.build`
///
/// Output format: METRIC name=number (microseconds)
@Suite("MarkdownParsePerfBench")
@MainActor
struct MarkdownParsePerfBench {

    // MARK: - Configuration

    private static let iterations = 15
    private static let warmupIterations = 3

    // MARK: - Timing

    /// Measure median nanoseconds across `iterations` runs (after warmup).
    private static func medianNs(
        iterations: Int = Self.iterations,
        warmup: Int = Self.warmupIterations,
        setup: () -> Void = {},
        _ block: () -> Void
    ) -> Double {
        var timings: [UInt64] = []
        timings.reserveCapacity(iterations)

        for i in 0 ..< (warmup + iterations) {
            setup()
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            if i >= warmup {
                timings.append(elapsed)
            }
        }

        timings.sort()
        return Double(timings[timings.count / 2])
    }

    // MARK: - Content Generators

    /// Build cumulative content strings simulating streaming deltas.
    /// Returns an array where each element is the full content after that delta.
    private static func makeStreamingDeltas(
        deltaCount: Int,
        charsPerDelta: Int = 30
    ) -> [String] {
        var content = "# Response\n\n"
        var deltas: [String] = []
        deltas.reserveCapacity(deltaCount)

        let words = [
            "The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog.",
            "Swift", "performance", "optimization", "is", "critical", "for", "smooth",
            "streaming.", "AttributedString", "construction", "dominates", "the", "hot",
            "path.", "Each", "33ms", "tick", "triggers", "a", "re-parse", "of", "the",
            "growing", "tail.", "Profiling", "shows", "that", "FlatSegment.build", "and",
            "parseCommonMark", "are", "the", "dominant", "costs."
        ]

        var wordIdx = 0

        for i in 0 ..< deltaCount {
            var chunk = ""
            var charCount = 0

            // Every 25 deltas, start a new block
            if i > 0, i % 25 == 0 {
                let blockType = (i / 25) % 4
                switch blockType {
                case 0:
                    chunk += "\n\n## Section \(i / 25)\n\n"
                case 1:
                    chunk += "\n\n```swift\nlet value\(i) = compute()\nfunc process\(i)() {\n    return value\(i)\n}\n```\n\n"
                case 2:
                    chunk += "\n\n- Item one with **bold** formatting\n- Item two with `inline code`\n- Item three\n\n"
                default:
                    chunk += "\n\n> This is a block quote with some content that spans multiple words.\n\n"
                }
                charCount += chunk.count
            }

            // Fill with words
            while charCount < charsPerDelta {
                let word = words[wordIdx % words.count]
                chunk += word + " "
                charCount += word.count + 1
                wordIdx += 1
            }

            content += chunk
            deltas.append(content)
        }

        return deltas
    }

    /// Generate a complete markdown document of approximately the given char count.
    private static func makeCompleteDocument(approximateChars: Int) -> String {
        var parts: [String] = []
        var totalChars = 0
        var sectionIdx = 0

        while totalChars < approximateChars {
            sectionIdx += 1
            parts.append("## Section \(sectionIdx)")
            parts.append("")
            totalChars += 20

            let para = "This is paragraph \(sectionIdx) with representative text for the CommonMark parser. It includes **bold**, *italic*, `inline code`, and [a link](https://example.com) to exercise all inline rendering paths."
            parts.append(para)
            parts.append("")
            totalChars += para.count + 2

            if sectionIdx % 3 == 0 {
                let code = "```swift\nfunc example\(sectionIdx)() {\n    let items = (0..<100).map { Item(id: $0) }\n    let filtered = items.filter { $0.isValid }\n    return filtered.sorted(by: { $0.id < $1.id })\n}\n```"
                parts.append(code)
                parts.append("")
                totalChars += code.count + 2
            }

            if sectionIdx % 4 == 0 {
                parts.append("- Item one with some text and **bold** emphasis")
                parts.append("- Item two with `inline code` formatting")
                parts.append("- Item three with a [link](https://example.com)")
                parts.append("")
                totalChars += 140
            }

            if sectionIdx % 5 == 0 {
                parts.append("> A block quote that contains *emphasized* text and represents typical assistant explanations.")
                parts.append("")
                totalChars += 90
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Config Helpers

    private static func streamingConfig(content: String) -> AssistantMarkdownContentView.Configuration {
        AssistantMarkdownContentView.Configuration(
            content: content,
            isStreaming: true,
            themeID: .dark,
            textSelectionEnabled: false,
            plainTextFallbackThreshold: nil
        )
    }

    // MARK: - Dead-code elimination prevention

    @inline(never)
    private static func consume<T>(_ value: T) {}

    // MARK: - Aggregate Benchmark

    @Test("Aggregate: total markdown parse cost")
    func aggregateMetric() {

        // --- 1. Short stream per-tick (50 deltas, ~1500 chars) ---
        let shortDeltas = Self.makeStreamingDeltas(deltaCount: 50, charsPerDelta: 30)
        let shortTotalNs = Self.medianNs {
            let source = AssistantMarkdownSegmentSource()
            // Warmup streaming state
            for i in 0 ..< 20 {
                Self.consume(source.buildSegments(Self.streamingConfig(content: shortDeltas[i])))
            }
            // Measure steady-state ticks
            for i in 20 ..< 50 {
                Self.consume(source.buildSegments(Self.streamingConfig(content: shortDeltas[i])))
            }
        }
        let shortTickUs = (shortTotalNs / 30.0) / 1000.0

        // --- 2. Long stream per-tick (200 deltas, ~8000 chars) ---
        let longDeltas = Self.makeStreamingDeltas(deltaCount: 200, charsPerDelta: 40)
        let longTotalNs = Self.medianNs(iterations: 10) {
            let source = AssistantMarkdownSegmentSource()
            // Warmup streaming state
            for i in 0 ..< 100 {
                Self.consume(source.buildSegments(Self.streamingConfig(content: longDeltas[i])))
            }
            // Measure steady-state ticks (large prefix, tail-only path)
            for i in 100 ..< 200 {
                Self.consume(source.buildSegments(Self.streamingConfig(content: longDeltas[i])))
            }
        }
        let longTickUs = (longTotalNs / 100.0) / 1000.0

        // --- 3. Full parse + build: ~2K complete message ---
        let doc2k = Self.makeCompleteDocument(approximateChars: 2000)
        let parse2kNs = Self.medianNs {
            let blocks = parseCommonMark(doc2k)
            Self.consume(FlatSegment.build(from: blocks, themeID: .dark))
        }
        let parse2kUs = parse2kNs / 1000.0

        // --- 4. Full parse + build: ~8K complete message ---
        let doc8k = Self.makeCompleteDocument(approximateChars: 8000)
        let parse8kNs = Self.medianNs {
            let blocks = parseCommonMark(doc8k)
            Self.consume(FlatSegment.build(from: blocks, themeID: .dark))
        }
        let parse8kUs = parse8kNs / 1000.0

        // --- 4b. Diagnostic: parse-only and build-only split for 8K ---
        let parseOnly8kNs = Self.medianNs {
            Self.consume(parseCommonMark(doc8k))
        }
        let parseOnly8kUs = parseOnly8kNs / 1000.0
        let blocks8k = parseCommonMark(doc8k)
        let buildOnly8kNs = Self.medianNs {
            Self.consume(FlatSegment.build(from: blocks8k, themeID: .dark))
        }
        let buildOnly8kUs = buildOnly8kNs / 1000.0

        // --- 5. FNV-1a hash: 8K bytes ---
        let hashContent = doc8k.utf8
        let hashCount = hashContent.count
        var hashResult: UInt64 = 0
        let fnvNs = Self.medianNs(iterations: 50) {
            var hash: UInt64 = 14_695_981_039_346_656_037
            let end = hashContent.index(hashContent.startIndex, offsetBy: hashCount)
            for byte in hashContent[..<end] {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hashResult = hash
        }
        Self.consume(hashResult)
        let fnvUs = fnvNs / 1000.0

        // --- 6. FlatSegment.build: 20 blocks ---
        let doc4k = Self.makeCompleteDocument(approximateChars: 4000)
        let buildBlocks = Array(parseCommonMark(doc4k).prefix(20))
        let buildNs = Self.medianNs(iterations: 30) {
            Self.consume(FlatSegment.build(from: buildBlocks, themeID: .dark))
        }
        let buildUs = buildNs / 1000.0

        let total = shortTickUs + longTickUs + parse2kUs + parse8kUs + fnvUs + buildUs

        print("METRIC total_parse_us=\(String(format: "%.1f", total))")
        print("METRIC short_stream_tick_us=\(String(format: "%.1f", shortTickUs))")
        print("METRIC long_stream_tick_us=\(String(format: "%.1f", longTickUs))")
        print("METRIC full_parse_2k_us=\(String(format: "%.1f", parse2kUs))")
        print("METRIC full_parse_8k_us=\(String(format: "%.1f", parse8kUs))")
        print("METRIC fnv1a_8k_us=\(String(format: "%.1f", fnvUs))")
        print("METRIC build_20blocks_us=\(String(format: "%.1f", buildUs))")
        print("METRIC parse_only_8k_us=\(String(format: "%.1f", parseOnly8kUs))")
        print("METRIC build_only_8k_us=\(String(format: "%.1f", buildOnly8kUs))")

        #expect(total > 0)
    }
}
