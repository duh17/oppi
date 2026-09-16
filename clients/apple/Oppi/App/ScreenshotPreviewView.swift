#if DEBUG
import Foundation
import SwiftUI
import UIKit

// MARK: - Configuration

enum ScreenshotPreviewConfig {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--screenshot-preview")
    }

    static var screen: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_SCREEN"] ?? "workspace-edit"
    }
}

// MARK: - Root Preview View

/// Launches a standalone screen with mock data for screenshot capture in UI tests.
struct ScreenshotPreviewView: View {
    var body: some View {
        switch ScreenshotPreviewConfig.screen {
        case "workspace-edit":
            WorkspaceEditPreview()
        case "whats-new-build49-light":
            WhatsNewScreenshotPreview(themeID: .light)
        case "whats-new-build49-dark":
            WhatsNewScreenshotPreview(themeID: .dark)
        case "server-resources-skills":
            ServerResourcesScreenshotPreview(screen: .skills)
        case "server-resources-extensions":
            ServerResourcesScreenshotPreview(screen: .extensions)
        case "server-resources-cached-offline":
            ServerResourcesScreenshotPreview(screen: .cachedOffline)
        case "server-provider-navigation-regression":
            ServerProviderNavigationRegressionPreview()
        case "model-providers-quota-inline":
            ModelProvidersQuotaPreview()
        case "inbox-provider-setup-empty":
            InboxProviderSetupPreview(showsSessions: false)
        case "inbox-provider-setup-with-sessions":
            InboxProviderSetupPreview(showsSessions: true)
        case "agent-icons":
            AgentIconProofPreview()
        case "agents-pi-row":
            AgentManagementPiProofPreview()
        case "agent-icon-title-bar-stress":
            AgentIconTitleBarStressPreview()
        case "agent-icons-save-failure":
            AgentIconProofPreview(failsFirstSave: true)
        case "assistant-avatar-picker":
            AssistantAvatarPickerProofPreview()
        case "workspace-sidebar-git-status":
            WorkspaceSidebarGitStatusPreview()
        case "session-timeline":
            SessionTimelinePreview()
        case "quiet-work-strip":
            QuietWorkStripPreview()
        case "chat-file-panel":
            ChatFileBrowserPanelPreview()
        case "file-browser-motion":
            FileBrowserMotionPreview()
        case "review-file-motion":
            ReviewFileMotionPreview()
        case "extension-widget":
            ExtensionSurfacePreview()
        case "chat-input-attachment-containment":
            ChatInputAttachmentContainmentPreview()
        case "review-comment-strip-collapsed":
            ReviewCommentStripScreenshotPreview(isExpanded: false)
        case "review-comment-strip-expanded":
            ReviewCommentStripScreenshotPreview(isExpanded: true)
        case "review-comment-strip-expanded-one":
            ReviewCommentStripScreenshotPreview(
                isExpanded: true,
                comments: Array(ReviewCommentStripScreenshotPreview.fixtureComments.prefix(1))
            )
        case "quick-session-dictation-composer":
            QuickSessionDictationComposerPreview()
        case "dictation-non-wipe-composer":
            QuickSessionDictationComposerPreview(
                title: "Non-wipe dictation composer",
                subtitle: "Earlier utterances stay when a later short phrase arrives.",
                transcriptSteps: [
                    ("hello world this is a test", 0),
                    ("hello world this is a test testing now", 11),
                ],
                initialDelay: .milliseconds(400),
                stepDelay: .milliseconds(900)
            )
        case "ask-card-long-composer":
            AskCardLongComposerPreview()
        case "extension-dock-stress":
            ExtensionDockStressPreview()
        case "extension-dock-review-combined":
            ExtensionDockReviewCombinedPreview()
        case "extension-dock-scoped-agents":
            ExtensionDockScopedAgentsPreview()
        case "extension-dock-goal-detail":
            ExtensionDockGoalDetailStandalonePreview()
        case "streaming-flicker":
            StreamingFlickerPreviewView()
        case "latex-rendering":
            LatexRenderingPreview()
        case "syntax-languages-a":
            SyntaxLanguagesPreview(page: .webAndDynamic, engine: .treeSitter)
        case "syntax-languages-b":
            SyntaxLanguagesPreview(page: .systemsAndMarkup, engine: .treeSitter)
        case "syntax-languages-a-scanner":
            SyntaxLanguagesPreview(page: .webAndDynamic, engine: .scanner)
        case "syntax-languages-b-scanner":
            SyntaxLanguagesPreview(page: .systemsAndMarkup, engine: .scanner)
        case "mermaid-rendering":
            MermaidRenderingPreview()
        case "geojson-mount-rainier":
            GeoJSONMountRainierPreview()
        case "usdz-rendering":
            USDZRenderingPreview()
        case "mermaid-consistency-inline":
            MermaidConsistencyPreview(expanded: false)
        case "mermaid-consistency-expanded":
            MermaidConsistencyPreview(expanded: true)
        case "mermaid-fullscreen":
            MermaidFullscreenPreview()
        case "mermaid-responsive-routing":
            MermaidResponsiveRoutingPreview()
        case "fullscreen-mermaid":
            FullscreenMermaidChromePreview()
        case "fullscreen-image":
            FullscreenImageChromePreview()
        case "fullscreen-html":
            FullscreenHTMLChromePreview()
        case "fullscreen-svg":
            FullscreenSVGChromePreview()
        case "ask-card":
            AskCardPreview()
        case "ask-card-multiselect-long":
            AskCardMultiSelectLongOptionsPreview()
        case "ask-card-long-unfocused":
            AskCardLongUnfocusedComposerPreview()
        case "ask-card-expanded-sheet":
            AskCardExpandedSheetPreview()
        case "ask-card-expanded-custom":
            AskCardExpandedCustomPreview()
        case "ask-card-intent-regression":
            AskCardIntentRegressionPreview()
        case "oppi-command-approval-inline":
            OppiCommandApprovalInlinePreview()
        case "context-bar-overlap":
            ContextBarOverlapPreview()
        case "feature-tips":
            FeatureEducationTipsPreview()
        case "feature-tip-p0":
            FeatureEducationP0TipPreview()
        case "voice-message-expanded":
            VoiceMessageExpandedPreview()
        case "global-audio-banner":
            GlobalAudioBannerPreview()
        case "share-redaction-report":
            ShareRedactionReportPreview()
        case "share-redaction-settings":
            ShareRedactionSettingsPreview()
        case "split-file-navigation-regression":
            SplitFileNavigationRegressionPreview()
        case "live-activity-working":
            LiveActivityPreviewScreen(
                title: "Live Activity — Working",
                state: .workingPreview,
                isStale: false
            )
        case "live-activity-awaiting":
            LiveActivityPreviewScreen(
                title: "Live Activity — Awaiting Reply",
                state: .awaitingReplyPreview,
                isStale: false
            )
        case "live-activity-stale-awaiting":
            LiveActivityPreviewScreen(
                title: "Live Activity — Stale Awaiting Reply",
                state: .awaitingReplyPreview,
                isStale: true
            )
        case "live-activity-done":
            LiveActivityPreviewScreen(
                title: "Live Activity — Done",
                state: .donePreview,
                isStale: false
            )
        default:
            Text("Unknown screen: \(ScreenshotPreviewConfig.screen)")
        }
    }
}


private extension PiSessionAttributes.ContentState {
    static let workingPreview = Self(
        primaryPhase: .working,
        primarySessionId: "session-working",
        primarySessionName: "Refactor Timeline",
        primaryTool: "Edit",
        primaryLastActivity: "Running Edit",
        totalActiveSessions: 2,
        sessionsAwaitingReply: 0,
        sessionsWorking: 2,
        primaryMutatingToolCalls: 3,
        primaryFilesChanged: 2,
        primaryAddedLines: 48,
        primaryRemovedLines: 12,
        sessionStartDate: Date().addingTimeInterval(-97)
    )

    static let awaitingReplyPreview = Self(
        primaryPhase: .awaitingReply,
        primarySessionId: "session-awaiting",
        primarySessionName: "Deploy Server",
        primaryTool: nil,
        primaryLastActivity: "Waiting for your next instruction",
        totalActiveSessions: 1,
        sessionsAwaitingReply: 1,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        sessionStartDate: nil
    )

    static let donePreview = Self(
        primaryPhase: .ended,
        primarySessionId: "session-done",
        primarySessionName: "Review Release Notes",
        primaryTool: nil,
        primaryLastActivity: "Session ended",
        totalActiveSessions: 0,
        sessionsAwaitingReply: 0,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        sessionStartDate: nil
    )
}

#endif
