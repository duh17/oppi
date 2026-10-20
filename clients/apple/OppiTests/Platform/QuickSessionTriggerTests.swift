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
        _ = trigger.consumePendingStart()

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

    @Test func requestPresentationStoresStart() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingStart()

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
        let start = QuickSessionStart(
            context: QuickSessionLaunchContext(serverId: "server-a", agentId: "voice"),
            mode: .liveVoice,
            payload: payload
        )
        let before = trigger.presentationRequestID

        trigger.requestPresentation(start)

        #expect(trigger.presentationRequestID == before + 1)
        #expect(trigger.consumePendingStart() == start)
        #expect(trigger.consumePendingStart() == nil)
        trigger.isPresented = false
    }

    @Test func latestPlainRequestClearsEarlierStart() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        trigger.requestPresentation(
            QuickSessionStart(
                mode: .liveVoice,
                payload: QuickSessionInitialPayload(text: "Replace me", attachments: [])
            )
        )

        trigger.requestPresentation()

        #expect(trigger.consumePendingStart() == QuickSessionStart())
        trigger.isPresented = false
    }

    @Test func latestRequestReplacesPendingStart() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        let first = QuickSessionStart(payload: QuickSessionInitialPayload(text: "First", attachments: []))
        let second = QuickSessionStart(
            mode: .dictation,
            payload: QuickSessionInitialPayload(text: "Second", attachments: [])
        )
        trigger.requestPresentation(first)

        trigger.requestPresentation(second)

        #expect(trigger.consumePendingStart() == second)
        trigger.isPresented = false
    }

    @Test func ignoredPresentationDoesNotQueueStart() {
        let trigger = QuickSessionTrigger.shared
        _ = trigger.consumePendingStart()
        trigger.isPresented = true
        let before = trigger.presentationRequestID

        trigger.requestPresentation(
            QuickSessionStart(
                mode: .liveVoice,
                payload: QuickSessionInitialPayload(text: "Do not keep me", attachments: [])
            )
        )

        #expect(trigger.presentationRequestID == before)
        #expect(trigger.consumePendingStart() == nil)
        trigger.isPresented = false
    }

}

// MARK: - Quick session control intent

// Nested in the serialized trigger suite: both drive the shared `QuickSessionTrigger`.
extension QuickSessionTriggerTests {
@Suite("QuickSessionOpenIntent")
@MainActor
struct QuickSessionOpenIntentTests {

    @Test func defaultsToMessageMode() {
        #expect(QuickSessionOpenIntent().target == .message)
    }

    /// A control placed before modes existed stored the original single target.
    @Test func originalControlTargetStillDecodesAsMessage() {
        #expect(QuickSessionMode(rawValue: "quickSession") == .message)
    }

    @Test func routesControlModeToPresentationRequest() {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        let before = trigger.presentationRequestID

        trigger.requestPresentation(for: QuickSessionOpenIntent(target: .liveVoice))

        #expect(trigger.presentationRequestID == before + 1)
        #expect(trigger.consumePendingStart() == QuickSessionStart(mode: .liveVoice))
        trigger.isPresented = false
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    @Test func targetsMainAppOnIOS27() {
        #expect(QuickSessionOpenIntent.allowedExecutionTargets == .main)
    }
#endif
}
}

// MARK: - Quick Session presentation

// Nested in the serialized trigger suite: both drive the shared `QuickSessionTrigger`.
extension QuickSessionTriggerTests {
/// The app root's handling of external Quick Session requests (Control widget,
/// App Intents, Shortcuts).
@Suite("QuickSessionPresentation")
@MainActor
struct QuickSessionPresentationTests {
    /// The presentation holds its host weakly, as the app root owns both; the
    /// caller keeps the host.
    private func makePresentation(host: UIViewController) -> (QuickSessionPresentation, AppNavigation) {
        let trigger = QuickSessionTrigger.shared
        trigger.isPresented = false
        _ = trigger.consumePendingStart()
        let root = makeTestAppRoot()
        let presentation = QuickSessionPresentation(root: root, host: host)
        return (presentation, root.navigation)
    }

    /// A request made while Oppi launches (a Control Center press on a cold
    /// start) opens Quick Session with its start once the shell is up, never
    /// over the launch backdrop or onboarding.
    @Test func requestWaitsForTheShellThenOpensWithItsStart() {
        let host = UIViewController()
        let (presentation, navigation) = makePresentation(host: host)
        let start = QuickSessionStart(mode: .liveVoice)
        QuickSessionTrigger.shared.requestPresentation(start)

        presentation.update()
        #expect(!navigation.showQuickSession, "Opened while the launch was resolving")

        navigation.launchPhase = .ready
        presentation.update()
        #expect(!navigation.showQuickSession, "Opened over onboarding")

        navigation.showOnboarding = false
        presentation.update()
        #expect(navigation.showQuickSession)
        #expect(navigation.pendingQuickSessionStart == start)
        #expect(presentation.controller?.parent === host)

        presentation.controller?.model.onDismiss()
        presentation.update()
        #expect(!navigation.showQuickSession)
        #expect(!QuickSessionTrigger.shared.isPresented)
        #expect(presentation.controller == nil)
        #expect(host.children.isEmpty)
        presentation.update()
        #expect(!navigation.showQuickSession, "A handled request opened Quick Session again")
    }

    /// A Quick Session the user already opened wins: a request that arrives
    /// meanwhile (possibly a Live Voice call) is dropped, not saved to open
    /// on its own after the user closes it.
    @Test func requestWhileOpenIsDropped() {
        let host = UIViewController()
        let (presentation, navigation) = makePresentation(host: host)
        navigation.revealPairedServerShell()
        let typed = QuickSessionStart()
        navigation.presentQuickSession(typed, from: .sessionListBar)
        presentation.update()
        #expect(presentation.controller?.parent === host)

        QuickSessionTrigger.shared.requestPresentation(QuickSessionStart(mode: .liveVoice))
        presentation.update()
        #expect(QuickSessionTrigger.shared.consumePendingStart() == nil)
        #expect(navigation.pendingQuickSessionStart == typed)

        presentation.controller?.model.onDismiss()
        presentation.update()
        presentation.update()
        #expect(!navigation.showQuickSession, "The dropped request opened after the user closed Quick Session")
        #expect(presentation.controller == nil)
        #expect(host.children.isEmpty)
    }
}
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
        let entity = WorkspaceEntity(
            serverId: "server-a",
            workspaceId: "ws-123",
            name: "My Workspace",
            serverName: "Studio",
            showsServerSubtitle: false
        )
        #expect(entity.serverId == "server-a")
        #expect(entity.workspaceId == "ws-123")
        #expect(entity.name == "My Workspace")
        #expect(entity.id == ServerScopedEntityID.encode(serverId: "server-a", itemId: "ws-123"))
    }

    @Test func displayRepresentationShowsName() {
        let entity = WorkspaceEntity(
            serverId: "server-a",
            workspaceId: "ws-1",
            name: "Project Alpha",
            serverName: "Studio",
            showsServerSubtitle: false
        )
        let repr = entity.displayRepresentation
        // DisplayRepresentation title is a LocalizedStringResource;
        // verify it was constructed (non-nil)
        #expect(repr.title != nil)
    }

    @Test func emptyName() {
        let entity = WorkspaceEntity(
            serverId: "server-a",
            workspaceId: "ws-empty",
            name: "",
            serverName: "Studio",
            showsServerSubtitle: false
        )
        #expect(entity.name.isEmpty)
        #expect(entity.workspaceId == "ws-empty")
    }

    @Test func unicodeName() {
        let entity = WorkspaceEntity(
            serverId: "server-a",
            workspaceId: "ws-jp",
            name: "プロジェクト",
            serverName: "Studio",
            showsServerSubtitle: false
        )
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

// The test host's app root presents and consumes trigger requests as they arrive, so
// these check the start an intent describes, not what the trigger still holds.
@Suite("StartQuickSessionIntent")
@MainActor
struct StartQuickSessionIntentTests {

    @Test func opensAppImmediately() {
        #expect(StartQuickSessionIntent.supportedModes == .foreground(.immediate))
    }

    @Test func startCarriesModeAgentAndWorkspace() async throws {
        let intent = StartQuickSessionIntent(mode: .liveVoice)
        intent.agent = AgentEntity(
            serverId: "server-a",
            agentId: "voice",
            name: "Voice",
            serverName: "Studio",
            showsServerSubtitle: false
        )
        intent.workspace = WorkspaceEntity(
            serverId: "server-a",
            workspaceId: "ws-1",
            name: "oppi",
            serverName: "Studio",
            showsServerSubtitle: false
        )

        #expect(
            try await intent.start()
                == QuickSessionStart(
                    context: QuickSessionLaunchContext(serverId: "server-a", agentId: "voice", workspaceId: "ws-1"),
                    mode: .liveVoice
                )
        )
    }

    @Test func emptyIntentStartsWithoutTarget() async throws {
        #expect(try await StartQuickSessionIntent().start() == QuickSessionStart())
    }

    @Test func rejectsAgentAndWorkspaceOnDifferentServers() async throws {
        let intent = StartQuickSessionIntent(mode: .liveVoice)
        intent.agent = AgentEntity(
            serverId: "server-a",
            agentId: "voice",
            name: "Voice",
            serverName: "Studio",
            showsServerSubtitle: true
        )
        intent.workspace = WorkspaceEntity(
            serverId: "server-b",
            workspaceId: "ws-1",
            name: "oppi",
            serverName: "Laptop",
            showsServerSubtitle: true
        )

        await #expect(throws: QuickSessionIntentError.agentOnOtherServer) {
            _ = try await intent.start()
        }
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    @Test func targetsMainAppOnIOS27() {
        #expect(StartQuickSessionIntent.allowedExecutionTargets == .main)
    }
#endif

    @Test func startTrimsText() async throws {
        let intent = StartQuickSessionIntent()
        intent.text = "  Describe this workspace  \n"

        #expect(
            try await intent.start()
                == QuickSessionStart(
                    payload: QuickSessionInitialPayload(text: "Describe this workspace", attachments: [])
                )
        )
    }

    @Test func startCarriesImageWithMatchingMetadata() async throws {
        let imageData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let intent = StartQuickSessionIntent()
        intent.image = IntentFile(data: imageData, filename: "shortcut-image", type: .png)

        let payload = try #require(try await intent.start().payload)
        #expect(payload.text == nil)
        #expect(payload.attachments == [
            QuickSessionInitialPayload.Attachment(
                name: "shortcut-image.png",
                data: imageData,
                mimeType: "image/png"
            ),
        ])
    }

    @Test func rejectsNonImageFile() async throws {
        let intent = StartQuickSessionIntent()
        intent.image = IntentFile(
            data: Data([0x00, 0x01, 0x02, 0x03]),
            filename: "document.bin",
            type: .data
        )

        await #expect(throws: QuickSessionIntentError.unsupportedImage) {
            _ = try await intent.start()
        }
    }

    @Test func rejectsImageOverComposerUploadLimit() async throws {
        let intent = StartQuickSessionIntent()
        intent.image = IntentFile(
            data: Data(repeating: 0x00, count: PendingImage.autoResizeMaxDataBytes + 1),
            filename: "oversized.png",
            type: .png
        )

        await #expect(throws: QuickSessionIntentError.imageTooLarge) {
            _ = try await intent.start()
        }
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

// MARK: - Quick Session saved draft

/// Quick Session's saved draft as it comes back into the composer: when
/// Quick Session opens, and when a Live Voice start that set the draft aside
/// stops with an error.
@Suite("Quick Session saved draft")
@MainActor
struct QuickSessionSavedDraftTests {
    @Test func reopeningKeepsTheSavedImageVideoAndFileReference() async throws {
        let fixture = try await SavedDraftFixture.make()
        defer { fixture.remove() }
        let model = QuickSessionModel(root: makeTestAppRoot(composerDraftStore: fixture.store))

        model.loadStoredDraft()

        #expect(model.text == "saved draft")
        #expect(model.pendingAttachments.map(\.id) == ["photo-1", "video-1"])
        #expect(model.pendingRepoPointers.map(\.path) == ["Sources/App.swift"])
        // Reopening is not an edit: the saved draft and its files stay saved.
        fixture.expectSavedDraft(text: "saved draft")
    }

    @Test func failedLiveVoiceStartBringsBackTheSavedDraftWithItsFiles() async throws {
        let fixture = try await SavedDraftFixture.make()
        defer { fixture.remove() }
        let model = QuickSessionModel(root: makeTestAppRoot(composerDraftStore: fixture.store))
        // A Live Voice start sets the saved draft aside and brings its own text.
        model.keepsStoredDraft = true
        model.text = "call text"

        model.error = "Live Voice isn't set up on this server."

        #expect(model.text == "saved draft\ncall text")
        #expect(model.pendingAttachments.map(\.id) == ["photo-1", "video-1"])
        #expect(model.pendingRepoPointers.map(\.path) == ["Sources/App.swift"])
        fixture.expectSavedDraft(text: "saved draft\ncall text")
    }
}

/// A draft store holding a saved Quick Session draft: text, an image kept as
/// bytes, a video kept as a file, and a file reference.
@MainActor
private struct SavedDraftFixture {
    let rootURL: URL
    let store: ComposerDraftStore
    let photoBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00])
    let videoBytes = Data(repeating: 0x5A, count: 2048)

    static func make() async throws -> SavedDraftFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "QuickSessionSavedDraft-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = ComposerDraftStore(
            fileURL: rootURL.appending(path: "drafts.json", directoryHint: .notDirectory),
            saveDelay: .seconds(60)
        )
        await store.load()
        let fixture = SavedDraftFixture(rootURL: rootURL, store: store)
        let clip = rootURL.appending(path: "clip.mp4", directoryHint: .notDirectory)
        try fixture.videoBytes.write(to: clip)
        let importedClip = try store.importAttachmentFile(from: clip)
        _ = try #require(store.setQuickSessionDraft(
            ComposerDraftPayload(
                text: "saved draft",
                repoPointers: [
                    ComposerDraftRepoPointer(
                        path: "Sources/App.swift",
                        isDirectory: false,
                        kind: .workspaceFile,
                        displayPrefix: nil
                    ),
                ],
                attachments: [
                    .init(
                        id: "photo-1",
                        displayName: "photo.png",
                        mimeType: "image/png",
                        source: .image,
                        relativePath: nil,
                        sizeBytes: fixture.photoBytes.count
                    ),
                    .init(
                        id: "video-1",
                        displayName: "clip.mp4",
                        mimeType: "video/mp4",
                        source: .localFile,
                        relativePath: nil,
                        sizeBytes: fixture.videoBytes.count
                    ),
                ]
            ),
            attachmentData: ["photo-1": fixture.photoBytes],
            attachmentFiles: ["video-1": importedClip]
        ))
        return fixture
    }

    /// The store still holds the draft with `text`, both files on disk, and the reference.
    func expectSavedDraft(text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let payload = store.quickSessionDraftPayload
        #expect(payload.text == text, sourceLocation: sourceLocation)
        #expect(payload.repoPointers.map(\.path) == ["Sources/App.swift"], sourceLocation: sourceLocation)
        #expect(payload.attachments.map(\.id) == ["photo-1", "video-1"], sourceLocation: sourceLocation)
        #expect(store.quickSessionDraftAttachmentData()["photo-1"] == photoBytes, sourceLocation: sourceLocation)
        let photoPath = payload.attachments.first { $0.id == "photo-1" }?.relativePath
        #expect(
            photoPath.map { FileManager.default.fileExists(atPath: rootURL.appending(path: $0).path) } == true,
            "The image's sidecar file is gone",
            sourceLocation: sourceLocation
        )
        let videoURL = store.quickSessionDraftAttachmentFileURL(attachmentID: "video-1")
        #expect(videoURL.flatMap { try? Data(contentsOf: $0) } == videoBytes, sourceLocation: sourceLocation)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

// MARK: - AskOppiIntent (static properties)

@Suite("AskOppiIntent")
@MainActor
struct AskOppiIntentTests {

    @Test func requiresLocalDeviceAuthentication() {
        #expect(AskOppiIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
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
        #expect(shortcuts.count == 4)
    }
}
