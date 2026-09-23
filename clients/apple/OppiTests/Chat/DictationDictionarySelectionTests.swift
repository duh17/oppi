import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Dictation dictionary selection")
@MainActor
struct DictationDictionarySelectionTests {
    @Test func workspaceFirstDedupeAndGlobalOnly() {
        let local = DictationDictionarySelection.make(
            workspace: ["Yuwp", "Duh Ifone"], global: ["Duh Ifone", "kypu"]
        )
        #expect(local.selected == ["Yuwp", "Duh Ifone", "kypu"])
        #expect(local.entries[2].exclusion == .duplicate)
        #expect(DictationDictionarySelection.make(workspace: [], global: ["kypu"]).selected == ["kypu"])
    }

    @Test func serverSendConsentIsFreshAndScopedToServerAndProvider() {
        let server = UUID().uuidString
        #expect(!DictationDictionaryConsent.isEnabled(serverId: server, provider: "xai"))
        DictationDictionaryConsent.setEnabled(true, serverId: server, provider: "xai")
        defer { DictationDictionaryConsent.setEnabled(false, serverId: server, provider: "xai") }
        #expect(DictationDictionaryConsent.isEnabled(serverId: server, provider: "xai"))
        #expect(!DictationDictionaryConsent.isEnabled(serverId: server, provider: "http"))
        #expect(!DictationDictionaryConsent.isEnabled(serverId: UUID().uuidString, provider: "xai"))
    }

    @Test func takePayloadKeepsOnDeviceHintsWhenServerConsentIsOff() {
        let phrases = ["Yuwp", "kypu"]
        #expect(VoiceInputManager.contextualStringsForTake(
            selected: phrases, engine: .modernSpeech, sendToServer: false, provider: "xai"
        ) == phrases)
        #expect(VoiceInputManager.contextualStringsForTake(
            selected: phrases, engine: .classicDictation, sendToServer: false, provider: "xai"
        ) == phrases)
    }

    @Test func takePayloadDoesNotSendWithoutConsent() {
        #expect(VoiceInputManager.contextualStringsForTake(
            selected: ["Yuwp"], engine: .serverDictation, sendToServer: false, provider: "xai"
        ).isEmpty)
    }

    @Test func takePayloadFiltersXAIPhrasesByUnicodeScalarsNotCharacters() {
        let boundary = String(repeating: "a", count: 50)
        let overBoundary = boundary + "a"
        let combining = String(repeating: "e\u{301}", count: 26) // 26 Characters, 52 scalars.
        #expect(VoiceInputManager.contextualStringsForTake(
            selected: [boundary, overBoundary, combining, "Yuwp"],
            engine: .serverDictation, sendToServer: true, provider: "xai"
        ) == [boundary, "Yuwp"])
        #expect(VoiceInputManager.contextualStringsForTake(
            selected: [overBoundary], engine: .serverDictation, sendToServer: true, provider: "http"
        ) == [overBoundary])
    }

    @Test func takePayloadFailsClosedAfterDictionaryFetchFailure() {
        // nil represents either the global or workspace fetch failing. Never reuse an earlier take.
        #expect(VoiceInputManager.contextualStringsForTake(
            selected: nil, engine: .modernSpeech, sendToServer: true, provider: "xai"
        ).isEmpty)
        #expect(VoiceInputManager.contextualStringsForTake(
            selected: nil, engine: .serverDictation, sendToServer: true, provider: "xai"
        ).isEmpty)
    }

    @Test func saveRejectsPerScopeCountAndUTF8OverflowWithoutDroppingRows() {
        let tooMany = (0...100).map { "name\($0)" }
        #expect(DictationDictionaryDraft.saveError(global: tooMany, workspace: [])?.contains("100") == true)
        #expect(DictationDictionaryDraft.saveError(
            global: [], workspace: [String(repeating: "é", count: 129)]
        )?.contains("256 UTF-8 bytes") == true)
        #expect(DictationDictionaryDraft.saveError(global: ["ok"], workspace: ["ok"]) == nil)
        #expect(DictationDictionaryDraft.saveError(global: ["bad\nphrase"], workspace: []) != nil)
        #expect(DictationDictionaryDraft.saveError(global: ["\u{FEFF}hidden"], workspace: []) != nil)
    }

    @Test func forgetBlockedByInvalidGlobalDraftKeepsWorkspaceDraftAndSkipsPUT() async {
        var draft = ["local phrase"]
        let binding = Binding(get: { draft }, set: { draft = $0 })
        var putCount = 0
        do {
            _ = try await DictationDictionaryDraft.forgetWorkspace(
                global: (0...100).map { "name\($0)" }, workspaceDraft: binding
            ) {
                putCount += 1
                return DictationDictionaryList(revision: 2, phrases: [], provider: nil)
            }
            Issue.record("Forget must be blocked by the invalid All Workspaces draft")
        } catch let error as DictationDictionaryDraft.ForgetBlocked {
            #expect(error.reason.contains("All Workspaces"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(putCount == 0)
        #expect(draft == ["local phrase"])
    }

    @Test func forgetKeepsDraftOnPUTFailureAndClearsOnlyAfterSuccess() async {
        var draft = ["local phrase"]
        let binding = Binding(get: { draft }, set: { draft = $0 })
        struct Offline: Error {}
        do {
            _ = try await DictationDictionaryDraft.forgetWorkspace(
                global: ["global phrase"], workspaceDraft: binding
            ) { throw Offline() }
            Issue.record("Forget should propagate the PUT failure")
        } catch is Offline {
            #expect(draft == ["local phrase"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let result = try? await DictationDictionaryDraft.forgetWorkspace(
            global: ["global phrase"], workspaceDraft: binding
        ) { DictationDictionaryList(revision: 2, phrases: [], provider: nil) }
        #expect(result?.revision == 2)
        #expect(draft.isEmpty)
    }

    @Test func swipeDeleteInvalidatesEditAndDuplicateRenamePreservesSource() {
        var global = ["first", "second", "third"]
        var workspace = ["existing"]
        var editing: DictationDictionaryDraft.Editing? = .init(
            workspace: false, index: 1, phrase: "second"
        )
        DictationDictionaryDraft.delete(
            offsets: IndexSet(integer: 0), workspaceScope: false,
            global: &global, workspace: &workspace, editing: &editing
        )
        #expect(editing == nil)
        #expect(global == ["second", "third"])
        #expect(!DictationDictionaryDraft.add(
            "existing", workspaceScope: true, global: &global,
            workspace: &workspace, editing: &editing
        ))
        #expect(global == ["second", "third"])
        editing = .init(workspace: false, index: 0, phrase: "second")
        #expect(!DictationDictionaryDraft.add(
            "existing", workspaceScope: true, global: &global,
            workspace: &workspace, editing: &editing
        ))
        #expect(global == ["second", "third"])
        #expect(workspace == ["existing"])
        editing = .init(workspace: false, index: 1, phrase: "second") // stale source identity
        #expect(!DictationDictionaryDraft.add(
            "replacement", workspaceScope: false, global: &global,
            workspace: &workspace, editing: &editing
        ))
        #expect(global == ["second", "third"])
    }

    @Test func consentFooterNamesCloudVendorButNotLocalASRImplementation() {
        let http = DictationDictionaryCopy.consentFooter(serverName: "mac-studio", provider: "http")
        let unknown = DictationDictionaryCopy.consentFooter(serverName: "mac-studio", provider: "other")
        let xai = DictationDictionaryCopy.consentFooter(serverName: "mac-studio", provider: "xai")
        for copy in [http, unknown, xai] {
            #expect(!copy.localizedCaseInsensitiveContains("yuwp"))
            #expect(copy.contains("mac-studio"))
            #expect(copy.contains("speech-to-text service"))
        }
        #expect(http.contains("its configured speech-to-text service"))
        #expect(!http.contains("HTTP"))
        #expect(xai.contains("its configured xAI speech-to-text service"))
    }

    @Test func overflowRemainsVisibleAsExcluded() {
        let phrases = (0..<101).map { "name\($0)" }
        let selected = DictationDictionarySelection.make(workspace: phrases, global: ["global"])
        #expect(selected.selected.count == 100)
        #expect(selected.entries.count == 102)
        #expect(selected.entries[100].exclusion == .phraseCount)
        #expect(selected.entries[101].exclusion == .phraseCount)
        let tooLong = DictationDictionarySelection.make(workspace: [String(repeating: "é", count: 129)], global: ["ok"])
        #expect(tooLong.entries[0].exclusion == .phraseBytes)
        #expect(tooLong.selected == ["ok"])
        let total = DictationDictionarySelection.make(
            workspace: (0..<50).map { "\($0)" + String(repeating: "a", count: 198) },
            global: ["ordinary"]
        )
        #expect(total.entries.contains { $0.exclusion == .totalBytes })
    }
}
