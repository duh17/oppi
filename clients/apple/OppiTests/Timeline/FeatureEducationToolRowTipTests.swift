import Testing
import SwiftUI
import UIKit
@testable import Oppi

@MainActor
@Suite("Feature education tool row tips")
struct FeatureEducationToolRowTipTests {
    @Test func tipBannerDismissControlUsesMinimumHitTargetAndThemeAccent() throws {
        let originalTheme = ThemeRuntimeState.currentThemeID()
        ThemeRuntimeState.setThemeID(.dark)
        defer { ThemeRuntimeState.setThemeID(originalTheme) }

        let view = FeatureEducationTipBannerView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 360,
                height: FeatureEducationTipBannerView.preferredHeight
            )
        )
        view.configure(descriptor: FeatureEducationTips.openToolDetails, onClose: {})
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let dismissButton = try #require(timelineAllViews(in: view).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "feature-tip.dismiss"
        })
        #expect(dismissButton.bounds.width >= 44)
        #expect(dismissButton.bounds.height >= 44)

        let iconView = try #require(timelineAllImageViews(in: view).first {
            $0.image != nil && !timelineColor($0.tintColor, approximatelyEquals: .secondaryLabel)
        })
        #expect(timelineColor(iconView.tintColor, approximatelyEquals: UIColor(Color.themeCyan)))
        #expect(timelineColor(dismissButton.tintColor, approximatelyEquals: UIColor(Color.themeFgDim)))

        let titleLabel = try #require(timelineAllLabels(in: view).first { $0.text == FeatureEducationTips.openToolDetails.title })
        let messageLabel = try #require(timelineAllLabels(in: view).first { $0.text == FeatureEducationTips.openToolDetails.message })
        #expect(timelineColor(titleLabel.textColor, approximatelyEquals: UIColor(Color.themeFg)))
        #expect(timelineColor(messageLabel.textColor, approximatelyEquals: UIColor(Color.themeFgDim)))
    }

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

private func timelineColor(_ lhs: UIColor?, approximatelyEquals rhs: UIColor, tolerance: CGFloat = 0.01) -> Bool {
    guard let lhs else { return false }

    var lr: CGFloat = 0
    var lg: CGFloat = 0
    var lb: CGFloat = 0
    var la: CGFloat = 0
    var rr: CGFloat = 0
    var rg: CGFloat = 0
    var rb: CGFloat = 0
    var ra: CGFloat = 0

    guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
          rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else {
        return lhs.cgColor == rhs.cgColor
    }

    return abs(lr - rr) <= tolerance &&
        abs(lg - rg) <= tolerance &&
        abs(lb - rb) <= tolerance &&
        abs(la - ra) <= tolerance
}
