import Foundation
import Testing
import UIKit
@testable import Oppi

/// Expanded tool-row Markdown paths that no other OppiPerfTests bench
/// exercises (`FollowTailBench` drives code and text labels only): one live
/// stream tick on a large document, the live-to-completed swap, a cold completed
/// install, collapse and re-expand of a live row, cell reuse across content
/// kinds, and the collapsed-row apply that runs while scrolling.
///
/// It touches the row through `ToolTimelineRowContentView(configuration:)`,
/// `configuration =` and `layoutIfNeeded()` only, so compare runs across changes
/// to how the row owns its Markdown viewport on the same simulator slot.
///
/// `tool_hosted_row_matrix` covers the hosted media and document surfaces that
/// share the same row: read-media (SVG), CSV table and GeoJSON map installs,
/// re-applying identical hosted content, collapse and re-expand, and cell reuse
/// hosted -> Markdown -> hosted.
///
/// Output format: `METRIC name=number` microseconds (median of `medianRuns`).
@Suite("ToolMarkdownRowPerfProbe", .tags(.perf))
struct ToolMarkdownRowPerfProbe {
    private static let medianRuns = 7
    private static let warmupRuns = 2

    @MainActor
    @Test func tool_markdown_row_matrix() throws {
        try measureLiveStreamTick(name: "live_stream_tick_200", paragraphs: 200)
        try measureLiveStreamTick(name: "live_stream_tick_1000", paragraphs: 1_000)
        try measureLiveToCompletedSwap(name: "live_to_completed_swap_200", paragraphs: 200)
        try measureColdCompletedInstall(name: "cold_completed_install_200", paragraphs: 200)
        try measureCollapseExpandLive(name: "collapse_expand_live_200", paragraphs: 200)
        try measureKindReuseCycle(name: "reuse_md_code_md_100", paragraphs: 100)
        try measureCollapsedApplyLoop(name: "collapsed_apply_x200", applies: 200)
    }

    @MainActor
    @Test func tool_hosted_row_matrix() throws {
        let readMedia = ToolPresentationBuilder.ToolExpandedContent.readMedia(
            output: Self.svg,
            filePath: "fixtures/portrait.svg",
            startLine: 1,
            attachments: []
        )
        let table = ToolPresentationBuilder.ToolExpandedContent.document(.delimitedTable(
            text: Self.csv(rows: 200),
            filePath: "rides.csv"
        ))
        let map = ToolPresentationBuilder.ToolExpandedContent.document(.geoJSON(
            text: Self.geoJSON,
            filePath: "park.geojson"
        ))
        try measureHostedColdInstall(name: "hosted_read_svg_cold_install", content: readMedia, prefix: "read")
        try measureHostedColdInstall(name: "hosted_csv_cold_install_200", content: table, prefix: "read")
        try measureHostedColdInstall(name: "hosted_geojson_cold_install", content: map, prefix: "read")
        try measureHostedReapply(name: "hosted_read_svg_reapply", content: readMedia, prefix: "read")
        try measureHostedReapply(name: "hosted_csv_reapply_200", content: table, prefix: "read")
        try measureHostedCollapseExpand(name: "hosted_csv_collapse_expand_200", content: table, prefix: "read")
        try measureHostedCollapseExpand(name: "hosted_geojson_collapse_expand", content: map, prefix: "read")
        try measureHostedMarkdownReuse(name: "reuse_read_svg_md_svg", content: readMedia)
        try measureHostedMarkdownReuse(name: "reuse_csv_md_csv_200", content: table)
        try measureHostedMarkdownReuse(name: "reuse_geojson_md_geojson", content: map)
    }

    // MARK: - Hosted cases

    /// A fresh row whose first configuration is the hosted content.
    @MainActor
    private func measureHostedColdInstall(
        name: String,
        content: ToolPresentationBuilder.ToolExpandedContent,
        prefix: String
    ) throws {
        for _ in 0 ..< Self.warmupRuns {
            let harness = try makeWindowedHostedView(content: content, prefix: prefix)
            harness.window.isHidden = true
        }
        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            var harness: WindowedToolHarness?
            times.append(try microseconds {
                harness = try makeWindowedHostedView(content: content, prefix: prefix)
            })
            harness?.window.isHidden = true
        }
        print("METRIC \(name)_us=\(median(times))")
    }

    /// Re-applying identical hosted content (what a scrolling timeline does).
    @MainActor
    private func measureHostedReapply(
        name: String,
        content: ToolPresentationBuilder.ToolExpandedContent,
        prefix: String
    ) throws {
        let harness = try makeWindowedHostedView(content: content, prefix: prefix)
        let view = harness.view
        let configuration = makeHostedConfiguration(content: content, prefix: prefix, isExpanded: true)
        for _ in 0 ..< Self.warmupRuns {
            view.configuration = configuration
            forceLayout(view)
        }
        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            times.append(microseconds {
                for _ in 0 ..< 50 { view.configuration = configuration }
                view.layoutIfNeeded()
            })
        }
        print("METRIC \(name)_x50_us=\(median(times))")
        harness.window.isHidden = true
    }

    /// Collapse and re-expand hosted content (retire + reinstall).
    @MainActor
    private func measureHostedCollapseExpand(
        name: String,
        content: ToolPresentationBuilder.ToolExpandedContent,
        prefix: String
    ) throws {
        let harness = try makeWindowedHostedView(content: content, prefix: prefix)
        let view = harness.view
        let collapsed = makeHostedConfiguration(content: content, prefix: prefix, isExpanded: false)
        let expanded = makeHostedConfiguration(content: content, prefix: prefix, isExpanded: true)
        func cycle() {
            view.configuration = collapsed
            view.layoutIfNeeded()
            view.configuration = expanded
            view.layoutIfNeeded()
        }
        for _ in 0 ..< Self.warmupRuns { cycle() }
        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            times.append(microseconds { cycle() })
        }
        print("METRIC \(name)_us=\(median(times))")
        harness.window.isHidden = true
    }

    /// Cell reuse: hosted content -> completed Markdown -> hosted content.
    @MainActor
    private func measureHostedMarkdownReuse(
        name: String,
        content: ToolPresentationBuilder.ToolExpandedContent
    ) throws {
        let text = makeMarkdown(paragraphs: 40)
        let harness = try makeWindowedHostedView(content: content, prefix: "read")
        let view = harness.view
        func cycle() {
            apply(view, text: text, isDone: true)
            view.layoutIfNeeded()
            view.configuration = makeHostedConfiguration(content: content, prefix: "read", isExpanded: true)
            view.layoutIfNeeded()
        }
        for _ in 0 ..< Self.warmupRuns { cycle() }
        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            times.append(microseconds { cycle() })
        }
        print("METRIC \(name)_us=\(median(times))")
        harness.window.isHidden = true
    }

    private static let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 600\"><rect width=\"200\" height=\"600\" fill=\"red\"/></svg>"

    private static func csv(rows: Int) -> String {
        let body = (1 ... rows).map { "2026-09-\($0 % 28 + 1),Route \($0),\($0 * 3).5,Lake Washington loop" }
        return (["date,route,miles,notes"] + body).joined(separator: "\n")
    }

    private static let geoJSON = """
    {"type":"FeatureCollection","features":[
    {"type":"Feature","properties":{"name":"Rainier"},"geometry":{"type":"Point","coordinates":[-121.7603,46.8523]}},
    {"type":"Feature","properties":{"name":"Loop"},"geometry":{"type":"LineString","coordinates":[[-122.34,47.62],[-122.33,47.63],[-122.31,47.62]]}}
    ]}
    """

    @MainActor
    private func makeHostedConfiguration(
        content: ToolPresentationBuilder.ToolExpandedContent,
        prefix: String,
        isExpanded: Bool
    ) -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "hosted",
            expandedContent: content,
            toolNamePrefix: prefix,
            isExpanded: isExpanded,
            isDone: true
        )
    }

    @MainActor
    private func makeWindowedHostedView(
        content: ToolPresentationBuilder.ToolExpandedContent,
        prefix: String
    ) throws -> WindowedToolHarness {
        try makeWindowedView(
            configuration: makeHostedConfiguration(content: content, prefix: prefix, isExpanded: true)
        )
    }

    // MARK: - Cases

    /// One append tick on a large live document, through the deferred layout
    /// pass (what the timeline pays per coalesced stream flush).
    @MainActor
    private func measureLiveStreamTick(name: String, paragraphs: Int) throws {
        let prefix = makeMarkdown(paragraphs: paragraphs)
        let harness = try makeWindowedView(text: prefix, isDone: false)
        let view = harness.view

        for round in 0 ..< Self.warmupRuns {
            apply(view, text: prefix, isDone: false)
            forceLayout(view)
            apply(view, text: prefix + tick(round), isDone: false)
            forceLayout(view)
        }

        var times: [Int] = []
        for round in 0 ..< Self.medianRuns {
            apply(view, text: prefix, isDone: false)
            forceLayout(view)
            let next = prefix + tick(round + 100)
            times.append(microseconds {
                apply(view, text: next, isDone: false)
                view.layoutIfNeeded()
            })
        }
        print("METRIC \(name)_us=\(median(times))")
        harness.window.isHidden = true
    }

    /// The completion swap: live incremental viewport -> immutable reader.
    @MainActor
    private func measureLiveToCompletedSwap(name: String, paragraphs: Int) throws {
        let text = makeMarkdown(paragraphs: paragraphs)
        let harness = try makeWindowedView(text: text, isDone: false)
        let view = harness.view

        for _ in 0 ..< Self.warmupRuns {
            apply(view, text: text, isDone: false)
            forceLayout(view)
            apply(view, text: text, isDone: true)
            forceLayout(view)
        }

        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            apply(view, text: text, isDone: false)
            forceLayout(view)
            times.append(microseconds {
                apply(view, text: text, isDone: true)
                view.layoutIfNeeded()
            })
        }
        print("METRIC \(name)_us=\(median(times))")
        harness.window.isHidden = true
    }

    /// A fresh row whose first configuration is completed Markdown.
    @MainActor
    private func measureColdCompletedInstall(name: String, paragraphs: Int) throws {
        let text = makeMarkdown(paragraphs: paragraphs)

        for _ in 0 ..< Self.warmupRuns {
            let harness = try makeWindowedView(text: text, isDone: true)
            harness.window.isHidden = true
        }

        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            var harness: WindowedToolHarness?
            times.append(try microseconds {
                harness = try makeWindowedView(text: text, isDone: true)
            })
            harness?.window.isHidden = true
        }
        print("METRIC \(name)_us=\(median(times))")
    }

    /// Collapse and re-expand a live row (retire + remount of retained content).
    @MainActor
    private func measureCollapseExpandLive(name: String, paragraphs: Int) throws {
        let text = makeMarkdown(paragraphs: paragraphs)
        let harness = try makeWindowedView(text: text, isDone: false)
        let view = harness.view

        for _ in 0 ..< Self.warmupRuns {
            view.configuration = makeConfiguration(text: text, isDone: false, isExpanded: false)
            forceLayout(view)
            apply(view, text: text, isDone: false)
            forceLayout(view)
        }

        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            times.append(microseconds {
                view.configuration = makeConfiguration(text: text, isDone: false, isExpanded: false)
                view.layoutIfNeeded()
                apply(view, text: text, isDone: false)
                view.layoutIfNeeded()
            })
        }
        print("METRIC \(name)_us=\(median(times))")
        harness.window.isHidden = true
    }

    /// Cell reuse across kinds: completed Markdown -> code -> completed Markdown.
    @MainActor
    private func measureKindReuseCycle(name: String, paragraphs: Int) throws {
        let text = makeMarkdown(paragraphs: paragraphs)
        let code = (1 ... 60).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let harness = try makeWindowedView(text: text, isDone: true)
        let view = harness.view

        func cycle() {
            view.configuration = makeTimelineToolConfiguration(
                title: "read Test.swift",
                expandedContent: .code(text: code, language: .swift, startLine: 1, filePath: "Test.swift"),
                toolNamePrefix: "read",
                isExpanded: true,
                isDone: true
            )
            view.layoutIfNeeded()
            apply(view, text: text, isDone: true)
            view.layoutIfNeeded()
        }

        for _ in 0 ..< Self.warmupRuns { cycle() }

        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            times.append(microseconds { cycle() })
        }
        print("METRIC \(name)_us=\(median(times))")
        harness.window.isHidden = true
    }

    /// Hot path while scrolling: an already collapsed row re-applied.
    @MainActor
    private func measureCollapsedApplyLoop(name: String, applies: Int) throws {
        let text = makeMarkdown(paragraphs: 20)
        let harness = try makeWindowedView(text: text, isDone: true)
        let view = harness.view
        let collapsed = makeConfiguration(text: text, isDone: true, isExpanded: false)
        view.configuration = collapsed
        forceLayout(view)

        for _ in 0 ..< Self.warmupRuns {
            for _ in 0 ..< applies { view.configuration = collapsed }
        }

        var times: [Int] = []
        for _ in 0 ..< Self.medianRuns {
            times.append(microseconds {
                for _ in 0 ..< applies { view.configuration = collapsed }
            })
        }
        print("METRIC \(name)_us=\(median(times))")
        harness.window.isHidden = true
    }

    // MARK: - Content

    private func makeMarkdown(paragraphs: Int) -> String {
        var blocks: [String] = ["# Tool Markdown Probe\n"]
        for index in 1 ... max(1, paragraphs) {
            blocks.append(
                "Paragraph \(index) with **bold**, `inline code`, and a [link](https://example.com/\(index)) to keep inline formatting busy across several wrapped lines on a phone viewport."
            )
            if index.isMultiple(of: 25) {
                blocks.append("```swift\nfunc probe\(index)() -> Int { \(index) }\n```")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    private func tick(_ round: Int) -> String {
        "\n\nTail tick \(round) appended while the tool is still streaming."
    }

    // MARK: - Harness

    private struct WindowedToolHarness {
        let window: UIWindow
        let view: ToolTimelineRowContentView
    }

    @MainActor
    private func makeConfiguration(
        text: String,
        isDone: Bool,
        isExpanded: Bool = true
    ) -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "notes",
            expandedContent: .markdown(text: text),
            toolNamePrefix: "extensions.notes",
            isExpanded: isExpanded,
            isDone: isDone
        )
    }

    @MainActor
    private func apply(_ view: ToolTimelineRowContentView, text: String, isDone: Bool) {
        view.configuration = makeConfiguration(text: text, isDone: isDone)
    }

    private struct MissingWindowScene: Error {}

    @MainActor
    private func makeWindowedView(text: String, isDone: Bool) throws -> WindowedToolHarness {
        try makeWindowedView(configuration: makeConfiguration(text: text, isDone: isDone))
    }

    @MainActor
    private func makeWindowedView(configuration: ToolTimelineRowConfiguration) throws -> WindowedToolHarness {
        let view = ToolTimelineRowContentView(configuration: configuration)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw MissingWindowScene()
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            view.topAnchor.constraint(equalTo: window.topAnchor),
        ])
        window.makeKeyAndVisible()
        forceLayout(view)
        return WindowedToolHarness(window: window, view: view)
    }

    @MainActor
    private func forceLayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func microseconds(_ body: () throws -> Void) rethrows -> Int {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.attoseconds / 1_000_000_000_000)
            + Int(elapsed.components.seconds) * 1_000_000
    }

    private func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
