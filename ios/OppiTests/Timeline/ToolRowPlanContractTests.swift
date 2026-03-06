import Testing
@testable import Oppi

@MainActor
@Suite("Tool row render plan contract")
struct ToolRowPlanContractTests {
    @Test func collapsedToolPlanTracksPreviewAndImageVisibility() {
        let plan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            preview: "summary",
            collapsedImageBase64: "abcd",
            isExpanded: false
        ))

        #expect(plan.expandedMode == .none)
        #expect(plan.interactionPolicy == nil)
        #expect(plan.interactionSpec == .collapsed)
        #expect(plan.collapsedPreviewPresent)
        #expect(plan.collapsedImagePreviewPresent)
        #expect(!plan.expectsExpandedContainer)
        #expect(!plan.expectsCommandContainer)
        #expect(!plan.expectsOutputContainer)
    }

    @Test func expandedBashPlanKeepsCommandSelectionButPrefersFullScreenForOutput() {
        let plan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyCommandText: "echo hi",
            copyOutputText: "hi",
            isExpanded: true,
            selectedTextPiRouter: SelectedTextPiActionRouter { _ in },
            selectedTextSessionId: "session-1"
        ))

        #expect(plan.expandedMode == .bash)
        #expect(plan.expectsCommandContainer)
        #expect(plan.expectsOutputContainer)
        #expect(!plan.expectsExpandedContainer)
        #expect(plan.interactionPolicy?.supportsFullScreenPreview == true)
        #expect(plan.interactionSpec.supportsFullScreenPreview)
        #expect(plan.interactionSpec.commandSelectionEnabled)
        #expect(!plan.interactionSpec.outputSelectionEnabled)
        #expect(plan.interactionSpec.allowsHorizontalScroll)
    }

    @Test func expandedMarkdownPlanPreservesFullScreenGesturesAndDisablesInlineSelection() {
        let plan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Header\n\nBody"),
            copyOutputText: "# Header\n\nBody",
            toolNamePrefix: "read",
            isExpanded: true,
            selectedTextPiRouter: SelectedTextPiActionRouter { _ in },
            selectedTextSessionId: "session-1"
        ))

        #expect(plan.expandedMode == .markdown)
        #expect(plan.expectsExpandedContainer)
        #expect(plan.interactionPolicy?.supportsFullScreenPreview == true)
        #expect(plan.interactionSpec.supportsFullScreenPreview)
        #expect(plan.interactionSpec.enablesTapCopyGesture)
        #expect(plan.interactionSpec.enablesPinchGesture)
        #expect(!plan.interactionSpec.markdownSelectionEnabled)
        #expect(!plan.interactionSpec.expandedLabelSelectionEnabled)
    }

    @Test func hostedPlansDoNotExposeTextFullScreenOrInlineSelection() {
        let readMediaPlan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            expandedContent: .readMedia(
                output: "data:image/png;base64,abc",
                filePath: "icon.png",
                startLine: 1
            ),
            toolNamePrefix: "read",
            isExpanded: true,
            selectedTextPiRouter: SelectedTextPiActionRouter { _ in },
            selectedTextSessionId: "session-1"
        ))
        #expect(readMediaPlan.expandedMode == .readMedia)
        #expect(readMediaPlan.expectsExpandedContainer)
        #expect(!readMediaPlan.interactionSpec.supportsFullScreenPreview)
        #expect(!readMediaPlan.interactionSpec.commandSelectionEnabled)
        #expect(!readMediaPlan.interactionSpec.outputSelectionEnabled)
        #expect(!readMediaPlan.interactionSpec.expandedLabelSelectionEnabled)
        #expect(!readMediaPlan.interactionSpec.markdownSelectionEnabled)
        #expect(!readMediaPlan.interactionSpec.enablesTapCopyGesture)
        #expect(!readMediaPlan.interactionSpec.enablesPinchGesture)

        let plotSpec = PlotChartSpec(
            rows: [.init(id: 0, values: ["x": .number(1), "y": .number(2)])],
            marks: [.init(id: "m1", type: .line, x: "x", y: "y")],
            xAxis: .init(),
            yAxis: .init(),
            interaction: .init()
        )
        let plotPlan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            expandedContent: .plot(spec: plotSpec, fallbackText: "x=1 y=2"),
            toolNamePrefix: "plot",
            isExpanded: true
        ))
        #expect(plotPlan.expandedMode == .plot)
        #expect(!plotPlan.interactionSpec.supportsFullScreenPreview)
        #expect(!plotPlan.interactionSpec.enablesTapCopyGesture)
        #expect(!plotPlan.interactionSpec.enablesPinchGesture)
    }
}
