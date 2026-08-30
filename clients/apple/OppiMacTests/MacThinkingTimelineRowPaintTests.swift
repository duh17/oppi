import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oppi

@MainActor
@Suite("Mac thinking timeline row paint")
struct MacThinkingTimelineRowPaintTests {
    @Test func thinkingRowUsesDedicatedFoldingBubbleNotUnboundedMarkdown() throws {
        let source = try macThinkingTimelineSource()
        let thinkingCase = try sourceSlice(
            named: "case .thinking(let id, let preview, let hasMore, let isDone):",
            until: "case .toolCall(",
            in: source
        )

        #expect(thinkingCase.contains("ThinkingTimelineBubble("))
        #expect(!thinkingCase.contains("MarkdownTimelineBubble("))
        #expect(!thinkingCase.contains("openToolDocument"))
        #expect(!thinkingCase.contains("WindowGroup"))
    }

    @Test func thinkingBubbleDoesNotStealDocumentColumn() throws {
        let source = try macThinkingTimelineSource()
        let bubble = try sourceSlice(
            named: "enum ThinkingFoldPolicy {",
            until: "private struct MarkdownTimelineBubble: View {",
            in: source
        )

        #expect(bubble.contains("Button(isExpanded ? \"Collapse\" : \"Expand\")"))
        #expect(bubble.contains("ThinkingFoldPolicy.collapsedMaxHeight"))
        #expect(bubble.contains("ThinkingFoldLayout("))
        #expect(bubble.contains("ThinkingFoldPolicy.overflowsCollapsedCap"))
        #expect(bubble.contains("ThinkingPaintedHeightKey"))
        #expect(bubble.contains("onPreferenceChange(ThinkingPaintedHeightKey.self)"))
        #expect(!bubble.contains("DispatchQueue.main.async"))
        #expect(!bubble.contains("onOverflowChange"))
        #expect(!bubble.contains("WindowGroup"))
        #expect(!bubble.contains("openToolDocument"))
        #expect(!bubble.contains("MacToolDocumentColumn"))
        #expect(!bubble.contains("ThinkingTimelineRowContent"))
        #expect(!bubble.contains("shouldOfferExpand(preview:"))
        #expect(!bubble.contains("estimatedBodyHeight"))
        #expect(!bubble.contains("estimatedCharsPerLine"))
    }

    @Test func shortCharacterTallMarkdownAppliesPaintedCapAndExpand() {
        let preview = Self.shortCharacterTallMarkdown
        #expect(preview.utf8.count < ChatItem.maxPreviewLength)
        #expect(discardedWrapAt48Height(preview) <= Double(ThinkingFoldPolicy.collapsedMaxHeight))

        let unconstrained = fittedHeight(
            of: MacMarkdownDocumentView(markdown: preview, itemID: "think-unconstrained-tall"),
            width: thinkingTimelineWidth
        )
        #expect(
            unconstrained > ThinkingFoldPolicy.collapsedMaxHeight,
            "Fixture must paint taller than 200pt so a wrap-at-48 skip is observable (painted \(unconstrained))"
        )

        let collapsed = collapsedBubbleHeight(preview: preview)
        #expect(
            collapsed <= ThinkingFoldPolicy.collapsedMaxHeight + 80,
            "Collapsed bubble must cap painted overflow at 200pt plus header/padding (got \(collapsed), unconstrained markdown \(unconstrained))"
        )
        #expect(collapsed < unconstrained)
    }

    @Test func shortThinkingThatFitsStaysUncappedWithoutControl() {
        let preview = "Short thought"
        let unconstrained = fittedHeight(
            of: MacMarkdownDocumentView(markdown: preview, itemID: "think-unconstrained-short"),
            width: thinkingTimelineWidth
        )
        #expect(unconstrained < ThinkingFoldPolicy.collapsedMaxHeight)

        let collapsed = collapsedBubbleHeight(preview: preview)
        #expect(collapsed < ThinkingFoldPolicy.collapsedMaxHeight)
        #expect(collapsed < ThinkingFoldPolicy.collapsedMaxHeight + 80)
    }

    /// Heading + bullets + a small fence: few wrap-at-48 lines, but markdown
    /// chrome paints past the 200pt cap.
    private static let shortCharacterTallMarkdown = """
    # Plan
    - a
    - b
    - c
    ```
    x
    ```
    """
}

private let thinkingTimelineWidth: CGFloat = 360

private func discardedWrapAt48Height(_ text: String) -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    var lineCount = 0
    trimmed.enumerateLines { line, _ in
        let chars = max(line.count, 1)
        lineCount += (chars + 48 - 1) / 48
    }
    return Double(lineCount) * 22
}

@MainActor
private func collapsedBubbleHeight(preview: String) -> CGFloat {
    let bubble = ThinkingTimelineBubble(
        itemID: "think-fold-\(UUID().uuidString)",
        preview: preview,
        hasMore: false,
        isDone: true
    )
    .frame(width: thinkingTimelineWidth, alignment: .topLeading)

    let controller = NSHostingController(rootView: bubble)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: thinkingTimelineWidth, height: 4_000),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    controller.view.setFrameSize(NSSize(width: thinkingTimelineWidth, height: 4_000))
    window.orderFrontRegardless()
    for _ in 0..<4 {
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    return controller.sizeThatFits(
        in: CGSize(width: thinkingTimelineWidth, height: CGFloat.greatestFiniteMagnitude)
    ).height
}

@MainActor
private func fittedHeight<V: View>(of view: V, width: CGFloat) -> CGFloat {
    let controller = NSHostingController(
        rootView: view.frame(width: width, alignment: .topLeading)
    )
    return controller.sizeThatFits(
        in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    ).height
}

private func macThinkingTimelineSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "OppiMac/Views/MacSessionTimelineViews.swift")
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
