import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Feature education tool row tips")
struct FeatureEducationToolRowTipTests {
    @Test func inlineToolTipInsertionInvalidatesEnclosingCollectionLayout() throws {
        FeatureEducationTipPresentationCoordinator.shared.resetForTesting()
        ToolTimelineRowContentView.forcesInlineFeatureTipsForTesting = true
        var invalidationRequests = 0
        ToolTimelineRowContentView.featureEducationTipLayoutInvalidationHookForTesting = {
            invalidationRequests += 1
        }
        defer {
            ToolTimelineRowContentView.forcesInlineFeatureTipsForTesting = false
            ToolTimelineRowContentView.featureEducationTipLayoutInvalidationHookForTesting = nil
            FeatureEducationTipPresentationCoordinator.shared.resetForTesting()
        }

        let initial = makeFeatureEducationToolConfiguration(isDone: false)
        let done = makeFeatureEducationToolConfiguration(isDone: true)
        let rowView = ToolTimelineRowContentView(configuration: initial)

        rowView.configuration = done
        #expect(inlineFeatureTipView(in: rowView) != nil, "Expected the completed tool row to insert its feature education tip")

        #expect(invalidationRequests > 0, "Adding an inline feature tip must request timeline cell remeasurement")
    }
}

@MainActor
private func inlineFeatureTipView(in view: ToolTimelineRowContentView) -> UIView? {
    guard let value = Mirror(reflecting: view).children.first(where: { $0.label == "featureTipView" })?.value else {
        return nil
    }
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return value as? UIView }
    return mirror.children.first?.value as? UIView
}

private func makeFeatureEducationToolConfiguration(isDone: Bool) -> ToolTimelineRowConfiguration {
    ToolTimelineRowConfiguration(
        itemID: "feature-education-tool-tip-test",
        title: "bash echo feature education",
        preview: "feature education output preview",
        expandedContent: .bash(
            command: "echo feature education",
            output: "feature education output preview",
            unwrapped: false
        ),
        copyCommandText: "echo feature education",
        copyOutputText: "feature education output preview",
        languageBadge: "bash",
        trailing: isDone ? "done" : "running",
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: "bash",
        toolNameColor: .systemGreen,
        editAdded: nil,
        editRemoved: nil,
        collapsedImageBase64: nil,
        collapsedImageMimeType: nil,
        isExpanded: false,
        isDone: isDone,
        isError: false,
        startedAt: isDone ? nil : Date(),
        elapsedSeconds: isDone ? 1 : nil,
        segmentAttributedTitle: nil,
        segmentAttributedTrailing: nil
    )
}
