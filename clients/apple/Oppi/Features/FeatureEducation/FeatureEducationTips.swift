import Foundation
import TipKit

/// Contextual tips for app behaviors that are easy to miss.
///
/// Keep each tip tied to one immediate action. Call the matching `mark...` method
/// when the user completes the action so TipKit stops showing that lesson.
enum FeatureEducationTips {
    private static let testingArgument = "--show-feature-tips-for-testing"
    private static let resetArgument = "--reset-feature-tips"

    static func configure() {
        do {
            if ProcessInfo.processInfo.arguments.contains(resetArgument) {
                try Tips.resetDatastore()
                FeatureEducationTipPresentationStore.standard.reset()
            }

            try Tips.configure([
                .displayFrequency(.immediate),
            ])

#if DEBUG
            if ProcessInfo.processInfo.arguments.contains(testingArgument) {
                Tips.showTipsForTesting(Self.p0TipTypes)
            }
#endif
        } catch {
            #if DEBUG
            print("TipKit configure failed: \(error)")
            #endif
        }
    }

    static let openToolDetails = FeatureEducationTipDescriptor(
        id: "open-tool-details",
        title: "Open tool details",
        message: "Tap a tool row to inspect command, output, diff, or file content.",
        systemImageName: "terminal"
    )

    static let toolOutputShortcuts = FeatureEducationTipDescriptor(
        id: "tool-output-shortcuts",
        title: "Use output shortcuts",
        message: "Double-tap or pinch expanded output. Touch and hold for copy actions.",
        systemImageName: "arrow.up.left.and.arrow.down.right"
    )

    static let answerPrompt = FeatureEducationTipDescriptor(
        id: "answer-prompt",
        title: "Answer prompts here",
        message: "Pick an option or type a response without returning to the Mac.",
        systemImageName: "checkmark.bubble"
    )

    static let busySendMode = FeatureEducationTipDescriptor(
        id: "busy-send-mode",
        title: "Choose how to send",
        message: "Use Steer for this turn. Use Follow-up for the next instruction.",
        systemImageName: "arrow.triangle.branch"
    )

    static let reviewCommentSelection = FeatureEducationTipDescriptor(
        id: "review-selection",
        title: "Comment from code",
        message: "Select text, then tap Comment to add it to your next message.",
        systemImageName: "text.bubble"
    )

    /// The chat's default bar shows only the context ring; this points at the
    /// menu that holds the rest. It names Files, which every chat with a workspace
    /// offers, and Git, offered in a Git workspace; Terminal is left out because it
    /// needs a folder a shell can start in. It calls the button by its three dots and
    /// never ends a line on an ellipsis.
    static let topBarMoreTools = FeatureEducationTipDescriptor(
        id: "chat-top-bar-more",
        title: "Chat tools are in the menu",
        message: "Files, Git, and more are in the \u{2022}\u{2022}\u{2022} menu. Pin them to the top bar in Settings \u{2192} Chat \u{2192} Top Bar.",
        systemImageName: "ellipsis.circle"
    )

#if DEBUG
    static let p0TipTypes: [any Tip.Type] = [
        OpenToolDetailsTip.self,
        ToolOutputShortcutsTip.self,
        AnswerPromptTip.self,
        BusySendModeTip.self,
        ReviewCommentSelectionTip.self,
        TopBarMoreToolsTip.self,
    ]
#endif

    @MainActor
    static func markToolDetailsOpened() {
        OpenToolDetailsTip().invalidate(reason: .actionPerformed)
        FeatureEducationTipPresentationCoordinator.shared.markCompleted(tipID: openToolDetails.id)
    }

    @MainActor
    static func markToolOutputShortcutUsed() {
        ToolOutputShortcutsTip().invalidate(reason: .actionPerformed)
        FeatureEducationTipPresentationCoordinator.shared.markCompleted(tipID: toolOutputShortcuts.id)
    }

    @MainActor
    static func markPromptAnswered() {
        AnswerPromptTip().invalidate(reason: .actionPerformed)
        FeatureEducationTipPresentationCoordinator.shared.markCompleted(tipID: answerPrompt.id)
    }

    @MainActor
    static func markBusySendModeUsed() {
        BusySendModeTip().invalidate(reason: .actionPerformed)
        FeatureEducationTipPresentationCoordinator.shared.markCompleted(tipID: busySendMode.id)
    }

    /// The top bar's menu opened, or Customize Top Bar: the person found the tools.
    @MainActor
    static func markTopBarMoreToolsFound() {
        TopBarMoreToolsTip().invalidate(reason: .actionPerformed)
        FeatureEducationTipPresentationCoordinator.shared.markCompleted(tipID: topBarMoreTools.id)
    }

    @MainActor
    static func markReviewCommentCreated() {
        ReviewCommentSelectionTip().invalidate(reason: .actionPerformed)
        FeatureEducationTipPresentationCoordinator.shared.markCompleted(tipID: reviewCommentSelection.id)
    }

    struct OpenToolDetailsTip: Tip {
        var title: Text { Text(FeatureEducationTips.openToolDetails.title) }
        var message: Text? { Text(FeatureEducationTips.openToolDetails.message) }
        var image: Image? { Image(systemName: FeatureEducationTips.openToolDetails.systemImageName) }
        var options: [any TipOption] { MaxDisplayCount(1) }
    }

    struct ToolOutputShortcutsTip: Tip {
        var title: Text { Text(FeatureEducationTips.toolOutputShortcuts.title) }
        var message: Text? { Text(FeatureEducationTips.toolOutputShortcuts.message) }
        var image: Image? { Image(systemName: FeatureEducationTips.toolOutputShortcuts.systemImageName) }
        var options: [any TipOption] { MaxDisplayCount(1) }
    }

    struct AnswerPromptTip: Tip {
        var title: Text { Text(FeatureEducationTips.answerPrompt.title) }
        var message: Text? { Text(FeatureEducationTips.answerPrompt.message) }
        var image: Image? { Image(systemName: FeatureEducationTips.answerPrompt.systemImageName) }
        var options: [any TipOption] { MaxDisplayCount(1) }
    }

    struct BusySendModeTip: Tip {
        var title: Text { Text(FeatureEducationTips.busySendMode.title) }
        var message: Text? { Text(FeatureEducationTips.busySendMode.message) }
        var image: Image? { Image(systemName: FeatureEducationTips.busySendMode.systemImageName) }
        var options: [any TipOption] { MaxDisplayCount(1) }
    }

    struct TopBarMoreToolsTip: Tip {
        var title: Text { Text(FeatureEducationTips.topBarMoreTools.title) }
        var message: Text? { Text(FeatureEducationTips.topBarMoreTools.message) }
        var image: Image? { Image(systemName: FeatureEducationTips.topBarMoreTools.systemImageName) }
        var options: [any TipOption] { MaxDisplayCount(1) }
    }

    struct ReviewCommentSelectionTip: Tip {
        var title: Text { Text(FeatureEducationTips.reviewCommentSelection.title) }
        var message: Text? { Text(FeatureEducationTips.reviewCommentSelection.message) }
        var image: Image? { Image(systemName: FeatureEducationTips.reviewCommentSelection.systemImageName) }
        var options: [any TipOption] { MaxDisplayCount(1) }
    }
}
