@testable import OppiMac
import XCTest

final class OppiMacTimelineRowBuilderTests: XCTestCase {
    func testBuildPreservesOrderAndIdentifiers() {
        let first = makeItem(
            id: "evt-1",
            kind: .assistant,
            title: "Assistant",
            preview: "First"
        )
        let second = makeItem(
            id: "evt-2",
            kind: .toolCall,
            title: "Tool call: bash",
            preview: "Second"
        )

        let rows = OppiMacTimelineRowBuilder.build(from: [first, second])

        XCTAssertEqual(rows.map(\.id), ["evt-1", "evt-2"])
        XCTAssertEqual(rows.map(\.title), ["Assistant", "Tool call: bash"])
        XCTAssertEqual(rows.map(\.subtitle), ["First", "Second"])
    }

    func testBuildMapsKindSymbolNames() {
        let rows = OppiMacTimelineRowBuilder.build(from: [
            makeItem(id: "a", kind: .user, title: "User", preview: "..."),
            makeItem(id: "b", kind: .assistant, title: "Assistant", preview: "..."),
            makeItem(id: "c", kind: .toolCall, title: "Tool call", preview: "..."),
            makeItem(id: "d", kind: .toolResult, title: "Tool output", preview: "..."),
            makeItem(id: "e", kind: .compaction, title: "Compaction", preview: "..."),
        ])

        XCTAssertEqual(rows[0].symbolName, "person.fill")
        XCTAssertEqual(rows[1].symbolName, "sparkles")
        XCTAssertEqual(rows[2].symbolName, "hammer")
        XCTAssertEqual(rows[3].symbolName, "terminal")
        XCTAssertEqual(rows[4].symbolName, "arrow.trianglehead.2.clockwise.rotate.90")
    }

    func testBuildUsesEmptyFallbackWhenPreviewIsBlank() {
        let rows = OppiMacTimelineRowBuilder.build(from: [
            makeItem(id: "evt", kind: .system, title: "System", preview: "   \n\n  "),
        ])

        XCTAssertEqual(rows.first?.subtitle, "(empty)")
    }

    func testBuildExtractsBashCommandFromToolCallDetailJSON() {
        let item = ReviewTimelineItem(
            id: "tool-call",
            kind: .toolCall,
            timestamp: Date(timeIntervalSince1970: 1),
            title: "Tool call: bash",
            preview: "command: git status",
            detail: "{\n  \"command\" : \"git status\"\n}",
            metadata: ["tool": "bash", "tool_call_id": "call-1"]
        )

        let row = OppiMacTimelineRowBuilder.build(from: [item]).first

        XCTAssertEqual(row?.commandText, "git status")
        XCTAssertEqual(row?.toolCallId, "call-1")
        XCTAssertNil(row?.outputText)
    }

    func testBuildCombinesToolCallAndResultWithMatchingToolCallID() {
        let callItem = ReviewTimelineItem(
            id: "tool-call",
            kind: .toolCall,
            timestamp: Date(timeIntervalSince1970: 1),
            title: "Tool call: bash",
            preview: "command: git status",
            detail: "{\n  \"command\" : \"git status\"\n}",
            metadata: ["tool": "bash", "tool_call_id": "call-1"]
        )

        let resultItem = ReviewTimelineItem(
            id: "tool-result",
            kind: .toolResult,
            timestamp: Date(timeIntervalSince1970: 2),
            title: "Tool output",
            preview: "On branch main",
            detail: "On branch main",
            metadata: ["tool_call_id": "call-1"]
        )

        let rows = OppiMacTimelineRowBuilder.build(from: [callItem, resultItem])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "tool-result")
        XCTAssertEqual(rows.first?.kind, .toolCall)
        XCTAssertEqual(rows.first?.commandText, "git status")
        XCTAssertEqual(rows.first?.outputText, "On branch main")
        XCTAssertEqual(rows.first?.toolCallId, "call-1")
    }

    func testBuildToolResultCarriesErrorFlagAndOutputSnippet() {
        let output = (0..<80).map { "line-\($0)" }.joined(separator: "\n")
        let item = ReviewTimelineItem(
            id: "tool-result",
            kind: .toolResult,
            timestamp: Date(timeIntervalSince1970: 1),
            title: "Tool output",
            preview: "line-0",
            detail: output,
            metadata: ["is_error": "true", "tool_call_id": "call-2"]
        )

        let row = OppiMacTimelineRowBuilder.build(from: [item]).first

        XCTAssertEqual(row?.toolCallId, "call-2")
        XCTAssertEqual(row?.isError, true)
        XCTAssertNotNil(row?.outputText)
        XCTAssertTrue(row?.outputText?.contains("lines omitted") == true)
        XCTAssertTrue(row?.outputCaption.contains("truncated") == true)
    }

    func testBuildToolResultPrettyPrintsJSONOutput() {
        let item = ReviewTimelineItem(
            id: "tool-json",
            kind: .toolResult,
            timestamp: Date(timeIntervalSince1970: 1),
            title: "Tool output",
            preview: "{\"z\":1,\"a\":2}",
            detail: "{\"z\":1,\"a\":2}",
            metadata: [:]
        )

        let row = OppiMacTimelineRowBuilder.build(from: [item]).first

        XCTAssertEqual(row?.outputCaption, "Output · JSON")
        XCTAssertEqual(row?.outputText?.contains("\n"), true)
        XCTAssertEqual(row?.outputText?.contains("\"a\""), true)
    }

    func testBuildToolResultStripsANSIEscapes() {
        let item = ReviewTimelineItem(
            id: "tool-ansi",
            kind: .toolResult,
            timestamp: Date(timeIntervalSince1970: 1),
            title: "Tool output",
            preview: "ansi",
            detail: "\u{001B}[31merror\u{001B}[0m",
            metadata: [:]
        )

        let row = OppiMacTimelineRowBuilder.build(from: [item]).first

        XCTAssertEqual(row?.outputCaption, "Output · ANSI")
        XCTAssertEqual(row?.outputText, "error")
    }

    private func makeItem(
        id: String,
        kind: ReviewTimelineKind,
        title: String,
        preview: String
    ) -> ReviewTimelineItem {
        ReviewTimelineItem(
            id: id,
            kind: kind,
            timestamp: Date(timeIntervalSince1970: 1),
            title: title,
            preview: preview,
            detail: preview,
            metadata: [:]
        )
    }
}
