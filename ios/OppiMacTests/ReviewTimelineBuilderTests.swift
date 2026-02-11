@testable import OppiMac
import XCTest

final class ReviewTimelineBuilderTests: XCTestCase {
    func testBuildMapsToolCallAndResultDetails() {
        let events = [
            TraceEvent(
                id: "evt-user",
                type: .user,
                timestamp: "2026-02-11T06:00:00.000Z",
                text: "run tests",
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ),
            TraceEvent(
                id: "evt-call",
                type: .toolCall,
                timestamp: "2026-02-11T06:00:01.000Z",
                text: nil,
                tool: "bash",
                args: ["command": .string("npm test")],
                output: nil,
                toolCallId: "call-1",
                toolName: nil,
                isError: nil,
                thinking: nil
            ),
            TraceEvent(
                id: "evt-result",
                type: .toolResult,
                timestamp: "2026-02-11T06:00:02.000Z",
                text: nil,
                tool: nil,
                args: nil,
                output: "all tests passed",
                toolCallId: "call-1",
                toolName: "bash",
                isError: false,
                thinking: nil
            ),
        ]

        let items = ReviewTimelineBuilder.build(from: events)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].kind, .user)
        XCTAssertEqual(items[1].kind, .toolCall)
        XCTAssertEqual(items[2].kind, .toolResult)

        XCTAssertEqual(items[1].title, "Tool call: bash")
        XCTAssertEqual(items[1].metadata["tool_call_id"], "call-1")
        XCTAssertTrue(items[1].detail.contains("command"))

        XCTAssertEqual(items[2].title, "Tool output: bash")
        XCTAssertEqual(items[2].preview, "all tests passed")
        XCTAssertEqual(items[2].detail, "all tests passed")
    }

    func testMatchesSearchAcrossMetadataAndBody() {
        let event = TraceEvent(
            id: "evt",
            type: .toolResult,
            timestamp: "2026-02-11T06:00:00.000Z",
            text: nil,
            tool: nil,
            args: nil,
            output: "updated /tmp/report.md",
            toolCallId: "call-report",
            toolName: "write",
            isError: false,
            thinking: nil
        )

        let item = ReviewTimelineBuilder.build(from: [event])[0]

        XCTAssertTrue(ReviewTimelineBuilder.matches(item, query: "report.md"))
        XCTAssertTrue(ReviewTimelineBuilder.matches(item, query: "call-report"))
        XCTAssertFalse(ReviewTimelineBuilder.matches(item, query: "totally-missing"))
    }

    func testPreviewCollapsesWhitespaceAndTruncates() {
        let text = String(repeating: "alpha ", count: 80)
        let event = TraceEvent(
            id: "evt",
            type: .assistant,
            timestamp: "2026-02-11T06:00:00.000Z",
            text: "\n\n\(text)\n\n",
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )

        let item = ReviewTimelineBuilder.build(from: [event])[0]

        XCTAssertTrue(item.preview.hasPrefix("alpha alpha"))
        XCTAssertTrue(item.preview.hasSuffix("…"))
    }
}
