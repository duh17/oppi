import Testing
@testable import Oppi

@Suite("Tool row render plan contract")
@MainActor
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
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSessionId: "session-1"
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
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSessionId: "session-1"
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
            , attachments: []),
            toolNamePrefix: "read",
            isExpanded: true,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter { _ in },
            reviewCommentSessionId: "session-1"
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

    }
}
