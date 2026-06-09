import Foundation
import Testing
@testable import Oppi

@Suite("QuickSessionTrigger")
@MainActor
struct QuickSessionTriggerTests {

    // MARK: - Initial state

    @Test func initialState() {
        let trigger = QuickSessionTrigger.shared
        // Reset to known state for test isolation
        trigger.isPresented = false

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

    // MARK: - checkForPendingRequest

    @Test func checkForPendingRequestWhenNoPending() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false

        let before = trigger.presentationRequestID

        // Ensure no pending flag
        SharedConstants.sharedDefaults.removeObject(forKey: SharedConstants.quickSessionPendingKey)

        trigger.checkForPendingRequest()
        #expect(trigger.presentationRequestID == before) // No change
    }

    @Test func checkForPendingRequestWhenPending() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false

        let before = trigger.presentationRequestID

        // Set the pending flag (simulating widget extension writing it)
        SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.quickSessionPendingKey)

        trigger.checkForPendingRequest()
        #expect(trigger.presentationRequestID == before + 1)

        // Flag should be cleared
        let stillPending = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.quickSessionPendingKey)
        #expect(stillPending == false)

        trigger.isPresented = false
    }

    @Test func checkForPendingRequestClearsFlagEvenWhenPresented() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = true

        let before = trigger.presentationRequestID

        SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.quickSessionPendingKey)

        trigger.checkForPendingRequest()

        // requestPresentation is guarded by isPresented, so ID should NOT increment
        #expect(trigger.presentationRequestID == before)

        // But the flag SHOULD still be cleared (checkForPendingRequest calls
        // removeObject before requestPresentation)
        let stillPending = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.quickSessionPendingKey)
        #expect(stillPending == false)

        trigger.isPresented = false
    }

    @Test func checkForPendingRequestCalledTwiceOnlyTriggersOnce() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false

        let before = trigger.presentationRequestID

        SharedConstants.sharedDefaults.set(true, forKey: SharedConstants.quickSessionPendingKey)

        trigger.checkForPendingRequest()
        #expect(trigger.presentationRequestID == before + 1)

        // Second call — flag already cleared
        trigger.checkForPendingRequest()
        #expect(trigger.presentationRequestID == before + 1) // No second bump

        trigger.isPresented = false
    }
}

// MARK: - ThinkingLevelEnum (Intent type)

@Suite("ThinkingLevelEnum")
@MainActor
struct ThinkingLevelEnumTests {

    @Test func allCasesHaveDisplayRepresentations() {
        let allCases: [ThinkingLevelEnum] = [.off, .minimal, .low, .medium, .high, .xhigh]
        for level in allCases {
            let repr = ThinkingLevelEnum.caseDisplayRepresentations[level]
            #expect(repr != nil, "Missing display representation for \(level)")
        }
    }

    @Test func caseDisplayRepresentationCount() {
        #expect(ThinkingLevelEnum.caseDisplayRepresentations.count == 6)
    }

    @Test func rawValueRoundTrip() {
        let cases: [(ThinkingLevelEnum, String)] = [
            (.off, "off"),
            (.minimal, "minimal"),
            (.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
            (.xhigh, "xhigh"),
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
        let intentCases: [ThinkingLevelEnum] = [.off, .minimal, .low, .medium, .high, .xhigh]
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

    @Test func modelIdRoundTrip() {
        AppPreferences.QuickSession.saveModelId("openai-codex/gpt-5.4")
        #expect(AppPreferences.QuickSession.lastModelId == "openai-codex/gpt-5.4")

        AppPreferences.QuickSession.saveModelId(nil)
        #expect(AppPreferences.QuickSession.lastModelId == nil)
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

@Suite("StartQuickSessionIntent")
@MainActor
struct StartQuickSessionIntentTests {

    @Test func openAppWhenRunIsTrue() {
        #expect(StartQuickSessionIntent.openAppWhenRun == true)
    }
}

// MARK: - Quick session sheet layout

@Suite("QuickSessionSheetLayout")
struct QuickSessionSheetLayoutTests {

    @Test func zeroContentKeepsCompactDetent() {
        #expect(
            QuickSessionSheetLayout.detentHeight(forContentHeight: 0)
                == QuickSessionSheetLayout.compactDetentHeight
        )
    }

    @Test func shortComposerKeepsCompactDetent() {
        #expect(
            QuickSessionSheetLayout.detentHeight(forContentHeight: 120)
                == QuickSessionSheetLayout.compactDetentHeight
        )
    }

    @Test func twoLineComposerKeepsCompactDetent() {
        let twoLineContentHeight: CGFloat = 140

        #expect(
            QuickSessionSheetLayout.detentHeight(forContentHeight: twoLineContentHeight)
                == QuickSessionSheetLayout.compactDetentHeight
        )
        #expect(!QuickSessionSheetLayout.shouldApplyContentHeightChange(
            currentContentHeight: 120,
            incomingContentHeight: twoLineContentHeight
        ))
    }

    @Test func contentJustOverCompactUsesMeasuredDetent() {
        #expect(QuickSessionSheetLayout.normalizedContentHeight(151) == 152)
        #expect(QuickSessionSheetLayout.detentHeight(forContentHeight: 151) == 152)
    }

    @Test func wrappedComposerGrowthTracksMeasuredHeight() {
        let firstWrappedRowDetent = QuickSessionSheetLayout.detentHeight(forContentHeight: 181)
        let secondWrappedRowDetent = QuickSessionSheetLayout.detentHeight(forContentHeight: 205)

        #expect(firstWrappedRowDetent == 184)
        #expect(secondWrappedRowDetent == 208)
    }

    @Test func contentHeightChangesWithinSameNormalizedDetentAreIgnored() {
        #expect(!QuickSessionSheetLayout.shouldApplyContentHeightChange(
            currentContentHeight: 181,
            incomingContentHeight: 183
        ))
    }

    @Test func contentHeightChangesAcrossDetentsAreApplied() {
        #expect(QuickSessionSheetLayout.shouldApplyContentHeightChange(
            currentContentHeight: 120,
            incomingContentHeight: 181
        ))
        #expect(QuickSessionSheetLayout.shouldApplyContentHeightChange(
            currentContentHeight: 400,
            incomingContentHeight: 181
        ))
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
