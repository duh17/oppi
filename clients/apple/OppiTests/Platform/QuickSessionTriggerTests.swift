import AppIntents
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Oppi

@Suite("QuickSessionTrigger", .serialized)
@MainActor
struct QuickSessionTriggerTests {

    // MARK: - Initial state

    @Test func initialState() {
        let trigger = QuickSessionTrigger.shared
        // Reset to known state for test isolation
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()

        // presentationRequestID starts at some value (may have been bumped by prior tests),
        // but isPresented should be controllable
        #expect(trigger.isPresented == false)
    }

    // MARK: - requestPresentation

    @Test func requestPresentationIncrementsID() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false

        let before = trigger.presentationRequestID
        trigger.requestPresentation()
        #expect(trigger.presentationRequestID == before + 1)

        // Clean up
        trigger.isPresented = false
    }

    @Test func requestPresentationIgnoredWhenAlreadyPresented() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = true

        let before = trigger.presentationRequestID
        trigger.requestPresentation()
        #expect(trigger.presentationRequestID == before) // No change

        // Clean up
        trigger.isPresented = false
    }

    @Test func consecutiveRequestsAllIncrement() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false

        let before = trigger.presentationRequestID
        trigger.requestPresentation()
        trigger.requestPresentation()
        trigger.requestPresentation()
        #expect(trigger.presentationRequestID == before + 3)

        trigger.isPresented = false
    }

    @Test func requestBlockedThenUnblockedAfterDismiss() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false

        let start = trigger.presentationRequestID
        trigger.requestPresentation()
        #expect(trigger.presentationRequestID == start + 1)

        // Simulate sheet presented
        trigger.isPresented = true
        trigger.requestPresentation()
        #expect(trigger.presentationRequestID == start + 1) // Blocked

        // Simulate sheet dismissed
        trigger.isPresented = false
        trigger.requestPresentation()
        #expect(trigger.presentationRequestID == start + 2) // Unblocked

        trigger.isPresented = false
    }

    @Test func requestPresentationStoresInitialPayload() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()

        let payload = QuickSessionInitialPayload(
            text: "Describe this screenshot",
            attachments: [
                QuickSessionInitialPayload.Attachment(
                    name: "screenshot.png",
                    data: Data([0x89, 0x50, 0x4e, 0x47]),
                    mimeType: "image/png"
                )
            ]
        )
        let before = trigger.presentationRequestID

        trigger.requestPresentation(initialPayload: payload)

        #expect(trigger.presentationRequestID == before + 1)
        #expect(trigger.consumePendingPayload() == payload)
        #expect(trigger.consumePendingPayload() == nil)
        trigger.isPresented = false
    }

    @Test func latestRequestWithoutPayloadClearsPendingPayload() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        let payload = QuickSessionInitialPayload(text: "Replace me", attachments: [])
        trigger.requestPresentation(initialPayload: payload)

        trigger.requestPresentation(initialPayload: nil)

        #expect(trigger.consumePendingPayload() == nil)
        trigger.isPresented = false
    }

    @Test func latestRequestReplacesPendingPayload() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        let first = QuickSessionInitialPayload(text: "First", attachments: [])
        let second = QuickSessionInitialPayload(text: "Second", attachments: [])
        trigger.requestPresentation(initialPayload: first)

        trigger.requestPresentation(initialPayload: second)

        #expect(trigger.consumePendingPayload() == second)
        trigger.isPresented = false
    }

    @Test func ignoredPresentationDoesNotQueueInitialPayload() {
        let trigger = QuickSessionTrigger.shared
        _ = trigger.consumePendingPayload()
        trigger.isPresented = true
        let before = trigger.presentationRequestID

        trigger.requestPresentation(
            initialPayload: QuickSessionInitialPayload(text: "Do not keep me", attachments: [])
        )

        #expect(trigger.presentationRequestID == before)
        #expect(trigger.consumePendingPayload() == nil)
        trigger.isPresented = false
    }

}

// MARK: - Quick session control intent

@Suite("QuickSessionOpenIntent")
@MainActor
struct QuickSessionOpenIntentTests {

    @Test func defaultsToQuickSessionTarget() {
        #expect(QuickSessionOpenIntent().target == .quickSession)
    }

    @Test func targetHasDisplayRepresentation() {
        #expect(QuickSessionOpenTarget.caseDisplayRepresentations[.quickSession] != nil)
    }

    @Test func routesIntentToPresentationRequest() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        let before = trigger.presentationRequestID

        trigger.requestPresentation(for: QuickSessionOpenIntent())

        #expect(trigger.presentationRequestID == before + 1)
        trigger.isPresented = false
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    @Test func targetsMainAppOnIOS27() {
        #expect(QuickSessionOpenIntent.allowedExecutionTargets == .main)
    }
#endif
}

// MARK: - ThinkingLevelEnum (Intent type)

@Suite("ThinkingLevelEnum")
@MainActor
struct ThinkingLevelEnumTests {

    @Test func allCasesHaveDisplayRepresentations() {
        let allCases: [ThinkingLevelEnum] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        for level in allCases {
            let repr = ThinkingLevelEnum.caseDisplayRepresentations[level]
            #expect(repr != nil, "Missing display representation for \(level)")
        }
    }

    @Test func caseDisplayRepresentationCount() {
        #expect(ThinkingLevelEnum.caseDisplayRepresentations.count == 7)
    }

    @Test func rawValueRoundTrip() {
        let cases: [(ThinkingLevelEnum, String)] = [
            (.off, "off"),
            (.minimal, "minimal"),
            (.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
            (.xhigh, "xhigh"),
            (.max, "max"),
        ]
        for (expected, raw) in cases {
            let parsed = ThinkingLevelEnum(rawValue: raw)
            #expect(parsed == expected)
        }
    }

    @Test func invalidRawValueReturnsNil() {
        #expect(ThinkingLevelEnum(rawValue: "turbo") == nil)
        #expect(ThinkingLevelEnum(rawValue: "") == nil)
        #expect(ThinkingLevelEnum(rawValue: "HIGH") == nil) // Case sensitive
    }

    @Test func rawValuesMatchThinkingLevel() {
        // ThinkingLevelEnum and ThinkingLevel should use the same raw strings
        // so intent parameters map correctly to the protocol enum.
        let intentCases: [ThinkingLevelEnum] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        for intentCase in intentCases {
            let protocolLevel = ThinkingLevel(rawValue: intentCase.rawValue)
            #expect(protocolLevel != nil,
                    "ThinkingLevelEnum.\(intentCase.rawValue) has no matching ThinkingLevel case")
        }
    }
}

// MARK: - WorkspaceEntity

@Suite("WorkspaceEntity")
@MainActor
struct WorkspaceEntityTests {

    @Test func construction() {
        let entity = WorkspaceEntity(id: "ws-123", name: "My Workspace")
        #expect(entity.id == "ws-123")
        #expect(entity.name == "My Workspace")
    }

    @Test func displayRepresentationShowsName() {
        let entity = WorkspaceEntity(id: "ws-1", name: "Project Alpha")
        let repr = entity.displayRepresentation
        // DisplayRepresentation title is a LocalizedStringResource;
        // verify it was constructed (non-nil)
        #expect(repr.title != nil)
    }

    @Test func emptyName() {
        let entity = WorkspaceEntity(id: "ws-empty", name: "")
        #expect(entity.name == "")
        #expect(entity.id == "ws-empty")
    }

    @Test func unicodeName() {
        let entity = WorkspaceEntity(id: "ws-jp", name: "プロジェクト")
        #expect(entity.name == "プロジェクト")
    }
}

// MARK: - AppPreferences.QuickSession

@Suite("AppPreferences.QuickSession")
@MainActor
struct QuickSessionTests {

    @Test func workspaceIdRoundTrip() {
        AppPreferences.QuickSession.saveWorkspaceId("test-ws-42")
        #expect(AppPreferences.QuickSession.lastWorkspaceId == "test-ws-42")

        // Clean up
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastWorkspaceId"
        )
    }

    @Test func defaultWorkspaceIdRoundTrip() {
        AppPreferences.QuickSession.saveDefaultWorkspaceId("admin-ws")
        #expect(AppPreferences.QuickSession.defaultWorkspaceId == "admin-ws")

        AppPreferences.QuickSession.saveDefaultWorkspaceId(nil)
        #expect(AppPreferences.QuickSession.defaultWorkspaceId == nil)
    }

    @Test func thinkingLevelRoundTrip() {
        AppPreferences.QuickSession.saveThinkingLevel(.high)
        #expect(AppPreferences.QuickSession.lastThinkingLevel == .high)

        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastThinkingLevel"
        )
    }

    @Test func thinkingLevelDefaultsToMedium() {
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastThinkingLevel"
        )
        #expect(AppPreferences.QuickSession.lastThinkingLevel == .medium)
    }

    @Test func preferredWorkspacePrefersLastUsed() {
        AppPreferences.QuickSession.saveWorkspaceId("last-ws")
        AppPreferences.QuickSession.saveDefaultWorkspaceId("explicit-ws")

        let preferred = AppPreferences.QuickSession.preferredWorkspaceId(
            in: [
                (id: "last-ws", name: "oppi"),
                (id: "explicit-ws", name: "something-else"),
                (id: "admin-ws", name: "oppi-admin"),
            ]
        )

        #expect(preferred == "last-ws")
        AppPreferences.QuickSession.saveDefaultWorkspaceId(nil)
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastWorkspaceId"
        )
    }

    @Test func preferredWorkspaceDoesNotSpecialCaseOppiAdmin() {
        AppPreferences.QuickSession.saveDefaultWorkspaceId(nil)
        AppPreferences.QuickSession.saveWorkspaceId("last-ws")

        let preferred = AppPreferences.QuickSession.preferredWorkspaceId(
            in: [
                (id: "last-ws", name: "oppi"),
                (id: "admin-ws", name: "oppi-admin"),
            ]
        )

        #expect(preferred == "last-ws")
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastWorkspaceId"
        )
    }

    @Test func workspaceIdNilWhenNotSet() {
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastWorkspaceId"
        )
        AppPreferences.QuickSession.saveDefaultWorkspaceId(nil)
        #expect(AppPreferences.QuickSession.lastWorkspaceId == nil)
    }

    @Test func pendingDictationCleanupRoundTripAndDedupes() {
        AppPreferences.QuickSession.clearPendingDictationCleanups()
        let cleanup = AppPreferences.QuickSession.PendingDictationCleanup(
            serverId: "server-1",
            workspaceId: "ws-1",
            sessionId: "sess-1"
        )

        AppPreferences.QuickSession.enqueuePendingDictationCleanup(cleanup)
        AppPreferences.QuickSession.enqueuePendingDictationCleanup(cleanup)

        #expect(AppPreferences.QuickSession.pendingDictationCleanups == [cleanup])

        AppPreferences.QuickSession.removePendingDictationCleanup(cleanup)
        #expect(AppPreferences.QuickSession.pendingDictationCleanups.isEmpty)
    }

}

// MARK: - StartQuickSessionIntent (static properties)

@Suite("StartQuickSessionIntent", .serialized)
@MainActor
struct StartQuickSessionIntentTests {

    @Test func opensAppImmediately() {
        #expect(StartQuickSessionIntent.supportedModes == .foreground(.immediate))
    }

    @Test func inputParametersDefaultToNil() {
        let intent = StartQuickSessionIntent()
        #expect(intent.text == nil)
        #expect(intent.image == nil)
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    @Test func targetsMainAppOnIOS27() {
        #expect(StartQuickSessionIntent.allowedExecutionTargets == .main)
    }
#endif

    @Test func performTrimsAndQueuesText() async throws {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()
        let intent = StartQuickSessionIntent()
        intent.text = "  Describe this workspace  \n"

        _ = try await intent.perform()

        #expect(
            trigger.consumePendingPayload()
                == QuickSessionInitialPayload(text: "Describe this workspace", attachments: [])
        )
        trigger.isPresented = false
    }

    @Test func performQueuesImageWithMatchingMetadata() async throws {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()
        let imageData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let intent = StartQuickSessionIntent()
        intent.image = IntentFile(data: imageData, filename: "shortcut-image", type: .png)

        _ = try await intent.perform()

        let payload = try #require(trigger.consumePendingPayload())
        #expect(payload.text == nil)
        #expect(payload.attachments == [
            QuickSessionInitialPayload.Attachment(
                name: "shortcut-image.png",
                data: imageData,
                mimeType: "image/png"
            ),
        ])
        trigger.isPresented = false
    }

    @Test func performRejectsNonImageFile() async throws {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()
        let intent = StartQuickSessionIntent()
        intent.image = IntentFile(
            data: Data([0x00, 0x01, 0x02, 0x03]),
            filename: "document.bin",
            type: .data
        )

        await #expect(throws: QuickSessionIntentPayloadError.unsupportedImage) {
            _ = try await intent.perform()
        }
        #expect(trigger.consumePendingPayload() == nil)
        trigger.isPresented = false
    }

    @Test func performRejectsImageOverComposerUploadLimit() async throws {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()
        let intent = StartQuickSessionIntent()
        intent.image = IntentFile(
            data: Data(repeating: 0x00, count: PendingImage.autoResizeMaxDataBytes + 1),
            filename: "oversized.png",
            type: .png
        )

        await #expect(throws: QuickSessionIntentPayloadError.imageTooLarge) {
            _ = try await intent.perform()
        }
        #expect(trigger.consumePendingPayload() == nil)
        trigger.isPresented = false
    }
}

// MARK: - Quick Session draft intake

@Suite("Quick Session draft intake")
struct QuickSessionDraftIntakeTests {
    @Test func incomingTextAppendsAfterRestoredDraft() {
        #expect(
            quickSessionText("restored draft", appending: "  shortcut text  ")
                == "restored draft\nshortcut text"
        )
    }

    @Test func incomingTextReplacesAnEmptyDraft() {
        #expect(quickSessionText("  \n", appending: "shortcut text") == "shortcut text")
    }

    @Test func emptyIncomingTextPreservesExactDraft() {
        #expect(quickSessionText("  restored draft  ", appending: " \n ") == "  restored draft  ")
    }
}

// MARK: - Quick Session overlay layout

@Suite("QuickSessionOverlayLayout")
struct QuickSessionOverlayLayoutTests {
    @Test func accessibilityTextStacksActionControls() {
        #expect(QuickSessionOverlayLayout.stacksActionControls(for: .accessibility1))
        #expect(QuickSessionOverlayLayout.stacksActionControls(for: .accessibility5))
    }

    @Test func standardTextKeepsCompactActionControls() {
        #expect(!QuickSessionOverlayLayout.stacksActionControls(for: .large))
        #expect(!QuickSessionOverlayLayout.stacksActionControls(for: .xxxLarge))
    }

    @Test func compactHeightBoundsComposerAndEnablesScrolling() {
        let viewport = QuickSessionOverlayLayout.viewport(
            contentHeight: 260,
            availableHeight: 180
        )

        #expect(viewport.height == 168)
        #expect(viewport.requiresScrolling)
    }

    @Test func accessibilityTextContentUsesTheSameBoundedFallback() {
        let viewport = QuickSessionOverlayLayout.viewport(
            contentHeight: 480,
            availableHeight: 320
        )

        #expect(viewport.height == 308)
        #expect(viewport.requiresScrolling)
    }

    @Test func ordinaryContentKeepsItsFittedHeightWithoutScrolling() {
        let viewport = QuickSessionOverlayLayout.viewport(
            contentHeight: 220,
            availableHeight: 700
        )

        #expect(viewport.height == 220)
        #expect(!viewport.requiresScrolling)
    }
}

// MARK: - AskOppiIntent (static properties)

@Suite("AskOppiIntent")
@MainActor
struct AskOppiIntentTests {

    @Test func openAppWhenRunIsFalse() {
        #expect(AskOppiIntent.openAppWhenRun == false)
    }

    @Test func parameterDefaults() {
        let intent = AskOppiIntent()
        // Optional parameters should default to nil
        #expect(intent.workspace == nil)
        #expect(intent.model == nil)
        #expect(intent.thinking == nil)
    }
}

// MARK: - OppiShortcutsProvider

@Suite("OppiShortcutsProvider")
@MainActor
struct OppiShortcutsProviderTests {

    @Test func providesShortcuts() {
        let shortcuts = OppiShortcutsProvider.appShortcuts
        #expect(shortcuts.count == 2)
    }
}
