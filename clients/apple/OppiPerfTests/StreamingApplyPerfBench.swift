import Foundation
import Testing
import UIKit
@testable import Oppi

/// Streaming apply pipeline performance benchmark.
///
/// Measures:
/// - **streaming_p95_us**: p95 apply duration during streaming ticks (primary)
/// - **streaming_max_us**: worst-case apply duration
/// - **zero_change_avg_us**: avg cost when nothing changed between ticks
/// - **jank_pct_over_33ms**: percentage of applies exceeding 33ms coalescer budget
///
/// Uses a real UIWindow + UICollectionView with 80+ items to match production
/// conditions where perf degrades.
@Suite("StreamingApplyPerfBench", .tags(.perf))
@MainActor
struct StreamingApplyPerfBench {

    // MARK: - Configuration

    /// Number of streaming ticks to measure (excluding warmup).
    private static let measureTicks = 100
    /// Warmup ticks before measurement begins.
    private static let warmupTicks = 10
    /// Number of zero-change ticks to measure.
    private static let zeroChangeTicks = 50
    /// Number of existing turns to build an 80+ item timeline.
    private static let turnCount = 16

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let window: UIWindow
        let collectionView: AnchoredCollectionView
        let coordinator: ChatTimelineController
        let reducer: TimelineReducer
        let toolOutputStore: ToolOutputStore
        let toolArgsStore: ToolArgsStore
        let toolSegmentStore: ToolSegmentStore
        let connection: ServerConnection
        let scrollController: ChatScrollController
        let audioPlayer: AudioPlayerService

        init() {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
            else {
                fatalError("Missing UIWindowScene")
            }

            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

            collectionView = AnchoredCollectionView(
                frame: window.bounds,
                collectionViewLayout: ChatTimelineController.makeTestLayout()
            )
            window.addSubview(collectionView)
            window.makeKeyAndVisible()

            coordinator = ChatTimelineController()
            coordinator.configureDataSource(collectionView: collectionView)
            collectionView.delegate = coordinator

            reducer = TimelineReducer()
            toolOutputStore = ToolOutputStore()
            toolArgsStore = ToolArgsStore()
            toolSegmentStore = ToolSegmentStore()
            connection = ServerConnection()
            scrollController = ChatScrollController()
            audioPlayer = AudioPlayerService()
        }

        func apply(
            items: [ChatItem],
            streamingAssistantID: String? = nil,
            isBusy: Bool = true
        ) {
            let config = makeTimelineConfiguration(
                items: items,
                isBusy: isBusy,
                streamingAssistantID: streamingAssistantID,
                sessionId: "bench-streaming-apply",
                reducer: reducer,
                toolOutputStore: toolOutputStore,
                toolArgsStore: toolArgsStore,
                toolSegmentStore: toolSegmentStore,
                connection: connection,
                scrollController: scrollController,
                audioPlayer: audioPlayer
            )
            coordinator.apply(configuration: config, to: collectionView)
        }

        deinit {
            MainActor.assumeIsolated {
                window.isHidden = true
            }
        }
    }

    // MARK: - Timeline Builder

    /// Build a realistic 80+ item timeline with mixed content.
    /// turnCount=16 produces: 16 user + 16 thinking + 16 assistant + 32 tool = 80 items.
    private static func buildTimeline(turnCount: Int) -> [ChatItem] {
        var items: [ChatItem] = []
        items.reserveCapacity(turnCount * 5 + 2)
        let now = Date()

        for turn in 0..<turnCount {
            items.append(.userMessage(
                id: "user-\(turn)",
                text: "Analyze the performance of module\(turn) and suggest improvements for the hot path.",
                timestamp: now
            ))

            items.append(.thinking(
                id: "thinking-\(turn)",
                preview: "Looking at allocation patterns, closure captures, and loop inefficiencies in module\(turn).",
                hasMore: true,
                isDone: true
            ))

            items.append(.assistantMessage(
                id: "assistant-\(turn)",
                text: """
                I've analyzed module\(turn). Key findings:

                ## Performance Issues

                1. **Closure allocation in hot loop** — Creates a new closure every iteration
                2. **String concatenation** — Using += in a loop is O(n^2)

                ```swift
                func optimized() {
                    var parts: [String] = []
                    parts.reserveCapacity(items.count)
                    for item in items {
                        parts.append(item.description)
                    }
                    return parts.joined()
                }
                ```

                The fix reduces allocation count by 3x and eliminates the quadratic growth.
                """,
                timestamp: now
            ))

            for t in 0..<2 {
                items.append(.toolCall(
                    id: "tool-\(turn)-\(t)",
                    tool: t == 0 ? "bash" : "read",
                    argsSummary: t == 0 ? "$ cat src/module\(turn).swift" : "src/module\(turn).swift",
                    outputPreview: "import Foundation\nlet x = \(turn)\nfunc process() { /* ... */ }",
                    outputByteCount: 512,
                    isError: false,
                    isDone: true
                ))
            }
        }

        return items
    }

    /// Append a streaming assistant + in-flight tool to the base timeline.
    private static func withStreamingTail(
        base: [ChatItem],
        streamingText: String
    ) -> (items: [ChatItem], streamingID: String) {
        var items = base
        let streamingID = "streaming-assistant"

        items.append(.userMessage(
            id: "user-streaming",
            text: "Explain how async/await works in Swift.",
            timestamp: Date()
        ))

        // In-flight tool alongside the streaming assistant — tests mutable scan cost.
        items.append(.toolCall(
            id: "tool-inflight",
            tool: "bash",
            argsSummary: "$ npm test",
            outputPreview: "",
            outputByteCount: 0,
            isError: false,
            isDone: false
        ))

        items.append(.assistantMessage(
            id: streamingID,
            text: streamingText,
            timestamp: Date()
        ))

        return (items, streamingID)
    }

    /// Build a long, already-finalized markdown prefix plus a live paragraph tail.
    /// This matches the slow production case better than a single growing paragraph:
    /// dozens of frozen text/code segments stay visible while only the final tail changes.
    private static func makeLongStreamingMarkdownPrefix(sectionCount: Int) -> String {
        var sections: [String] = []
        sections.reserveCapacity(sectionCount * 2)

        for section in 1...sectionCount {
            sections.append("""
            ## Section \(section)

            This finalized paragraph includes **bold text**, `inline code`, and a [reference link](https://example.com/\(section)) so the renderer builds realistic attributed text.
            """)

            if section.isMultiple(of: 8) {
                sections.append("""
                ```swift
                struct Worker\(section) {
                    let id: Int
                    func run() -> String { "section-\(section)" }
                }
                ```
                """)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Stats

    private struct Stats {
        let p50Us: Double
        let p95Us: Double
        let maxUs: Double
        let avgUs: Double
        let jankPctOver33ms: Double

        init(durationsNs: [UInt64]) {
            let sorted = durationsNs.sorted()
            let count = sorted.count
            guard count > 0 else {
                p50Us = 0; p95Us = 0; maxUs = 0; avgUs = 0; jankPctOver33ms = 0
                return
            }

            let toUs = { (ns: UInt64) -> Double in Double(ns) / 1000.0 }
            p50Us = toUs(sorted[count / 2])
            p95Us = toUs(sorted[min(count - 1, count * 95 / 100)])
            maxUs = toUs(sorted[count - 1])
            avgUs = toUs(sorted.reduce(0, +) / UInt64(count))

            let jankThresholdNs: UInt64 = 33_000_000  // 33ms
            let jankCount = sorted.filter { $0 > jankThresholdNs }.count
            jankPctOver33ms = Double(jankCount) / Double(count) * 100.0
        }
    }

    // MARK: - Primary Benchmark

    @Test("Streaming apply pipeline: p95, max, zero-change, jank")
    func streamingApplyPipeline() {
        let h = Harness()
        let baseItems = Self.buildTimeline(turnCount: Self.turnCount)
        let initialText = "Here's how async/await works in Swift. "

        // --- Setup: prime the timeline with 80+ items ---
        let (initialItems, streamingID) = Self.withStreamingTail(
            base: baseItems,
            streamingText: initialText
        )
        h.apply(items: initialItems, streamingAssistantID: streamingID)
        h.collectionView.layoutIfNeeded()

        let itemCount = h.coordinator.currentIDs.count
        #expect(itemCount >= 80, "Need 80+ items for realistic bench, got \(itemCount)")

        // Scroll to bottom so the streaming assistant cell is visible.
        // In production, the user watches the streaming assistant at the bottom.
        // Without this, the cell configure (including markdown rendering) doesn't
        // fire during reconfigure, making the bench unrealistically fast.
        let lastIndex = IndexPath(item: h.coordinator.currentIDs.count - 1, section: 0)
        h.collectionView.scrollToItem(at: lastIndex, at: .bottom, animated: false)
        h.collectionView.layoutIfNeeded()

        // --- Phase 1: Streaming ticks (text grows each tick) ---
        var streamingDurationsNs: [UInt64] = []
        streamingDurationsNs.reserveCapacity(Self.measureTicks)

        var currentText = initialText
        let totalTicks = Self.warmupTicks + Self.measureTicks

        for tick in 0..<totalTicks {
            let chunk = "The key concept is structured concurrency, which provides safety guarantees. Tick \(tick). "
            currentText += chunk

            let (tickItems, _) = Self.withStreamingTail(
                base: baseItems,
                streamingText: currentText
            )

            let startNs = DispatchTime.now().uptimeNanoseconds
            h.apply(items: tickItems, streamingAssistantID: streamingID)
            let endNs = DispatchTime.now().uptimeNanoseconds

            if tick >= Self.warmupTicks {
                streamingDurationsNs.append(endNs &- startNs)
            }
        }

        let streamingStats = Stats(durationsNs: streamingDurationsNs)

        // --- Phase 2: Zero-change ticks (identical input) ---
        let lastItems: [ChatItem]
        (lastItems, _) = Self.withStreamingTail(
            base: baseItems,
            streamingText: currentText
        )

        // Prime with the current state.
        h.apply(items: lastItems, streamingAssistantID: streamingID)

        var zeroChangeDurationsNs: [UInt64] = []
        zeroChangeDurationsNs.reserveCapacity(Self.zeroChangeTicks)

        for _ in 0..<Self.zeroChangeTicks {
            let startNs = DispatchTime.now().uptimeNanoseconds
            h.apply(items: lastItems, streamingAssistantID: streamingID)
            let endNs = DispatchTime.now().uptimeNanoseconds
            zeroChangeDurationsNs.append(endNs &- startNs)
        }

        let zeroChangeStats = Stats(durationsNs: zeroChangeDurationsNs)

        // --- Emit METRIC lines ---
        print("METRIC streaming_p95_us=\(String(format: "%.1f", streamingStats.p95Us))")
        print("METRIC streaming_max_us=\(String(format: "%.1f", streamingStats.maxUs))")
        print("METRIC streaming_p50_us=\(String(format: "%.1f", streamingStats.p50Us))")
        print("METRIC streaming_avg_us=\(String(format: "%.1f", streamingStats.avgUs))")
        print("METRIC zero_change_avg_us=\(String(format: "%.1f", zeroChangeStats.avgUs))")
        print("METRIC zero_change_max_us=\(String(format: "%.1f", zeroChangeStats.maxUs))")
        print("METRIC jank_pct_over_33ms=\(String(format: "%.1f", streamingStats.jankPctOver33ms))")
        print("METRIC item_count=\(itemCount)")

        // Sanity: streaming assistant text actually grew.
        if case .assistantMessage(_, let finalText, _) = h.coordinator.currentItemByID[streamingID] {
            #expect(finalText.count > initialText.count, "Streaming text should have grown")
        } else {
            Issue.record("Expected streaming assistant item at end of bench")
        }
    }

    @Test("Long markdown streaming apply: frozen prefix, growing tail")
    func longMarkdownStreamingApplyPipeline() {
        ChatTimelinePerf.reset()
        let h = Harness()
        let baseItems = Self.buildTimeline(turnCount: Self.turnCount)
        let prefix = Self.makeLongStreamingMarkdownPrefix(sectionCount: 48)
        let initialText = prefix + "\n\nThe live streaming tail starts short. "

        let (initialItems, streamingID) = Self.withStreamingTail(
            base: baseItems,
            streamingText: initialText
        )
        h.apply(items: initialItems, streamingAssistantID: streamingID)
        h.collectionView.layoutIfNeeded()

        let itemCount = h.coordinator.currentIDs.count
        #expect(itemCount >= 80, "Need 80+ items for realistic bench, got \(itemCount)")

        let lastIndex = IndexPath(item: h.coordinator.currentIDs.count - 1, section: 0)
        h.collectionView.scrollToItem(at: lastIndex, at: .bottom, animated: false)
        h.collectionView.layoutIfNeeded()

        var durationsNs: [UInt64] = []
        durationsNs.reserveCapacity(Self.measureTicks)

        var currentText = initialText
        let totalTicks = Self.warmupTicks + Self.measureTicks
        for tick in 0..<totalTicks {
            currentText += " Additional streamed prose keeps appending to the final paragraph while the finalized prefix remains unchanged. Tick \(tick)."

            let (tickItems, _) = Self.withStreamingTail(
                base: baseItems,
                streamingText: currentText
            )

            let startNs = DispatchTime.now().uptimeNanoseconds
            h.apply(items: tickItems, streamingAssistantID: streamingID)
            let endNs = DispatchTime.now().uptimeNanoseconds

            if tick >= Self.warmupTicks {
                durationsNs.append(endNs &- startNs)
            }
        }

        let stats = Stats(durationsNs: durationsNs)
        let timelineStats = ChatTimelinePerf.snapshot()
        print("METRIC long_streaming_p95_us=\(String(format: "%.1f", stats.p95Us))")
        print("METRIC long_streaming_max_us=\(String(format: "%.1f", stats.maxUs))")
        print("METRIC long_streaming_p50_us=\(String(format: "%.1f", stats.p50Us))")
        print("METRIC long_streaming_avg_us=\(String(format: "%.1f", stats.avgUs))")
        print("METRIC long_streaming_jank_pct_over_33ms=\(String(format: "%.1f", stats.jankPctOver33ms))")
        print("METRIC long_timeline_apply_max_ms=\(timelineStats.applyMaxMs)")
        print("METRIC long_timeline_layout_max_ms=\(timelineStats.layoutMaxMs)")
        print("METRIC long_cell_configure_max_ms=\(timelineStats.cellConfigureMaxMs)")
    }

    // MARK: - Tick breakdown

    /// A math-heavy answer: headings, prose with inline formulas, display
    /// blocks and lists of formulas, about 10 KB.
    private static func makeMathHeavyAnswer() -> String {
        (1...12).map { section in
            """
            ## Step \(section): the update rule

            Let $x_t \\in \\mathbb{R}^{d}$ be the parameters after step $t$ and $\\eta_{\(section)} > 0$ the step size. \
            The loss $L(x) = \\frac{1}{2}\\|Ax - b\\|^2$ has gradient $\\nabla L(x) = A^\\top (Ax - b)$, so a step costs \
            one product with $A$ and one with $A^\\top$.

            $$
            x_{t+1} = x_t - \\eta_{\(section)} \\nabla L(x_t) = (I - \\eta_{\(section)} A^\\top A) x_t + \\eta_{\(section)} A^\\top b
            $$

            - The Hessian is $H = A^\\top A$, so the step converges when $0 < \\eta < 2 / \\lambda_{\\max}(H)$.
            - With $\\kappa = \\lambda_{\\max} / \\lambda_{\\min}$ the error shrinks like $(1 - 1/\\kappa)^t$.
            - A budget of $\(section * 100)$ steps reaches $\\epsilon \\approx e^{-\(section)}$ when $\\kappa \\le \(section * 10)$.

            """
        }.joined()
    }

    /// A long table-heavy answer: a 150-row table and a 60-row table with
    /// code, bold and dollar amounts in cells, prose around them; about 20 KB.
    private static func makeTableHeavyAnswer() -> String {
        func table(rows: Int, offset: Int) -> String {
            var lines = [
                "| File | Lines | Status | Cost | Note |",
                "| --- | ---: | :---: | ---: | --- |",
            ]
            for row in 0..<rows {
                let index = row + offset
                lines.append(
                    "| `src/module\(index)/File\(index).swift` | \(index * 37 % 900 + 12) | **\(index.isMultiple(of: 3) ? "changed" : "kept")** "
                        + "| $\(index * 13 % 97).\(index % 10)0 | see [notes](https://example.com/\(index)) |"
                )
            }
            return lines.joined(separator: "\n")
        }
        return """
        ## Audit of the module tree

        Every file below was read once. Costs are the measured build minutes at $0.08 a minute, rounded to cents.

        \(table(rows: 150, offset: 0))

        The changed files cluster in the first third. The second table lists the tests that cover them.

        \(table(rows: 60, offset: 150))

        Nothing else changed.

        """
    }

    /// Per-tick milliseconds for one phase of a streamed answer.
    private struct PhaseSamples {
        var ns: [UInt64] = []

        func line(_ name: String) -> String {
            let stats = Stats(durationsNs: ns)
            let quarter = max(1, ns.count / 4)
            let early = Double(ns.prefix(quarter).reduce(0, +)) / Double(quarter) / 1000
            let late = Double(ns.suffix(quarter).reduce(0, +)) / Double(quarter) / 1000
            return String(
                format: "%@ avg=%.1fus p50=%.1fus p95=%.1fus max=%.1fus first-quarter=%.1fus last-quarter=%.1fus",
                name, stats.avgUs, stats.p50Us, stats.p95Us, stats.maxUs, early, late
            )
        }
    }

    /// Streams `answer` in 64-byte ticks through each stage the chat runs per
    /// tick, on separate instances, and prints where a tick's time goes:
    /// the streaming parse, the segment build (parse plus FlatSegment and its
    /// attributed strings), the content view's apply (build plus the segment
    /// applier's views and text storage), the row's height measure (first and
    /// repeated), its layout at that height, and the whole timeline tick
    /// (collection apply and layout) with the answer as the visible streaming
    /// row. A first measure far above the repeat means UIKit re-measured views
    /// that did not change.
    private func measureTickBreakdown(name: String, answer: String) {
        let h = Harness()
        let baseItems = Self.buildTimeline(turnCount: Self.turnCount)
        let width: CGFloat = 358

        var parser = CommonMarkStreamingParser()
        let source = AssistantMarkdownSegmentSource()
        let view = AssistantMarkdownContentView(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        view.hostLayoutWidth = width
        h.window.addSubview(view)
        defer { view.removeFromSuperview() }

        let bytes = Array(answer.utf8)
        var ticks: [String] = []
        var end = 0
        while end < bytes.count {
            end = min(bytes.count, end + 64)
            // Ticks end on a character boundary.
            while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            ticks.append(String(decoding: bytes[..<end], as: UTF8.self))
        }

        let (initialItems, streamingID) = Self.withStreamingTail(base: baseItems, streamingText: "")
        h.apply(items: initialItems, streamingAssistantID: streamingID)
        h.collectionView.layoutIfNeeded()

        var parse = PhaseSamples(), build = PhaseSamples(), apply = PhaseSamples()
        var measure = PhaseSamples(), remeasure = PhaseSamples(), layout = PhaseSamples(), timeline = PhaseSamples()
        func timed(_ samples: inout PhaseSamples, _ body: () -> Void) {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.ns.append(DispatchTime.now().uptimeNanoseconds &- start)
        }

        for text in ticks {
            let config = AssistantMarkdownContentView.Configuration.make(
                content: text,
                isStreaming: true,
                themeID: .dark,
                textSelectionEnabled: false
            )
            timed(&parse) { _ = parser.parse(text) }
            timed(&build) { _ = source.buildSegments(config) }
            timed(&apply) { view.apply(configuration: config) }
            var fitted = CGSize.zero
            func fit() {
                fitted = view.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
            }
            timed(&measure, fit)
            timed(&remeasure, fit)
            // As a self-sizing cell does: take the fitted height, then lay out.
            timed(&layout) {
                view.frame.size = CGSize(width: width, height: fitted.height)
                view.layoutIfNeeded()
            }

            let (items, _) = Self.withStreamingTail(base: baseItems, streamingText: text)
            timed(&timeline) {
                h.apply(items: items, streamingAssistantID: streamingID)
                h.collectionView.layoutIfNeeded()
                let last = IndexPath(item: h.coordinator.currentIDs.count - 1, section: 0)
                h.collectionView.scrollToItem(at: last, at: .bottom, animated: false)
                h.collectionView.layoutIfNeeded()
            }
        }

        // Which views the row's height measure spends its time in, at the
        // final tick: each arranged view measured alone at the row width.
        var byType: [String: (count: Int, ns: UInt64)] = [:]
        if let stack = view.subviews.compactMap({ $0 as? UIStackView }).first {
            for arranged in stack.arrangedSubviews {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = arranged.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                )
                let key = String(describing: type(of: arranged))
                let entry = byType[key] ?? (0, 0)
                byType[key] = (entry.count + 1, entry.ns + DispatchTime.now().uptimeNanoseconds &- start)
            }
        }
        for (key, entry) in byType.sorted(by: { $0.value.ns > $1.value.ns }) {
            print("[TickBreakdown] \(name) measure-by-view \(key) count=\(entry.count) total=\(String(format: "%.1f", Double(entry.ns) / 1000))us")
        }
        print("[TickBreakdown] \(name) bytes=\(bytes.count) ticks=\(ticks.count)")
        print("[TickBreakdown] \(parse.line("parse"))")
        print("[TickBreakdown] \(build.line("segment-build"))")
        print("[TickBreakdown] \(apply.line("content-apply"))")
        print("[TickBreakdown] \(measure.line("row-measure"))")
        print("[TickBreakdown] \(remeasure.line("row-remeasure"))")
        print("[TickBreakdown] \(layout.line("row-layout"))")
        print("[TickBreakdown] \(timeline.line("timeline-tick"))")
        for (phase, samples) in [("parse", parse), ("build", build), ("apply", apply), ("measure", measure), ("layout", layout), ("timeline", timeline)] {
            print("METRIC tick_\(name)_\(phase)_avg_us=\(String(format: "%.1f", Stats(durationsNs: samples.ns).avgUs))")
        }
    }

    @Test("Streaming tick breakdown: math-heavy answer")
    func mathHeavyTickBreakdown() {
        measureTickBreakdown(name: "math", answer: Self.makeMathHeavyAnswer())
    }

    @Test("Streaming tick breakdown: table-heavy answer")
    func tableHeavyTickBreakdown() {
        measureTickBreakdown(name: "table", answer: Self.makeTableHeavyAnswer())
    }

    /// Cold configure+size of 80 real collapsed tool `SafeSizingCell`s.
    /// Descriptor-only builder time is not the measurement; each sample paints
    /// a cell and asks it to self-size.
    @Test("Cold 80-tool SafeSizingCell configure and size")
    func coldCollapsedToolConfigureAndSize() {
        ChatTimelinePerf.reset()
        let h = Harness()
        var items: [ChatItem] = []
        items.reserveCapacity(80)

        for index in 0..<80 {
            let itemID = "cold-tool-\(index)"
            let tool: String
            let argsSummary: String
            switch index % 4 {
            case 0:
                tool = "bash"
                argsSummary = "command: echo \(index)"
                h.toolArgsStore.set(["command": .string("echo \(index)")], for: itemID)
            case 1:
                tool = "read"
                argsSummary = "path: src/file\(index).swift"
                h.toolArgsStore.set(["path": .string("src/file\(index).swift")], for: itemID)
            case 2:
                tool = "edit"
                argsSummary = "path: src/file\(index).swift"
                h.toolArgsStore.set([
                    "path": .string("src/file\(index).swift"),
                    "edits": .array([
                        .object([
                            "oldText": .string("let value = \(index)\n"),
                            "newText": .string("let value = \(index + 1)\n"),
                        ]),
                    ]),
                ], for: itemID)
            default:
                tool = "extensions.backlog"
                argsSummary = "action: list-all"
            }
            items.append(.toolCall(
                id: itemID,
                tool: tool,
                argsSummary: argsSummary,
                outputPreview: "output \(index)",
                outputByteCount: 64,
                isError: false,
                isDone: true
            ))
        }

        let applyStartNs = DispatchTime.now().uptimeNanoseconds
        h.apply(items: items, isBusy: false)
        h.collectionView.layoutIfNeeded()
        let applyMs = Double(DispatchTime.now().uptimeNanoseconds &- applyStartNs) / 1_000_000.0

        var configureDurationsNs: [UInt64] = []
        var sizeDurationsNs: [UInt64] = []
        configureDurationsNs.reserveCapacity(items.count)
        sizeDurationsNs.reserveCapacity(items.count)

        let width = h.collectionView.bounds.width > 0 ? h.collectionView.bounds.width : 390
        for (index, item) in items.enumerated() {
            let configureStartNs = DispatchTime.now().uptimeNanoseconds
            let configuration = h.coordinator.toolRowConfiguration(itemID: item.id, item: item)
            let cell = SafeSizingCell(frame: CGRect(x: 0, y: 0, width: width, height: 44))
            cell.contentConfiguration = configuration
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.contentView.clipsToBounds = true
            configureDurationsNs.append(DispatchTime.now().uptimeNanoseconds &- configureStartNs)

            #expect(
                !(configuration?.makeContentView() is ToolTimelineRowContentView),
                "collapsed tool \(item.id) must use cheap content view"
            )

            let attributes = UICollectionViewLayoutAttributes(
                forCellWith: IndexPath(item: index, section: 0)
            )
            attributes.size = CGSize(width: width, height: 100)
            let sizeStartNs = DispatchTime.now().uptimeNanoseconds
            let fitted = cell.preferredLayoutAttributesFitting(attributes)
            sizeDurationsNs.append(DispatchTime.now().uptimeNanoseconds &- sizeStartNs)
            #expect(fitted.size.height.isFinite && fitted.size.height > 0)
        }

        let configureStats = Stats(durationsNs: configureDurationsNs)
        let sizeStats = Stats(durationsNs: sizeDurationsNs)
        let timelineStats = ChatTimelinePerf.snapshot()

        print("METRIC cold_80_tool_apply_ms=\(String(format: "%.1f", applyMs))")
        print("METRIC collapsed_tool_configure_p50_us=\(String(format: "%.1f", configureStats.p50Us))")
        print("METRIC collapsed_tool_configure_p95_us=\(String(format: "%.1f", configureStats.p95Us))")
        print("METRIC collapsed_tool_configure_max_us=\(String(format: "%.1f", configureStats.maxUs))")
        print("METRIC collapsed_tool_size_p50_us=\(String(format: "%.1f", sizeStats.p50Us))")
        print("METRIC collapsed_tool_size_p95_us=\(String(format: "%.1f", sizeStats.p95Us))")
        print("METRIC collapsed_tool_size_max_us=\(String(format: "%.1f", sizeStats.maxUs))")
        print("METRIC cold_80_cell_configure_max_ms=\(timelineStats.cellConfigureMaxMs)")
        print("METRIC cold_80_failsafe_configure_count=\(timelineStats.failsafeConfigureCount)")

        #expect(items.count == 80)
        #expect(timelineStats.failsafeConfigureCount == 0)
    }
}
