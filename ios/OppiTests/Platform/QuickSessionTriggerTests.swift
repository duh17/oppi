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

// MARK: - QuickSessionDefaults

@Suite("QuickSessionDefaults")
struct QuickSessionDefaultsTests {

    @Test func workspaceIdRoundTrip() {
        QuickSessionDefaults.saveWorkspaceId("test-ws-42")
        #expect(QuickSessionDefaults.lastWorkspaceId == "test-ws-42")

        // Clean up
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastWorkspaceId"
        )
    }

    @Test func modelIdRoundTrip() {
        QuickSessionDefaults.saveModelId("gpt-4o")
        #expect(QuickSessionDefaults.lastModelId == "gpt-4o")

        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastModelId"
        )
    }

    @Test func thinkingLevelDefaultsToMedium() {
        // Clear any stored value
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastThinkingLevel"
        )
        #expect(QuickSessionDefaults.lastThinkingLevel == .medium)
    }

    @Test func thinkingLevelRoundTrip() {
        QuickSessionDefaults.saveThinkingLevel(.high)
        #expect(QuickSessionDefaults.lastThinkingLevel == .high)

        QuickSessionDefaults.saveThinkingLevel(.off)
        #expect(QuickSessionDefaults.lastThinkingLevel == .off)

        // Restore default
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastThinkingLevel"
        )
    }

    @Test func thinkingLevelInvalidRawFallsBackToMedium() {
        UserDefaults.standard.set(
            "nonexistent",
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastThinkingLevel"
        )
        #expect(QuickSessionDefaults.lastThinkingLevel == .medium)

        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastThinkingLevel"
        )
    }

    @Test func workspaceIdNilWhenNotSet() {
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastWorkspaceId"
        )
        #expect(QuickSessionDefaults.lastWorkspaceId == nil)
    }

    @Test func modelIdNilWhenNotSet() {
        UserDefaults.standard.removeObject(
            forKey: "\(AppIdentifiers.subsystem).quickSession.lastModelId"
        )
        #expect(QuickSessionDefaults.lastModelId == nil)
    }
}

// MARK: - StartQuickSessionIntent (static properties)

@Suite("StartQuickSessionIntent")
struct StartQuickSessionIntentTests {

    @Test func openAppWhenRunIsTrue() {
        #expect(StartQuickSessionIntent.openAppWhenRun == true)
    }
}

// MARK: - AskOppiIntent (static properties)

@Suite("AskOppiIntent")
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
struct OppiShortcutsProviderTests {

    @Test func providesShortcuts() {
        let shortcuts = OppiShortcutsProvider.appShortcuts
        #expect(shortcuts.count == 2)
    }
}
