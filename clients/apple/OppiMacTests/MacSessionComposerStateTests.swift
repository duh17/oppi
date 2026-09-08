import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac pane composer state")
struct MacSessionComposerStateTests {
    @Test func actionLayoutUsesStablePaneWidthBoundaries() {
        #expect(MacComposerActionLayout.resolve(paneWidth: 319) == .minimum)
        #expect(MacComposerActionLayout.resolve(paneWidth: 320) == .minimum)
        #expect(MacComposerActionLayout.resolve(paneWidth: 359) == .minimum)
        #expect(MacComposerActionLayout.resolve(paneWidth: 360) == .compact)
        #expect(MacComposerActionLayout.resolve(paneWidth: 519) == .compact)
        #expect(MacComposerActionLayout.resolve(paneWidth: 520) == .wide)

        #expect(MacComposerActionLayout.minimum.minimumContentWidth == 296)
        #expect(MacComposerActionLayout.compact.minimumContentWidth == 336)
        #expect(MacComposerActionLayout.wide.minimumContentWidth == 496)
    }

    @Test func commandReturnBelongsOnlyToActivePane() {
        #expect(MacComposerPaneKeyboardRouting.installsCommandReturn(isActivePane: true))
        #expect(!MacComposerPaneKeyboardRouting.installsCommandReturn(isActivePane: false))
    }

    @Test func fourPaneStatesKeepDraftsAttachmentsAndErrorsIndependent() throws {
        let attachment = try MacPendingAttachment(
            id: "pane-2-attachment",
            url: URL(fileURLWithPath: "/tmp/pane-2-notes.md"),
            displayName: "pane-2-notes.md",
            mimeType: "text/markdown",
            sizeBytes: 42
        )
        let states = (1...4).map { MacSessionComposerState(initialDraft: "Pane \($0)") }

        states[1].pendingAttachments = [attachment]
        states[2].localError = "Pane 3 failed"
        _ = states[3].submissionGate.begin()

        #expect(states.map(\.draft) == ["Pane 1", "Pane 2", "Pane 3", "Pane 4"])
        #expect(states[0].pendingAttachments.isEmpty)
        #expect(states[1].pendingAttachments == [attachment])
        #expect(states[2].localError == "Pane 3 failed")
        #expect(states[0].localError == nil)
        #expect(states[3].submissionGate.isActive)
        #expect(!states[0].submissionGate.isActive)
    }

    @Test func sessionChangeResetsOnlyTheTargetPaneState() throws {
        let attachment = try MacPendingAttachment(
            id: "reset-attachment",
            url: URL(fileURLWithPath: "/tmp/reset-notes.md"),
            displayName: "reset-notes.md",
            mimeType: "text/markdown",
            sizeBytes: 42
        )
        let resetState = MacSessionComposerState(
            initialDraft: "Discard me",
            initialAttachments: [attachment]
        )
        let retainedState = MacSessionComposerState(initialDraft: "Keep me")
        resetState.localError = "Retry"
        _ = resetState.submissionGate.begin()

        resetState.resetForSessionChange()

        #expect(resetState.draft.isEmpty)
        #expect(resetState.pendingAttachments.isEmpty)
        #expect(resetState.localError == nil)
        #expect(!resetState.submissionGate.isActive)
        #expect(retainedState.draft == "Keep me")
    }

    @Test func releasingPaneStateDeletesOwnedPastedFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("composer-state-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("Pasted Image.png")
        try Data([0x01]).write(to: fileURL)
        let attachment = try MacPendingAttachment(
            id: "owned-paste",
            url: fileURL,
            displayName: "Pasted Image.png",
            mimeType: "image/png",
            sizeBytes: 1,
            ownsTemporaryFile: true
        )

        var state: MacSessionComposerState? = MacSessionComposerState(
            initialAttachments: [attachment]
        )
        #expect(state?.pendingAttachments == [attachment])
        state = nil

        #expect(!fileManager.fileExists(atPath: fileURL.path))
        try? fileManager.removeItem(at: directory)
    }
}
