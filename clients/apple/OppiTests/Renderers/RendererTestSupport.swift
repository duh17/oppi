import Foundation
import Testing
@testable import Oppi

/// Shared test infrastructure for notebook renderer conformance and performance tests.
///
/// Provides:
/// - `medianNs()`: timing helper matching `MarkdownParsePerfBench` pattern
/// - `benchParse()`: parse benchmark with METRIC output and optional budget
/// - `benchParseAndRender()`: full pipeline benchmark
/// - `assertNoParseFailure()`: verify parser error recovery (no crashes)
///
/// All performance benchmarks emit METRIC lines:
///   `METRIC name=value`
/// Compatible with autoresearch bench framework and Grafana telemetry import.
enum RendererTestSupport {

    // MARK: - Timing

    /// Measure median nanoseconds across iterations (after warmup).
    ///
    /// Matches the `MarkdownParsePerfBench.medianNs` pattern exactly.
    static func medianNs(
        iterations: Int = 15,
        warmup: Int = 3,
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

    /// Convert nanoseconds to microseconds.
    static func nsToUs(_ ns: Double) -> Double { ns / 1000.0 }

    // MARK: - Parse Benchmarks

    /// Benchmark a parser and emit METRIC lines.
    ///
    /// ```swift
    /// RendererTestSupport.benchParse(
    ///     parser: OrgParser(),
    ///     input: orgDocument,
    ///     prefix: "org",
    ///     label: "100_headings",
    ///     budgetUs: 500
    /// )
    /// // Emits: METRIC org_parse_100_headings_us=123.4
    /// ```
    static func benchParse<P: DocumentParser>(
        parser: P,
        input: String,
        prefix: String,
        label: String,
        iterations: Int = 15,
        warmup: Int = 3,
        budgetUs: Double? = nil
    ) {
        let ns = medianNs(iterations: iterations, warmup: warmup) {
            consume(parser.parse(input))
        }
        let us = nsToUs(ns)
        let metricName = "\(prefix)_parse_\(label)_us"
        print("METRIC \(metricName)=\(String(format: "%.1f", us))")

        if let budget = budgetUs {
            #expect(us < budget, "\(metricName) exceeded budget: \(String(format: "%.1f", us))us > \(budget)us")
        }
    }

    /// Benchmark full parse-render pipeline and emit METRIC lines.
    ///
    /// Emits three metrics: parse, render, and total.
    static func benchParseAndRender<P: DocumentParser, R: DocumentRenderer>(
        parser: P,
        renderer: R,
        input: String,
        config: RenderConfiguration = .default(),
        prefix: String,
        label: String,
        iterations: Int = 15,
        warmup: Int = 3,
        parseBudgetUs: Double? = nil,
        renderBudgetUs: Double? = nil,
        totalBudgetUs: Double? = nil
    ) where P.Document == R.Document {
        // Parse-only
        let parseNs = medianNs(iterations: iterations, warmup: warmup) {
            consume(parser.parse(input))
        }
        let parseUs = nsToUs(parseNs)
        print("METRIC \(prefix)_parse_\(label)_us=\(String(format: "%.1f", parseUs))")

        if let budget = parseBudgetUs {
            #expect(parseUs < budget, "\(prefix)_parse_\(label) exceeded: \(String(format: "%.1f", parseUs))us > \(budget)us")
        }

        // Render-only (parse once, measure render)
        let document = parser.parse(input)
        let renderNs = medianNs(iterations: iterations, warmup: warmup) {
            consume(renderer.render(document, configuration: config))
        }
        let renderUs = nsToUs(renderNs)
        print("METRIC \(prefix)_render_\(label)_us=\(String(format: "%.1f", renderUs))")

        if let budget = renderBudgetUs {
            #expect(renderUs < budget, "\(prefix)_render_\(label) exceeded: \(String(format: "%.1f", renderUs))us > \(budget)us")
        }

        // Total
        let totalUs = parseUs + renderUs
        print("METRIC \(prefix)_total_\(label)_us=\(String(format: "%.1f", totalUs))")

        if let budget = totalBudgetUs {
            #expect(totalUs < budget, "\(prefix)_total_\(label) exceeded: \(String(format: "%.1f", totalUs))us > \(budget)us")
        }
    }

    // MARK: - Conformance Helpers

    /// Verify a parser doesn't crash on a batch of inputs (error recovery test).
    static func assertNoParseFailure<P: DocumentParser>(
        parser: P,
        inputs: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for input in inputs {
            consume(parser.parse(input))
        }
    }

    /// Verify parse produces the expected AST.
    static func assertParseEquals<P: DocumentParser>(
        parser: P,
        input: String,
        expected: P.Document,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let result = parser.parse(input)
        #expect(result == expected, sourceLocation: sourceLocation)
    }

    // MARK: - Anti-DCE

    @inline(never)
    static func consume<T>(_ value: T) {}
}
