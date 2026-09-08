import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac extension interaction ownership")
struct MacExtensionInteractionTests {
    @Test func queueKeepsDuplicatesInPlaceAndFallsBackForMalformedAsk() {
        let (store, target) = fixture()
        var editor = request("first", target, method: "editor")
        deliver(editor, to: store, target: target)
        deliver(request("second", target, method: "ask"), to: store, target: target)
        editor.title = "Updated title"
        deliver(editor, to: store, target: target)
        #expect(store.pendingExtensionRequests.map(\.id) == ["first", "second"])
        #expect(store.currentExtensionDialog?.title == "Updated title")
        settle("first", store, target)
        #expect(store.currentExtensionDialog?.id == "second")
        #expect(store.currentAskRequest == nil)
    }

    @Test func localDeadlineDoesNotSettleAndRemoteSettlementRevokesLateRequests() {
        let (store, target) = fixture()
        var editor = request("expired", target, method: "editor")
        editor.timeoutAt = .distantPast
        deliver(editor, to: store, target: target)
        #expect(store.currentExtensionDialog == editor)
        store.applyLiveRuntimeMessage(.extensionUISettled(id: editor.id, sessionId: "other"), sessionId: target.sessionId)
        #expect(store.currentExtensionDialog == editor)
        settle(editor.id, store, target)
        deliver(editor, to: store, target: target)
        #expect(store.currentExtensionRequest == nil)
    }

    @Test func responseWriteDoesNotAdvanceQueueAndDuplicateSubmitSendsOnce() async {
        let (store, target) = fixture()
        let editor = request("editor", target, method: "editor")
        deliver(editor, to: store, target: target)
        deliver(request("next", target, method: "confirm"), to: store, target: target)
        var messages: [ClientMessage] = []
        store._sendLiveMessageForTesting = { messages.append($0); return true }
        await store.respondToExtensionRequest(editor, payload: .init(value: ""))
        await store.respondToExtensionRequest(editor, payload: .cancelled)
        #expect(messages.count == 1)
        if case .extensionUIResponse(let id, let value, let confirmed, let cancelled, _) = messages.first {
            #expect(id == editor.id)
            #expect(value == "")
            #expect(confirmed == nil && cancelled == nil)
        } else { Issue.record("Expected editor response") }
        #expect(store.currentExtensionRequest == editor)
        #expect(store.extensionResponseAttempts[editor.id] != nil)
        settle(editor.id, store, target)
        #expect(store.currentAskRequest?.id == "next")
        #expect(store.extensionResponseAttempts.isEmpty)
    }

    @Test func failurePreservesDraftAndAllowsExplicitCancelRetry() async {
        let (store, target) = fixture()
        let editor = request("editor", target, method: "editor")
        deliver(editor, to: store, target: target)
        store.setExtensionEditorText("My edited response", for: editor)
        store._sendLiveMessageForTesting = { _ in throw CancellationError() }
        await store.respondToExtensionRequest(editor, payload: .init(value: "My edited response"))
        #expect(store.extensionResponseAttempts.isEmpty)
        #expect(store.extensionResponseErrors[editor.id] != nil)
        #expect(store.extensionEditorText(for: editor) == "My edited response")
        var cancelled = false
        store._sendLiveMessageForTesting = {
            if case .extensionUIResponse(_, _, _, let value, _) = $0 { cancelled = value == true }
            return true
        }
        await store.respondToExtensionRequest(editor, payload: .cancelled)
        #expect(cancelled)
        #expect(store.extensionResponseErrors.isEmpty)
        #expect(store.currentExtensionRequest == editor)
    }

    @Test func unrelatedStreamErrorDoesNotUnlockAResponseAlreadyWritten() async {
        let (store, target) = fixture()
        let editor = request("editor", target, method: "editor")
        deliver(editor, to: store, target: target)
        var sends = 0
        store._sendLiveMessageForTesting = { _ in sends += 1; return true }
        await store.respondToExtensionRequest(editor, payload: .init(value: "Answer"))
        store.applyLiveRuntimeMessage(.error(message: "An unrelated command failed", code: nil, fatal: false),
                                      sessionId: target.sessionId)
        await store.respondToExtensionRequest(editor, payload: .cancelled)
        #expect(sends == 1)
        #expect(store.extensionResponseAttempts[editor.id] != nil)
        #expect(store.extensionResponseErrors.isEmpty)
    }

    @Test func replacedSnapshotCannotRespondButTheCurrentRequestCan() async {
        let (store, target) = fixture()
        let original = request("editor", target, method: "editor")
        deliver(original, to: store, target: target)
        var replacement = original
        replacement.title = "Review the revised request"
        deliver(replacement, to: store, target: target)
        var sends = 0
        store._sendLiveMessageForTesting = { _ in sends += 1; return true }
        await store.respondToExtensionRequest(original, payload: .init(value: "Old answer"))
        #expect(sends == 0)
        await store.respondToExtensionRequest(replacement, payload: .init(value: "Reviewed answer"))
        #expect(sends == 1)
    }

    @Test func wrongSessionAndQueuedRequestsCannotRespond() async {
        let (store, target) = fixture()
        let first = request("first", target, method: "editor")
        let second = request("second", target, method: "editor")
        deliver(first, to: store, target: target)
        deliver(second, to: store, target: target)
        var sends = 0
        store._sendLiveMessageForTesting = { _ in sends += 1; return true }
        await store.respondToExtensionRequest(second, payload: .cancelled)
        store.select(Self.target("other"))
        await store.respondToExtensionRequest(first, payload: .cancelled)
        #expect(sends == 0)
        #expect(store.pendingExtensionRequests.isEmpty)
    }

    @Test func lateFailureCannotPolluteNewSessionWithSameRequestID() async {
        let (store, target) = fixture()
        let editor = request("same-id", target, method: "editor")
        deliver(editor, to: store, target: target)
        let gate = ExtensionSendGate()
        store._sendLiveMessageForTesting = { _ in
            await gate.hold()
            throw CancellationError()
        }
        let task = Task { await store.respondToExtensionRequest(editor, payload: .cancelled) }
        await gate.waitUntilEntered()
        let other = Self.target("other")
        store.select(other)
        let replacement = request("same-id", other, method: "editor")
        deliver(replacement, to: store, target: other)
        gate.release()
        await task.value
        #expect(store.currentExtensionDialog == replacement)
        #expect(store.extensionResponseErrors.isEmpty)
        #expect(store.extensionResponseAttempts.isEmpty)
    }

    @Test func settlementDuringSendDoesNotReinsertOrAdvanceAgain() async {
        let (store, target) = fixture()
        let editor = request("editor", target, method: "editor")
        deliver(editor, to: store, target: target)
        let next = request("next", target, method: "editor")
        deliver(next, to: store, target: target)
        store._sendLiveMessageForTesting = { _ in
            settle(editor.id, store, target)
            return true
        }
        await store.respondToExtensionRequest(editor, payload: .cancelled)
        #expect(store.currentExtensionDialog == next)
        #expect(store.extensionResponseAttempts.isEmpty)
    }

    @Test func reconnectDropsStaleRequestsAndToastButReplayedEditorKeepsUserDraft() async {
        let (store, target) = fixture()
        let editor = request("editor", target, method: "editor")
        deliver(editor, to: store, target: target)
        deliver(request("stale", target, method: "confirm"), to: store, target: target)
        store.setExtensionEditorText("Keep this", for: editor)
        notify("notify", store, target, message: "Ephemeral")
        store._sendLiveMessageForTesting = { _ in true }
        await store.respondToExtensionRequest(editor, payload: .cancelled)
        store.applyLiveRuntimeMessage(.connected(session: target.summary.session), sessionId: target.sessionId)
        #expect(store.currentExtensionRequest == nil)
        #expect(store.extensionNotice == nil)
        #expect(store.extensionResponseAttempts.isEmpty)
        deliver(editor, to: store, target: target)
        #expect(store.pendingExtensionRequests.map(\.id) == [editor.id])
        #expect(store.extensionEditorText(for: editor) == "Keep this")
    }

    @Test func stopClearsRequestsButPreservesSurfaceAndUserComposerText() {
        let (store, target) = fixture()
        let composer = MacSessionComposerState(initialDraft: "Local")
        store.bindExtensionComposer(composer, sessionId: target.sessionId)
        notify("set_editor_text", store, target, text: "Handoff")
        notify("setWorkingMessage", store, target, message: "Checking")
        deliver(request("editor", target, method: "editor"), to: store, target: target)
        store.applyLiveRuntimeMessage(.stopConfirmed(source: .user, reason: nil), sessionId: target.sessionId)
        #expect(store.currentExtensionRequest == nil)
        #expect(store.extensionSurface.working?.message == "Checking")
        #expect(composer.draft == "Local\n\nHandoff")
        store.applyLiveRuntimeMessage(.sessionEnded(reason: "done"), sessionId: target.sessionId)
        #expect(!store.extensionSurface.hasRetainedContent)
        #expect(composer.draft == "Local\n\nHandoff")
    }

    @Test func handoffsWaitForCorrectComposerThenApplyOnceAcrossRemount() {
        let (store, target) = fixture()
        notify("set_editor_text", store, target, text: "One")
        notify("set_editor_text", store, target, text: "Two")
        let composer = MacSessionComposerState(initialDraft: "Draft")
        store.bindExtensionComposer(composer, sessionId: "other")
        #expect(composer.draft == "Draft")
        store.bindExtensionComposer(composer, sessionId: target.sessionId)
        #expect(composer.draft == "Draft\n\nOne\n\nTwo")
        store.bindExtensionComposer(composer, sessionId: target.sessionId)
        #expect(composer.draft == "Draft\n\nOne\n\nTwo")
        let other = Self.target("other")
        store.select(other)
        notify("set_editor_text", store, other, text: "Other session")
        #expect(composer.draft == "Draft\n\nOne\n\nTwo")
        store.clearSelection()
        store.select(target)
        store.bindExtensionComposer(composer, sessionId: target.sessionId)
        #expect(!composer.draft.contains("Other session"))
    }

    @Test func twoPanesHaveIndependentHandoffsAndSettlementDoesNotClearText() {
        let a = Self.target("a"), b = Self.target("b")
        let paneA = MacSessionPaneRuntime(id: MacSessionPaneID(), target: a, traceStore: MacSessionTraceStore())
        let paneB = MacSessionPaneRuntime(id: MacSessionPaneID(), target: b, traceStore: MacSessionTraceStore())
        paneA.composerState.draft = "A"
        paneB.composerState.draft = "B"
        notify("set_editor_text", paneA.traceStore, a, text: "For A")
        notify("set_editor_text", paneB.traceStore, b, text: "For B")
        settle("unrelated", paneA.traceStore, a)
        #expect(paneA.composerState.draft == "A\n\nFor A")
        #expect(paneB.composerState.draft == "B\n\nFor B")
        paneA.updateTarget(b)
        notify("set_editor_text", paneA.traceStore, a, text: "Late A")
        notify("set_editor_text", paneA.traceStore, b, text: "Now B")
        #expect(paneA.composerState.draft == "Now B")
        #expect(paneB.composerState.draft == "B\n\nFor B")
    }

    @Test func noticeDismissalCannotEraseReplacementAndNeverCreatesResponse() throws {
        let (store, target) = fixture()
        notify("notify", store, target, message: "First")
        let first = try #require(store.extensionNotice)
        notify("notify", store, target, message: "Second")
        store.dismissExtensionNotice(id: first.id)
        #expect(store.extensionNotice?.message == "Second")
        let second = try #require(store.extensionNotice)
        store.dismissExtensionNotice(id: second.id)
        #expect(store.extensionNotice == nil)
        #expect(store.pendingExtensionRequests.isEmpty)
        #expect(!store.extensionSurface.hasRetainedContent)
    }

    @Test func workingPaintConsumesMessageVisibilityFramesAndReset() {
        let (store, target) = fixture()
        notify("setWorkingMessage", store, target, message: "Checking files")
        notify("setWorkingVisible", store, target, visible: false)
        notify("setWorkingIndicator", store, target, indicator: .init(frames: ["A", "B"], intervalMs: 100))
        var paint = MacWorkingRowPresentation(state: store.extensionSurface.working)
        #expect(paint.message == "Checking files")
        #expect(!paint.isVisible)
        #expect(paint.frame(at: Date(timeIntervalSinceReferenceDate: 0.15), reduceMotion: false) == "B")
        #expect(paint.frame(at: Date(timeIntervalSinceReferenceDate: 0.15), reduceMotion: true) == "A")
        notify("setWorkingIndicator", store, target, indicator: .init(frames: [], intervalMs: nil))
        paint = MacWorkingRowPresentation(state: store.extensionSurface.working)
        #expect(paint.frames == [])
        notify("setWorkingIndicator", store, target)
        notify("setWorkingMessage", store, target)
        notify("setWorkingVisible", store, target)
        paint = MacWorkingRowPresentation(state: store.extensionSurface.working)
        #expect(paint.frames == nil)
        #expect(paint.isVisible)
        #expect(paint.message == "Working…")
    }

    @Test func expansionCommandsResetLocalOverridesAndClearAcrossSessions() {
        let (store, target) = fixture()
        notify("setToolsExpanded", store, target, expanded: true)
        #expect(store.isToolRowExpanded("one"))
        store.setToolRowExpanded("one", expanded: false)
        #expect(!store.isToolRowExpanded("one"))
        #expect(store.isToolRowExpanded("two"))
        notify("setToolsExpanded", store, target, expanded: true)
        #expect(store.isToolRowExpanded("one"))
        notify("setToolsExpanded", store, target, expanded: false)
        #expect(!store.isToolRowExpanded("one"))
        store.setToolRowExpanded("one", expanded: true)
        #expect(store.isToolRowExpanded("one"))
        store.select(Self.target("other"))
        #expect(!store.isToolRowExpanded("one"))
    }

    private func fixture() -> (MacSessionTraceStore, MacSelectedSessionTarget) {
        let store = MacSessionTraceStore()
        let target = Self.target("extension-session")
        store.select(target)
        return (store, target)
    }

    static func target(_ id: String) -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(id: id, workspaceId: "workspace", workspaceName: "Workspace", status: .busy,
                              createdAt: now, lastActivity: now, model: "provider/model", messageCount: 1,
                              tokens: TokenUsage(input: 0, output: 0), cost: 0, firstMessage: "Hello")
        return MacSelectedSessionTarget(workspaceId: "workspace", sessionId: id, summary: SessionSummary(from: session))
    }

    private func request(_ id: String, _ target: MacSelectedSessionTarget, method: String) -> ExtensionUIRequest {
        ExtensionUIRequest(id: id, sessionId: target.sessionId, method: method, title: "Review", prefill: "Original")
    }

    private func deliver(_ request: ExtensionUIRequest, to store: MacSessionTraceStore, target: MacSelectedSessionTarget) {
        store.applyLiveRuntimeMessage(.extensionUIRequest(request), sessionId: target.sessionId)
    }

    private func settle(_ id: String, _ store: MacSessionTraceStore, _ target: MacSelectedSessionTarget) {
        store.applyLiveRuntimeMessage(.extensionUISettled(id: id, sessionId: target.sessionId), sessionId: target.sessionId)
    }

    private func notify(_ method: String, _ store: MacSessionTraceStore, _ target: MacSelectedSessionTarget,
                        message: String? = nil, text: String? = nil, visible: Bool? = nil,
                        indicator: ExtensionUIWorkingIndicator? = nil, expanded: Bool? = nil) {
        store.applyLiveRuntimeMessage(.extensionUINotification(ExtensionUINotification(
            method: method, message: message, notifyType: nil, statusKey: nil, statusText: nil,
            title: nil, text: text, widgetKey: nil, widgetLines: nil, widgetPlacement: nil,
            workingIndicator: indicator, workingVisible: visible, toolsExpanded: expanded
        )), sessionId: target.sessionId)
    }
}

@MainActor
private final class ExtensionSendGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
