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

    @Test func timelineScrollViewUsesSoftTopAndBottomEdges() throws {
        let source = try macSessionTimelineSource()
        let scroll = try sourceSlice(
            named: "private struct MacSessionTimelineScrollView: View {",
            until: "private func scrollToLatestIfAttached",
            in: source
        )
        #expect(scroll.contains(".scrollEdgeEffectStyle(.soft, for: .top)"))
        #expect(scroll.contains(".scrollEdgeEffectStyle(.soft, for: .bottom)"))
    }

    @Test func semanticRowsAvoidCompetingFullCardAccentWashes() throws {
        let source = try macSessionTimelineSource()
        #expect(!source.contains(".fill(theme.bg.highlight)"))
        #expect(source.contains("fill: theme.bg.secondary"))
        #expect(source.contains("fill: theme.accent.purple.opacity(0.12)"))
        #expect(source.contains("fill: theme.accent.red.opacity(0.12)"))
        #expect(!source.contains("fill: theme.accent.orange.opacity(0.12)"))
        #expect(!source.contains("theme.accent.orange.opacity(0.12)"))
        #expect(source.contains("theme.text.tertiary.opacity(isDone ? 0.08 : 0.06)"))
        #expect(!source.contains("return theme.accent.blue.opacity(0.10)"))
        #expect(!source.contains("return theme.accent.green.opacity(0.08)"))
    }

    @Test func proseUsesBoundedRoleSpecificHierarchy() throws {
        #expect(MacTimelineProsePaint.readableMaximumWidth == 720)
        #expect(MacTimelineProsePaint.userLeadingInset == 0)
        #expect(MacTimelineProsePaint.alignment(for: .assistant) == .leading)
        #expect(MacTimelineProsePaint.alignment(for: .user) == .leading)

        let source = try macSessionTimelineSource()
        let user = try sourceSlice(
            named: "case .userMessage(let id, let text, let images, let timestamp):",
            until: "case .assistantMessage(",
            in: source
        )
        let assistant = try sourceSlice(
            named: "case .assistantMessage(let id, let text, let timestamp):",
            until: "case .audioClip(",
            in: source
        )
        let prose = try sourceSlice(
            named: "private struct MarkdownTimelineBubble: View {",
            until: "private struct TimelineBubbleHeader: View {",
            in: source
        )

        #expect(user.contains("role: .user"))
        #expect(assistant.contains("role: .assistant"))
        #expect(prose.contains("MacTimelineProsePaint.readableMaximumWidth"))
        #expect(prose.contains("proseMaximumWidth: MacTimelineProsePaint.readableMaximumWidth"))
        #expect(prose.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(!prose.contains("RoundedRectangle"))
        #expect(!prose.contains("theme.bg.highlight"))
    }

    @Test func graphicalMarkdownBlocksCanUseConversationWidthWhileProseStaysReadable() {
        let prose = MarkdownBlock.paragraph([.text("Readable prose")])
        let mermaid = MarkdownBlock.codeBlock(
            language: "mermaid",
            code: "flowchart LR\nA --> B"
        )
        let code = MarkdownBlock.codeBlock(language: "swift", code: "let value = 1")

        #expect(MacMarkdownBlockWidthPaint.role(for: prose) == .prose)
        #expect(MacMarkdownBlockWidthPaint.role(for: code) == .prose)
        #expect(MacMarkdownBlockWidthPaint.role(for: mermaid) == .graphical)
        #expect(MacMarkdownBlockWidthPaint.maximumWidth(
            for: prose,
            proseMaximumWidth: 720
        ) == 720)
        #expect(MacMarkdownBlockWidthPaint.maximumWidth(
            for: mermaid,
            proseMaximumWidth: 720
        ).isInfinite)
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

    @Test func systemAndCacheRowsMatchIOSCompactStrips() throws {
        let source = try macSessionTimelineSource()
        let rows = try sourceSlice(
            named: "private struct ChatItemSummaryRow: View {",
            until: "enum MacToolTimelineChrome {",
            in: source
        )
        let strip = try sourceSlice(
            named: "private struct MacSystemTimelineStrip: View {",
            until: "enum MacToolTimelineChrome {",
            in: source
        )

        #expect(rows.contains("MacSystemTimelineStrip(message: message, style: .informational)"))
        #expect(rows.contains("MacSystemTimelineStrip(message: message, style: .warning)"))
        #expect(strip.contains(".font(.caption)"))
        #expect(strip.contains(".frame(width: 13, height: 13)"))
        #expect(strip.contains(".frame(maxWidth: .infinity, alignment: .center)"))
        #expect(!strip.contains(".background("))
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
