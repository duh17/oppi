import Testing
import UIKit
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("ToolPresentationBuilder — Segment Integration")
@MainActor
struct ToolPresentationSegmentTests {

    // MARK: - Helpers

    private func buildConfig(
        tool: String,
        argsSummary: String = "",
        outputPreview: String = "",
        isError: Bool = false,
        isDone: Bool = true,
        callSegments: [StyledSegment]? = nil,
        resultSegments: [StyledSegment]? = nil
    ) -> ToolTimelineRowConfiguration {
        ToolPresentationBuilder.build(
            itemID: "test-1",
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: .init(
                args: nil,
                expandedItemIDs: [],
                fullOutput: "",
                isLoadingOutput: false,
                callSegments: callSegments,
                resultSegments: resultSegments
            )
        )
    }

    // MARK: - Call Segments

    @Test func callSegmentsProduceAttributedTitle() {
        // Bash has an icon ($ symbol) so the "$ " prefix segment is stripped
        // from the title — the icon already represents it.
        let config = buildConfig(
            tool: "bash",
            callSegments: [
                StyledSegment(text: "$ ", style: .bold),
                StyledSegment(text: "npm test", style: .accent),
            ]
        )
        #expect(config.segmentAttributedTitle != nil)
        #expect(config.segmentAttributedTitle!.string == "npm test")
    }

    @Test func noCallSegmentsFallsBackToHardcoded() {
        let config = buildConfig(
            tool: "bash",
            argsSummary: "echo hi"
        )
        #expect(config.segmentAttributedTitle == nil)
        #expect(config.title.contains("echo hi"))
    }

    @Test func callSegmentsOverrideToolNamePrefix() {
        let config = buildConfig(
            tool: "extensions.notes",
            callSegments: [
                StyledSegment(text: "notes ", style: .bold),
                StyledSegment(text: "\"note\"", style: .muted),
            ]
        )
        #expect(config.toolNamePrefix == "notes")
    }

    // MARK: - Result Segments

    @Test func resultSegmentsProduceAttributedTrailing() {
        let config = buildConfig(
            tool: "extensions.notes",
            resultSegments: [
                StyledSegment(text: "✓ Saved ", style: .success),
                StyledSegment(text: "→ journal", style: .muted),
            ]
        )
        #expect(config.segmentAttributedTrailing != nil)
        #expect(config.segmentAttributedTrailing!.string == "✓ Saved → journal")
        // When segment trailing is set, plain trailing should be nil
        #expect(config.trailing == nil)
    }

    @Test func noResultSegmentsFallsBackToPlainTrailing() {
        let config = buildConfig(
            tool: "extensions.notes",
            argsSummary: "text: hello"
        )
        #expect(config.segmentAttributedTrailing == nil)
    }

    // MARK: - Error Segments

    @Test func errorResultSegmentsShowErrorStyle() {
        let config = buildConfig(
            tool: "bash",
            isError: true,
            resultSegments: [
                StyledSegment(text: "exit 127", style: .error),
            ]
        )
        #expect(config.segmentAttributedTrailing != nil)
        #expect(config.segmentAttributedTrailing!.string == "exit 127")
    }

    // MARK: - Extension Tool (unknown to hardcoded renderer)

    @Test func unknownToolWithSegmentsRendersNicely() {
        let config = buildConfig(
            tool: "my_custom_tool",
            callSegments: [
                StyledSegment(text: "custom ", style: .bold),
                StyledSegment(text: "doing stuff", style: .accent),
            ],
            resultSegments: [
                StyledSegment(text: "3 items", style: .success),
            ]
        )
        #expect(config.segmentAttributedTitle!.string == "custom doing stuff")
        #expect(config.segmentAttributedTrailing!.string == "3 items")
    }

    // MARK: - Extension tools

    @Test func extensionNotesCallSegments() {
        let config = buildConfig(
            tool: "extensions.notes",
            callSegments: [
                StyledSegment(text: "notes ", style: .bold),
                StyledSegment(text: "\"Node 25 supports TS\"", style: .muted),
                StyledSegment(text: " [oppi, node]", style: .dim),
            ]
        )
        #expect(config.segmentAttributedTitle!.string == "notes \"Node 25 supports TS\" [oppi, node]")
    }

    @Test func extensionLookupResultSegments() {
        let config = buildConfig(
            tool: "extensions.lookup",
            callSegments: [
                StyledSegment(text: "lookup ", style: .bold),
                StyledSegment(text: "\"rendering\"", style: .muted),
            ],
            resultSegments: [
                StyledSegment(text: "5 match(es)", style: .success),
                StyledSegment(text: " — top: ", style: .muted),
                StyledSegment(text: "[0.85] Tool rendering design", style: .dim),
            ]
        )
        #expect(config.segmentAttributedTitle!.string == "lookup \"rendering\"")
        #expect(config.segmentAttributedTrailing!.string == "5 match(es) — top: [0.85] Tool rendering design")
    }

    @Test func extensionBacklogResultSegments() {
        let config = buildConfig(
            tool: "extensions.backlog",
            callSegments: [
                StyledSegment(text: "backlog ", style: .bold),
                StyledSegment(text: "list", style: .muted),
            ],
            resultSegments: [
                StyledSegment(text: "3/5 open", style: .success),
            ]
        )
        #expect(config.segmentAttributedTitle!.string == "backlog list")
        #expect(config.segmentAttributedTrailing!.string == "3/5 open")
    }
}
