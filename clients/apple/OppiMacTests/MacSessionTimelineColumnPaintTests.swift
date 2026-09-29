import Foundation
import Testing
@testable import Oppi

@Suite("Mac session timeline column paint")
struct MacSessionTimelineColumnPaintTests {
    @Test func columnPaintsTheLiveThemeBehindTransparentTimelineRows() throws {
        let source = try macSessionTimelineSource()
        let column = try sourceSlice(
            named: "struct MacSessionTimelineView: View {",
            until: "private struct MacSessionTimelineScrollSnapshot",
            in: source
        )
        #expect(column.contains(".themedScrollSurface()"))
        #expect(column.contains(".foregroundStyle(.themeFg)"))
    }

    @Test func proseColumnWidensWithMessageZoom() {
        // 50em of the live body size, never narrower than the reading minimum.
        #expect(MacTimelineProsePaint.readableColumnWidth(bodyPointSize: 15) == 750)
        #expect(MacTimelineProsePaint.readableColumnWidth(bodyPointSize: 20) == 1_000)
        #expect(MacTimelineProsePaint.readableColumnWidth(bodyPointSize: 10) == 560)
    }

    @Test func mermaidRasterTracksTheMeasuredCardAndIgnoresMinorJitter() throws {
        #expect(MacMermaidInlineLayout.rasterWidth(containerWidth: 720) == 704)
        #expect(MacMermaidInlineLayout.rasterWidth(containerWidth: 2_000) == 1_200)
        #expect(MacMermaidInlineLayout.rasterWidth(containerWidth: 12) == nil)
        #expect(MacMermaidInlineLayout.shouldUpdateRasterWidth(current: nil, candidate: 704))
        #expect(!MacMermaidInlineLayout.shouldUpdateRasterWidth(current: 704, candidate: 712))
        #expect(MacMermaidInlineLayout.shouldUpdateRasterWidth(current: 704, candidate: 713))

        let source = try macMermaidSource()
        #expect(source.contains("theme.macMermaidRenderTheme"))
        #expect(source.contains("renderThemeIdentity"))
        #expect(source.contains("maxWidth: request.rasterWidth"))
        #expect(!source.contains("ThemeRuntimeState.currentPalette"))
        #expect(!source.contains("maxWidth: 640"))
    }

    @Test func toolsAndThinkingKeepFullWidth() throws {
        let source = try macSessionTimelineSource()
        let tool = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )
        let thinking = try sourceSlice(
            named: "struct ThinkingTimelineBubble: View {",
            until: "private struct MarkdownTimelineBubble: View {",
            in: source
        )

        #expect(tool.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(thinking.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    @Test func emptyFailureOwnsExactlyOneRetryAction() throws {
        let source = try macSessionTimelineSource()
        let timeline = try sourceSlice(
            named: "struct MacSessionTimelineView: View {",
            until: "private struct MacSessionTimelineScrollSnapshot",
            in: source
        )

        #expect(timeline.components(separatedBy: "Button(\"Retry\")").count - 1 == 1)
        #expect(timeline.contains("Task { await store.loadSelectedFromLocalConfig() }"))
        #expect(timeline.contains("mac.timeline.retry"))
    }

    @Test func authoritativeErrorStatusPaintsFailureWithoutTransportDetail() {
        #expect(
            MacTimelineFailurePaint.message(status: .error, lastError: nil)
                == MacTimelineFailurePaint.fallbackMessage
        )
        #expect(
            MacTimelineFailurePaint.message(
                status: .error,
                lastError: "The session stream closed."
            ) == "The session stream closed."
        )
        #expect(MacTimelineFailurePaint.message(status: .ready, lastError: nil) == nil)
    }
}

private func macSessionTimelineSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "OppiMac/Views/MacSessionTimelineViews.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func macMermaidSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "OppiMac/Views/MacMermaidDiagramView.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func sourceSlice(named marker: String, until endMarker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw SourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw SourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}
