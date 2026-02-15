@testable import OppiMac
import XCTest

final class OppiMacInspectorDocumentBuilderTests: XCTestCase {
    func testBuildSortsMetadataRows() {
        let item = makeItem(
            kind: .assistant,
            detail: "Hello",
            metadata: [
                "zeta": "last",
                "alpha": "first",
            ]
        )

        let document = OppiMacInspectorDocumentBuilder.build(from: item)

        XCTAssertEqual(document.metadataRows.map(\.key), ["alpha", "zeta"])
    }

    func testBuildUsesKindSpecificDetailTitles() {
        let toolCall = makeItem(kind: .toolCall, detail: "{\"path\":\"README.md\"}")
        let toolOutput = makeItem(kind: .toolResult, detail: "ok")
        let thinking = makeItem(kind: .thinking, detail: "step by step")

        XCTAssertEqual(OppiMacInspectorDocumentBuilder.build(from: toolCall).detailTitle, "Arguments")
        XCTAssertEqual(OppiMacInspectorDocumentBuilder.build(from: toolOutput).detailTitle, "Output")
        XCTAssertEqual(OppiMacInspectorDocumentBuilder.build(from: thinking).detailTitle, "Reasoning")
    }

    func testBuildUsesEmptyFallbackForBlankDetail() {
        let item = makeItem(kind: .system, detail: "   \n")

        let document = OppiMacInspectorDocumentBuilder.build(from: item)

        XCTAssertEqual(document.detailText, "(empty)")
    }

    private func makeItem(
        kind: ReviewTimelineKind,
        detail: String,
        metadata: [String: String] = [:]
    ) -> ReviewTimelineItem {
        ReviewTimelineItem(
            id: "evt-1",
            kind: kind,
            timestamp: Date(timeIntervalSince1970: 1),
            title: "Title",
            preview: "Preview",
            detail: detail,
            metadata: metadata
        )
    }
}
