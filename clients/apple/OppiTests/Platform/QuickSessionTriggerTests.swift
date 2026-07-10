import AppIntents
import Foundation
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
        #expect(trigger.consumePendingPayload() == .initial(payload))
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

        #expect(trigger.consumePendingPayload() == .initial(second))
        trigger.isPresented = false
    }

    @Test func latestInitialRequestReplacesPendingSharePayload() throws {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()
        let sharePayload = ShareQuickSessionPayload(
            id: "share-replaced-test",
            text: "Shared first",
            files: [],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try ShareQuickSessionPayload.store(sharePayload)
        defer {
            let defaults = SharedConstants.sharedDefaults
            defaults.removeObject(forKey: ShareQuickSessionPayload.defaultsKey(for: sharePayload.id))
            defaults.removeObject(forKey: ShareQuickSessionPayload.pendingPayloadIdKey)
            defaults.removeObject(forKey: SharedConstants.quickSessionPendingKey)
            _ = trigger.consumePendingPayload()
            trigger.isPresented = false
        }
        trigger.checkForPendingRequest()

        let latestPayload = QuickSessionInitialPayload(text: "Shortcut wins", attachments: [])
        trigger.requestPresentation(initialPayload: latestPayload)

        #expect(trigger.consumePendingPayload() == .initial(latestPayload))
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

    @Test func checkForPendingRequestConsumesStoredSharePayload() throws {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingPayload()

        let payload = ShareQuickSessionPayload(
            id: "share-payload-test",
            text: "Summarize this page",
            files: [
                ShareQuickSessionPayload.SharedFile(
                    name: "notes.pdf",
                    relativePath: "share-payload-test/notes.pdf",
                    mimeType: "application/pdf"
                )
            ],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try ShareQuickSessionPayload.store(payload)
        defer {
            let defaults = SharedConstants.sharedDefaults
            defaults.removeObject(forKey: ShareQuickSessionPayload.defaultsKey(for: payload.id))
            defaults.removeObject(forKey: ShareQuickSessionPayload.pendingPayloadIdKey)
            defaults.removeObject(forKey: SharedConstants.quickSessionPendingKey)
            _ = trigger.consumePendingPayload()
            trigger.isPresented = false
        }

        let before = trigger.presentationRequestID

        trigger.checkForPendingRequest()

        #expect(trigger.presentationRequestID == before + 1)
        #expect(trigger.consumePendingPayload() == .share(payload))
        #expect(SharedConstants.sharedDefaults.bool(forKey: SharedConstants.quickSessionPendingKey) == false)
        #expect(SharedConstants.sharedDefaults.string(forKey: ShareQuickSessionPayload.pendingPayloadIdKey) == nil)
        #expect(ShareQuickSessionPayload.load(id: payload.id) == nil)
    }
}

@Suite("ExtensionContextOpenSupport")
struct ExtensionContextOpenSupportTests {
    @Test func shareExtensionPointCannotOpenContainingAppOnIOS() {
        #expect(
            ExtensionContextOpenSupport.supportsOpeningContainingAppOnIOS(
                extensionPointIdentifier: ExtensionContextOpenSupport.shareServicesExtensionPointIdentifier
            ) == false
        )
    }

    @Test func documentedOpenExtensionPointsCanOpenContainingAppOnIOS() {
        #expect(
            ExtensionContextOpenSupport.supportsOpeningContainingAppOnIOS(
                extensionPointIdentifier: ExtensionContextOpenSupport.todayExtensionPointIdentifier
            )
        )
        #expect(
            ExtensionContextOpenSupport.supportsOpeningContainingAppOnIOS(
                extensionPointIdentifier: ExtensionContextOpenSupport.iMessageExtensionPointIdentifier
            )
        )
    }

    @Test func missingOrUnknownExtensionPointCannotOpenContainingAppOnIOS() {
        #expect(!ExtensionContextOpenSupport.supportsOpeningContainingAppOnIOS(extensionPointIdentifier: nil))
        #expect(!ExtensionContextOpenSupport.supportsOpeningContainingAppOnIOS(extensionPointIdentifier: "com.apple.ui-services"))
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
                == .initial(QuickSessionInitialPayload(text: "Describe this workspace", attachments: []))
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

        let pending = trigger.consumePendingPayload()
        guard case .initial(let payload) = pending else {
            Issue.record("Expected an initial Quick Session payload")
            return
        }
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

    @Test func contentJustOverCompactUsesStableMultilineDetent() {
        #expect(QuickSessionSheetLayout.normalizedContentHeight(151) == 152)
        #expect(
            QuickSessionSheetLayout.detentHeight(forContentHeight: 151)
                == QuickSessionSheetLayout.multilineComposerDetentHeight
        )
        #expect(QuickSessionSheetLayout.multilineComposerDetentHeight > QuickSessionSheetLayout.compactDetentHeight)
        #expect(QuickSessionSheetLayout.multilineComposerDetentHeight < 260)
    }

    @Test func wrappedComposerGrowthDoesNotRetargetSheetEveryRow() {
        let firstWrappedRowDetent = QuickSessionSheetLayout.detentHeight(forContentHeight: 181)
        let secondWrappedRowDetent = QuickSessionSheetLayout.detentHeight(forContentHeight: 205)

        #expect(firstWrappedRowDetent == QuickSessionSheetLayout.multilineComposerDetentHeight)
        #expect(firstWrappedRowDetent == secondWrappedRowDetent)
        #expect(firstWrappedRowDetent < 260)
    }

    @Test func contentHeightChangesWithinStableMultilineDetentAreIgnored() {
        #expect(!QuickSessionSheetLayout.shouldApplyContentHeightChange(
            currentContentHeight: 181,
            incomingContentHeight: 205
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
