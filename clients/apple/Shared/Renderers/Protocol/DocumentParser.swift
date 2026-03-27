/// Protocol for spec-conformant document parsers.
///
/// Every document renderer starts with a parser that converts raw text into
/// a typed AST. Parsers are `nonisolated` and `Sendable` so they can run
/// off the main thread via `Task.detached` — matching the existing
/// `parseCommonMark` pattern.
///
/// Conformance requirements:
/// 1. Parse must be deterministic — same input always produces same output.
/// 2. Parse must not crash on malformed input — return partial results or empty.
/// 3. Document type must be Equatable for conformance test assertions.
///
/// Each parser ships with:
/// - Conformance tests derived from the format spec (one test per production rule)
/// - Performance benchmarks emitting METRIC lines (matching MarkdownParsePerfBench)
/// - Spec coverage tracking comments in the test file
protocol DocumentParser: Sendable {
    /// The AST type produced by parsing.
    associatedtype Document: Equatable & Sendable

    /// Parse raw source text into a typed document.
    ///
    /// Must be safe to call from any thread. Must not crash on malformed input.
    /// Returns an empty or partial document on parse failure.
    nonisolated func parse(_ source: String) -> Document
}
