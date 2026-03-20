import Testing
@testable import Oppi

@MainActor
@Suite("Tool row render plan contract")
struct ToolRowPlanContractTests {
    @Test func collapsedToolPlanUsesCollapsedInteractionSpec() {
        let plan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            preview: "summary",
            collapsedImageBase64: "abcd",
            isExpanded: false
        ))

        #expect(plan.interactionPolicy == nil)
        #expect(plan.interactionSpec == .collapsed)
    }

    @Test func expandedBashPlanKeepsCommandSelectionButPrefersFullScreenForOutput() throws {
        let plan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
            copyCommandText: "echo hi",
            copyOutputText: "hi",
            isExpanded: true,
            selectedTextPiRouter: SelectedTextPiActionRouter { _ in },
            selectedTextSessionId: "session-1"
        ))

        let policy = try #require(plan.interactionPolicy)
        #expect(policy.mode == .bash(unwrapped: true))
        #expect(policy.supportsFullScreenPreview)
        #expect(plan.interactionSpec.commandSelectionEnabled)
        #expect(!plan.interactionSpec.outputSelectionEnabled)
        #expect(plan.interactionSpec.allowsHorizontalScroll)
        #expect(plan.interactionSpec.enablesTapCopyGesture)
        #expect(plan.interactionSpec.enablesPinchGesture)
    }

    @Test func expandedMarkdownPlanPreservesFullScreenGesturesAndDisablesInlineSelection() throws {
        let plan = ToolRowPlanBuilder.build(configuration: makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "# Header\n\nBody"),
            copyOutputText: "# Header\n\nBody",
            toolNamePrefix: "read",
            isExpanded: true,
            selectedTextPiRouter: SelectedTextPiActionRouter { _ in },
            selectedTextSessionId: "session-1"
        ))

        let policy = try #require(plan.interactionPolicy)
        #expect(policy.mode == .markdown)
        #expect(policy.supportsFullScreenPreview)
        #expect(plan.interactionSpec.enablesTapCopyGesture)
        #expect(plan.interactionSpec.enablesPinchGesture)
        #expect(!plan.interactionSpec.markdownSelectionEnabled)
        #expect(!plan.interactionSpec.expandedLabelSelectionEnabled)
    }

    @Test func hostedPlansDoNotExposeTextFullScreenOrInlineSelection() throws {
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
        let readMediaPolicy = try #require(readMediaPlan.interactionPolicy)
        #expect(readMediaPolicy.mode == .readMedia)
        #expect(!readMediaPolicy.supportsFullScreenPreview)
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
        let plotPolicy = try #require(plotPlan.interactionPolicy)
        #expect(plotPolicy.mode == .plot)
        #expect(!plotPolicy.supportsFullScreenPreview)
        #expect(!plotPlan.interactionSpec.enablesTapCopyGesture)
        #expect(!plotPlan.interactionSpec.enablesPinchGesture)
    }
}
