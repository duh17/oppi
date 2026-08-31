import Foundation
import Observation

/// Runtime state tied to one pane identity rather than one SwiftUI view pass.
/// Retiling keeps this object, its live trace, and its unsent composer input.
@MainActor
@Observable
final class MacSessionPaneRuntime: Identifiable {
    let id: MacSessionPaneID
    let traceStore: MacSessionTraceStore
    let composerState: MacSessionComposerState
    let quickSession: MacQuickSessionPaneState
    private(set) var target: MacSelectedSessionTarget?

    var isEmpty: Bool { target == nil }

    init(
        id: MacSessionPaneID,
        target: MacSelectedSessionTarget? = nil,
        traceStore: MacSessionTraceStore,
        composerState: MacSessionComposerState = MacSessionComposerState(),
        quickSession: MacQuickSessionPaneState = MacQuickSessionPaneState()
    ) {
        self.id = id
        self.target = target
        self.traceStore = traceStore
        self.composerState = composerState
        self.quickSession = quickSession
        if let target {
            traceStore.select(target)
        }
    }

    func updateTarget(_ target: MacSelectedSessionTarget) {
        let changedSession = self.target?.sessionId != target.sessionId
        self.target = target
        if traceStore.selectedTarget == target {
            traceStore.applyLiveRuntimeSession(target.summary.session)
        } else {
            traceStore.select(target)
        }
        if changedSession {
            composerState.resetForSessionChange()
            quickSession.reset()
        }
    }

    func clearSelection() {
        target = nil
        traceStore.clearSelection()
        composerState.resetForSessionChange()
        quickSession.reset()
    }
}

/// Window-local owner of the visible pane tree and its pane runtimes.
@MainActor
@Observable
final class MacSessionPaneDeck {
    typealias StoreFactory = @MainActor () -> MacSessionTraceStore
    typealias ComposerStateFactory = @MainActor () -> MacSessionComposerState
    typealias ReloadTarget = @MainActor (MacSessionTraceStore, MacSelectedSessionTarget) async -> Void

    private(set) var layout: MacSessionPaneLayout?
    @ObservationIgnored private var runtimesByPaneID: [MacSessionPaneID: MacSessionPaneRuntime] = [:]
    @ObservationIgnored private let storeFactory: StoreFactory
    @ObservationIgnored private let composerStateFactory: ComposerStateFactory
    @ObservationIgnored private let reloadTarget: ReloadTarget

    init(
        storeFactory: @escaping StoreFactory = { MacSessionTraceStore() },
        composerStateFactory: @escaping ComposerStateFactory = { MacSessionComposerState() },
        reloadTarget: @escaping ReloadTarget = { store, _ in
            await store.loadSelectedFromLocalConfig()
        }
    ) {
        self.storeFactory = storeFactory
        self.composerStateFactory = composerStateFactory
        self.reloadTarget = reloadTarget

        let paneID = MacSessionPaneID()
        let runtime = MacSessionPaneRuntime(
            id: paneID,
            traceStore: storeFactory(),
            composerState: composerStateFactory()
        )
        layout = MacSessionPaneLayout(initialRoute: nil, paneID: paneID)
        runtimesByPaneID[paneID] = runtime
    }

    var root: MacSessionPaneNode? {
        layout?.root
    }

    var focusedSessionID: String? {
        layout?.focusedPane?.route?.sessionID
    }

    var focusedPaneID: MacSessionPaneID? {
        layout?.focusedPaneID
    }

    var visibleSessionIDs: [String] {
        layout?.panes.compactMap(\.route?.sessionID) ?? []
    }

    var paneCount: Int {
        layout?.paneCount ?? 0
    }

    var canSplit: Bool {
        layout != nil && paneCount < MacSessionPaneLayout.maximumPaneCount
    }

    var focusedRuntime: MacSessionPaneRuntime? {
        guard let paneID = layout?.focusedPaneID else { return nil }
        return runtimesByPaneID[paneID]
    }

    var runtimes: [MacSessionPaneRuntime] {
        layout?.panes.compactMap { runtimesByPaneID[$0.id] } ?? []
    }

    func runtime(for paneID: MacSessionPaneID) -> MacSessionPaneRuntime? {
        runtimesByPaneID[paneID]
    }

    func runtime(forSessionID sessionID: String) -> MacSessionPaneRuntime? {
        guard let paneID = paneID(forSessionID: sessionID) else { return nil }
        return runtimesByPaneID[paneID]
    }

    var hasComposerFirstResponder: Bool {
        runtimes.contains { $0.composerState.isComposerFirstResponder }
    }

    /// Destination pane owns AppKit keyboard after split/focus/close commands.
    /// Click-to-focus does not use this path.
    func synchronizeKeyboardOwnership() {
        let destinationID = focusedPaneID
        for runtime in runtimesByPaneID.values {
            if runtime.id == destinationID {
                runtime.composerState.claimKeyboardOwnership()
            } else {
                runtime.composerState.resignKeyboardOwnership()
            }
        }
    }

    /// Opens into the focused pane, unless that session is already visible.
    @discardableResult
    func openOrFocus(_ target: MacSelectedSessionTarget) -> MacSessionPaneRuntime? {
        if let existing = runtime(forSessionID: target.sessionId) {
            existing.updateTarget(target)
            _ = focus(paneID: existing.id)
            return existing
        }

        guard layout != nil else {
            return openFirst(target)
        }
        return replaceFocused(with: target)
    }

    /// Reuses the focused pane runtime so view-local state does not migrate
    /// between pane identities. A session already elsewhere is only focused.
    @discardableResult
    func replaceFocused(with target: MacSelectedSessionTarget) -> MacSessionPaneRuntime? {
        guard let paneID = layout?.focusedPaneID else {
            return openFirst(target)
        }
        return replace(paneID: paneID, with: target)
    }

    /// Completes an async launch into the pane that started it. Returns nil
    /// when that pane is gone instead of replacing whatever is focused now.
    @discardableResult
    func replace(paneID: MacSessionPaneID, with target: MacSelectedSessionTarget) -> MacSessionPaneRuntime? {
        if let existing = runtime(forSessionID: target.sessionId) {
            existing.updateTarget(target)
            _ = focus(paneID: existing.id)
            return existing
        }
        guard var nextLayout = layout,
              let runtime = runtimesByPaneID[paneID] else {
            return nil
        }
        do {
            try nextLayout.setRoute(Self.route(for: target), for: runtime.id)
        } catch {
            return nil
        }

        runtime.updateTarget(target)
        layout = nextLayout
        return runtime
    }

    @discardableResult
    func splitFocusedRight(with target: MacSelectedSessionTarget) -> MacSessionPaneRuntime? {
        splitFocused(with: target, axis: .horizontal)
    }

    @discardableResult
    func splitFocusedBelow(with target: MacSelectedSessionTarget) -> MacSessionPaneRuntime? {
        splitFocused(with: target, axis: .vertical)
    }

    /// `⌘D`: empty Quick Session pane to the right of focus.
    @discardableResult
    func splitFocusedRight() -> MacSessionPaneRuntime? {
        splitFocusedEmpty(axis: .horizontal)
    }

    /// `⌘⇧D`: empty Quick Session pane below focus.
    @discardableResult
    func splitFocusedBelow() -> MacSessionPaneRuntime? {
        splitFocusedEmpty(axis: .vertical)
    }

    @discardableResult
    func focusAdjacent(_ direction: MacSessionPaneFocusDirection) -> Bool {
        guard let paneID = layout?.adjacentPaneID(direction: direction) else {
            return false
        }
        return focus(paneID: paneID)
    }

    @discardableResult
    func focus(paneID: MacSessionPaneID) -> Bool {
        guard var nextLayout = layout else { return false }
        do {
            try nextLayout.focus(paneID)
        } catch {
            return false
        }
        layout = nextLayout
        return true
    }

    @discardableResult
    func closeFocused() -> Bool {
        guard let paneID = layout?.focusedPaneID else { return false }
        return close(paneID: paneID)
    }

    @discardableResult
    func close(paneID: MacSessionPaneID) -> Bool {
        guard var nextLayout = layout,
              let runtime = runtimesByPaneID[paneID] else {
            return false
        }

        if nextLayout.paneCount == 1 {
            runtime.clearSelection()
            runtimesByPaneID.removeValue(forKey: paneID)
            let replacementID = MacSessionPaneID()
            let replacement = makeRuntime(paneID: replacementID, target: nil)
            runtimesByPaneID[replacementID] = replacement
            layout = MacSessionPaneLayout(initialRoute: nil, paneID: replacementID)
            return true
        }

        do {
            try nextLayout.close(paneID: paneID)
        } catch {
            return false
        }
        runtime.clearSelection()
        runtimesByPaneID.removeValue(forKey: paneID)
        layout = nextLayout
        return true
    }

    @discardableResult
    func remove(sessionID: String) -> Bool {
        guard let paneID = paneID(forSessionID: sessionID) else { return false }
        return close(paneID: paneID)
    }

    @discardableResult
    func remove(workspaceID: String) -> Int {
        let paneIDs = layout?.panes.compactMap { pane -> MacSessionPaneID? in
            guard case .workspace(let id, _) = pane.route, id == workspaceID else {
                return nil
            }
            return pane.id
        } ?? []
        var removedCount = 0
        for paneID in paneIDs where close(paneID: paneID) {
            removedCount += 1
        }
        return removedCount
    }

    /// Session Home owns the pane deck's presentation lifecycle. Cancel at
    /// that boundary, not from pane leaves that disappear during split retiling.
    func cancelAllLiveDictation() {
        for runtime in runtimes where runtime.composerState.dictation.isLive {
            let dictation = runtime.composerState.dictation
            Task { @MainActor in
                await dictation.cancel()
            }
        }
    }

    /// The window owns pane visibility. Suspend every focused session stream
    /// here without changing pane identities, routes, or composer drafts.
    func suspendAllSessionRuntimes() {
        for runtime in runtimes {
            runtime.traceStore.suspendRuntime()
        }
    }

    /// Applies the latest list projection without replacing the pane runtime.
    @discardableResult
    func updateOpenTarget(_ target: MacSelectedSessionTarget) -> Bool {
        guard var nextLayout = layout,
              let runtime = runtime(forSessionID: target.sessionId) else {
            return false
        }
        do {
            try nextLayout.setRoute(Self.route(for: target), for: runtime.id)
        } catch {
            return false
        }
        runtime.updateTarget(target)
        layout = nextLayout
        return true
    }

    /// Reload is injected for focused tests; the normal path asks the pane's
    /// existing trace store to reconnect through local owner configuration.
    @discardableResult
    func reloadOpenTarget(_ target: MacSelectedSessionTarget) async -> Bool {
        guard updateOpenTarget(target),
              let runtime = runtime(forSessionID: target.sessionId) else {
            return false
        }
        await reloadTarget(runtime.traceStore, target)
        return true
    }

    @discardableResult
    private func openFirst(_ target: MacSelectedSessionTarget) -> MacSessionPaneRuntime {
        let paneID = MacSessionPaneID()
        let runtime = makeRuntime(paneID: paneID, target: target)
        runtimesByPaneID[paneID] = runtime
        layout = MacSessionPaneLayout(initialRoute: Self.route(for: target), paneID: paneID)
        return runtime
    }

    @discardableResult
    private func splitFocused(
        with target: MacSelectedSessionTarget,
        axis: MacSessionPaneSplitAxis
    ) -> MacSessionPaneRuntime? {
        if let existing = runtime(forSessionID: target.sessionId) {
            existing.updateTarget(target)
            _ = focus(paneID: existing.id)
            return existing
        }
        guard var nextLayout = layout, canSplit else { return nil }
        let paneID = MacSessionPaneID()
        do {
            try nextLayout.split(
                paneID: nextLayout.focusedPaneID,
                axis: axis,
                newRoute: Self.route(for: target),
                newPaneID: paneID
            )
        } catch {
            return nil
        }

        let runtime = makeRuntime(paneID: paneID, target: target)
        runtimesByPaneID[paneID] = runtime
        layout = nextLayout
        return runtime
    }

    @discardableResult
    private func splitFocusedEmpty(axis: MacSessionPaneSplitAxis) -> MacSessionPaneRuntime? {
        guard var nextLayout = layout, canSplit else { return nil }
        let paneID = MacSessionPaneID()
        do {
            try nextLayout.split(
                paneID: nextLayout.focusedPaneID,
                axis: axis,
                newRoute: nil,
                newPaneID: paneID
            )
        } catch {
            return nil
        }

        let runtime = makeRuntime(paneID: paneID, target: nil)
        runtimesByPaneID[paneID] = runtime
        layout = nextLayout
        return runtime
    }

    private func makeRuntime(
        paneID: MacSessionPaneID,
        target: MacSelectedSessionTarget?
    ) -> MacSessionPaneRuntime {
        MacSessionPaneRuntime(
            id: paneID,
            target: target,
            traceStore: storeFactory(),
            composerState: composerStateFactory()
        )
    }

    private func paneID(forSessionID sessionID: String) -> MacSessionPaneID? {
        layout?.panes.first(where: { $0.route?.sessionID == sessionID })?.id
    }

    private static func route(for target: MacSelectedSessionTarget) -> MacSessionPaneRoute {
        switch target.routeScope {
        case .workspace(let workspaceID):
            .workspace(workspaceID: workspaceID, sessionID: target.sessionId)
        case .control:
            .control(sessionID: target.sessionId)
        }
    }
}
