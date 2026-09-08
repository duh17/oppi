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
    let presentation: MacSessionPanePresentationState
    private(set) var target: MacSelectedSessionTarget?
    var restorationError: String?
    private(set) var restorationAttemptGeneration: UInt = 0

    var isEmpty: Bool { target == nil && restorationError == nil }

    func bumpRestorationAttempt() {
        restorationAttemptGeneration &+= 1
    }

    static let pendingRestorationMessage = "Opening this session…"
    static let unavailableRestorationMessage = "This session is no longer available."
    static let disconnectedRestorationMessage = "Can't reach the local server to open this session."

    init(
        id: MacSessionPaneID,
        target: MacSelectedSessionTarget? = nil,
        traceStore: MacSessionTraceStore,
        composerState: MacSessionComposerState = MacSessionComposerState(),
        quickSession: MacQuickSessionPaneState = MacQuickSessionPaneState(),
        presentation: MacSessionPanePresentationState = MacSessionPanePresentationState()
    ) {
        self.id = id
        self.target = target
        self.traceStore = traceStore
        self.composerState = composerState
        self.quickSession = quickSession
        self.presentation = presentation
        if let target {
            traceStore.select(target)
            traceStore.bindExtensionComposer(composerState, sessionId: target.sessionId)
        }
    }

    func updateTarget(_ target: MacSelectedSessionTarget) {
        let changedSession = self.target?.sessionId != target.sessionId
        bumpRestorationAttempt()
        self.target = target
        restorationError = nil
        if traceStore.selectedTarget == target {
            traceStore.applyLiveRuntimeSession(target.summary.session)
        } else {
            traceStore.select(target)
        }
        if changedSession {
            composerState.resetForSessionChange()
            quickSession.reset()
            presentation.resetForSessionChange()
            restorationError = nil
        }
        traceStore.bindExtensionComposer(composerState, sessionId: target.sessionId)
    }

    func clearSelection() {
        bumpRestorationAttempt()
        target = nil
        restorationError = nil
        traceStore.clearSelection()
        composerState.resetForSessionChange()
        quickSession.reset()
        presentation.resetForSessionChange()
    }
}

/// Pane-owned document / inspector / live-tail intent. Retiling must not
/// reconstruct this from SwiftUI view identity.
@MainActor
@Observable
final class MacSessionPanePresentationState {
    var isInspectorPresented = false
    var selectedFilesSection: MacSessionFilesInspectorSection = .browser
    var isOutlinePresented = false
    var isContextPresented = false
    var composerHeight = MacSessionTimelineOverlap.defaultComposerHeight
    var openPlan: FileViewerPlan?
    var isLiveTailAttached = true
    var timelineViewport = MacSessionTimelineViewport()

    func resetForSessionChange() {
        selectedFilesSection = .browser
        isOutlinePresented = false
        isContextPresented = false
        openPlan = nil
        isLiveTailAttached = true
        timelineViewport = MacSessionTimelineViewport()
    }
}

enum MacSessionPaneUnresolvedRoute: Equatable, Sendable {
    /// Injected resolvers that return nil have already decided the route is gone.
    case unavailable
    /// Production: catalog miss still looks up the session record.
    case lookup
}

/// Cooperative cancel for restored-session lookups. Actor hops can miss
/// `Task.isCancelled` after `await`, so the caller Task's `onCancel` is the source of truth.
private final class RestorationCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum MacSessionPaneRestoredLookup: Equatable {
    case found(MacSelectedSessionTarget)
    case unavailable
    case disconnected

    /// Classifies `getSessionRecord` success, confirmed 404, and any other
    /// transport/server failure. This never resumes a session.
    static func fromSessionRecord(
        _ body: @Sendable () async throws -> Session
    ) async -> Self {
        do {
            let session = try await body()
            guard let target = MacSelectedSessionTarget.from(session: session) else {
                return .unavailable
            }
            return .found(target)
        } catch let MacWorkspaceClientError.server(status, _) where status == 404 {
            return .unavailable
        } catch {
            return .disconnected
        }
    }
}

struct MacSessionPaneRuntimeCensus: Equatable, Sendable {
    var liveRuntimeCount: Int
    var reducerItemCount: Int
    var liveUpdateCount: Int
}

struct MacSessionPaneLayoutPersistence {
    var windowID: String
    var defaults: UserDefaults

    init(windowID: String, defaults: UserDefaults = .standard) {
        self.windowID = windowID
        self.defaults = defaults
    }

    var key: String { "oppi.mac.sessionPaneLayout.\(windowID)" }

    func load() -> MacSessionPaneLayout? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MacSessionPaneLayout.self, from: data)
    }

    func save(_ layout: MacSessionPaneLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: key)
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
    private(set) var lastSplitRejection: MacSessionPaneSplitAdmission.Rejection?
    private(set) var measuredWindowSize: MacSessionPaneMeasuredSize?
    @ObservationIgnored private var runtimesByPaneID: [MacSessionPaneID: MacSessionPaneRuntime] = [:]
    @ObservationIgnored private var measuredPaneSizes: [MacSessionPaneID: MacSessionPaneMeasuredSize] = [:]
    @ObservationIgnored private let storeFactory: StoreFactory
    @ObservationIgnored private let composerStateFactory: ComposerStateFactory
    @ObservationIgnored private let reloadTarget: ReloadTarget
    @ObservationIgnored private let persistence: MacSessionPaneLayoutPersistence?
    @ObservationIgnored private let resolveRestoredRoute: @MainActor (MacSessionPaneRoute) -> MacSelectedSessionTarget?
    @ObservationIgnored private let unresolvedRestoredRoute: MacSessionPaneUnresolvedRoute

    init(
        storeFactory: @escaping StoreFactory = { MacSessionTraceStore() },
        composerStateFactory: @escaping ComposerStateFactory = { MacSessionComposerState() },
        reloadTarget: @escaping ReloadTarget = { store, _ in
            await store.loadSelectedFromLocalConfig()
        },
        persistence: MacSessionPaneLayoutPersistence? = nil,
        resolveRestoredRoute: @escaping @MainActor (MacSessionPaneRoute) -> MacSelectedSessionTarget? = { _ in nil },
        unresolvedRestoredRoute: MacSessionPaneUnresolvedRoute = .unavailable
    ) {
        self.storeFactory = storeFactory
        self.composerStateFactory = composerStateFactory
        self.reloadTarget = reloadTarget
        self.persistence = persistence
        self.resolveRestoredRoute = resolveRestoredRoute
        self.unresolvedRestoredRoute = unresolvedRestoredRoute

        if let restored = persistence?.load() {
            applyRestoredLayout(restored)
        } else {
            let paneID = MacSessionPaneID()
            let runtime = MacSessionPaneRuntime(
                id: paneID,
                traceStore: storeFactory(),
                composerState: composerStateFactory()
            )
            layout = MacSessionPaneLayout(initialRoute: nil, paneID: paneID)
            runtimesByPaneID[paneID] = runtime
        }
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
        canSplitFocused(axis: .horizontal) || canSplitFocused(axis: .vertical)
    }

    var splitRejectionMessage: String? {
        lastSplitRejection?.message
    }

    var runtimeCensus: MacSessionPaneRuntimeCensus {
        MacSessionPaneRuntimeCensus(
            liveRuntimeCount: runtimes.filter(\.traceStore.hasLiveRuntime).count,
            reducerItemCount: runtimes.reduce(0) { $0 + $1.traceStore.reducerItemCount },
            liveUpdateCount: runtimes.reduce(0) { $0 + $1.traceStore.liveUpdateCount }
        )
    }

    func canSplitFocused(axis: MacSessionPaneSplitAxis) -> Bool {
        guard layout != nil else { return false }
        return MacSessionPaneSplitAdmission.evaluate(
            paneSize: focusedPaneSize,
            windowSize: measuredWindowSize,
            axis: axis
        ) == nil
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

    func noteWindowSize(_ size: MacSessionPaneMeasuredSize) {
        if measuredWindowSize != size {
            // Stale leaf measurements can outlive a shrink until SwiftUI
            // remeasures. Drop them so admission uses the current window.
            measuredPaneSizes.removeAll(keepingCapacity: true)
        }
        measuredWindowSize = size
    }

    func notePaneSize(_ size: MacSessionPaneMeasuredSize, for paneID: MacSessionPaneID) {
        measuredPaneSizes[paneID] = size
    }

    @discardableResult
    func setFraction(_ fraction: Double, for splitID: MacSessionPaneSplitID) -> Bool {
        guard var nextLayout = layout else { return false }
        do {
            try nextLayout.setFraction(fraction, for: splitID)
        } catch {
            return false
        }
        commit(nextLayout)
        return true
    }

    /// Restores a window's pane tree without touching the app-scoped snapshot.
    func restore(_ restored: MacSessionPaneLayout) {
        applyRestoredLayout(restored)
        persistCurrentLayout()
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
        commit(nextLayout)
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
        commit(nextLayout)
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
            measuredPaneSizes[paneID] = nil
            commit(MacSessionPaneLayout(initialRoute: nil, paneID: replacementID))
            return true
        }

        do {
            try nextLayout.close(paneID: paneID)
        } catch {
            return false
        }
        runtime.clearSelection()
        runtimesByPaneID.removeValue(forKey: paneID)
        measuredPaneSizes[paneID] = nil
        commit(nextLayout)
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
        commit(nextLayout)
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
        commit(MacSessionPaneLayout(initialRoute: Self.route(for: target), paneID: paneID))
        return runtime
    }

    @discardableResult
    private func splitFocused(
        with target: MacSelectedSessionTarget,
        axis: MacSessionPaneSplitAxis
    ) -> MacSessionPaneRuntime? {
        if let existing = runtime(forSessionID: target.sessionId) {
            existing.updateTarget(target)
            lastSplitRejection = nil
            _ = focus(paneID: existing.id)
            return existing
        }
        guard admitSplit(axis: axis) else { return nil }
        guard var nextLayout = layout else { return nil }
        let paneID = MacSessionPaneID()
        do {
            try nextLayout.split(
                paneID: nextLayout.focusedPaneID,
                axis: axis,
                newRoute: Self.route(for: target),
                newPaneID: paneID,
                paneSize: focusedPaneSize,
                windowSize: measuredWindowSize
            )
        } catch {
            recordSplitFailure(axis: axis)
            return nil
        }

        lastSplitRejection = nil
        let runtime = makeRuntime(paneID: paneID, target: target)
        runtimesByPaneID[paneID] = runtime
        commit(nextLayout)
        return runtime
    }

    @discardableResult
    private func splitFocusedEmpty(axis: MacSessionPaneSplitAxis) -> MacSessionPaneRuntime? {
        guard admitSplit(axis: axis) else { return nil }
        guard var nextLayout = layout else { return nil }
        let paneID = MacSessionPaneID()
        do {
            try nextLayout.split(
                paneID: nextLayout.focusedPaneID,
                axis: axis,
                newRoute: nil,
                newPaneID: paneID,
                paneSize: focusedPaneSize,
                windowSize: measuredWindowSize
            )
        } catch {
            recordSplitFailure(axis: axis)
            return nil
        }

        lastSplitRejection = nil
        let runtime = makeRuntime(paneID: paneID, target: nil)
        runtimesByPaneID[paneID] = runtime
        commit(nextLayout)
        return runtime
    }

    private func admitSplit(axis: MacSessionPaneSplitAxis) -> Bool {
        guard layout != nil else { return false }
        if let rejection = MacSessionPaneSplitAdmission.evaluate(
            paneSize: focusedPaneSize,
            windowSize: measuredWindowSize,
            axis: axis
        ) {
            lastSplitRejection = rejection
            return false
        }
        return true
    }

    private func recordSplitFailure(axis: MacSessionPaneSplitAxis) {
        lastSplitRejection = MacSessionPaneSplitAdmission.evaluate(
            paneSize: focusedPaneSize,
            windowSize: measuredWindowSize,
            axis: axis
        ) ?? .paneTooSmall
    }

    private var focusedPaneSize: MacSessionPaneMeasuredSize? {
        guard let layout else { return measuredWindowSize }
        let paneID = layout.focusedPaneID
        if let measured = measuredPaneSizes[paneID] {
            return measured
        }
        guard let windowSize = measuredWindowSize else { return nil }
        return layout.paintedSize(of: paneID, in: windowSize)
    }

    private func commit(_ nextLayout: MacSessionPaneLayout) {
        if layout?.root != nextLayout.root {
            measuredPaneSizes.removeAll(keepingCapacity: true)
        }
        layout = nextLayout
        persistCurrentLayout()
    }

    private func persistCurrentLayout() {
        guard let layout else { return }
        persistence?.save(layout)
    }

    private func applyRestoredLayout(_ restored: MacSessionPaneLayout) {
        var nextRuntimes: [MacSessionPaneID: MacSessionPaneRuntime] = [:]
        for pane in restored.panes {
            if let existing = runtimesByPaneID[pane.id] {
                apply(pane: pane, to: existing)
                nextRuntimes[pane.id] = existing
                continue
            }
            let runtime = makeRuntime(
                paneID: pane.id,
                target: resolvedTarget(for: pane.route)
            )
            apply(pane: pane, to: runtime)
            nextRuntimes[pane.id] = runtime
        }
        for (paneID, runtime) in runtimesByPaneID where nextRuntimes[paneID] == nil {
            runtime.clearSelection()
        }
        runtimesByPaneID = nextRuntimes
        measuredPaneSizes.removeAll(keepingCapacity: true)
        layout = restored
    }

    private func apply(pane: MacSessionPane, to runtime: MacSessionPaneRuntime) {
        guard let route = pane.route else {
            if runtime.target != nil {
                runtime.clearSelection()
            }
            runtime.restorationError = nil
            return
        }
        if let target = resolvedTarget(for: route) {
            runtime.updateTarget(target)
            runtime.restorationError = nil
        } else {
            runtime.updateTarget(Self.placeholderTarget(for: route))
            runtime.restorationError = unresolvedRestoredRoute == .lookup
                ? MacSessionPaneRuntime.pendingRestorationMessage
                : MacSessionPaneRuntime.unavailableRestorationMessage
        }
    }

    /// Completes restored routes that were pending a session-record lookup.
    /// Stopped sessions stay history-only; this never resumes them.
    /// `onAccepted` runs synchronously with each still-owned apply so the
    /// window can publish before a later pane lookup suspends.
    @discardableResult
    func resolvePendingRestoredSessions(
        lookup: @MainActor (MacSessionPaneRoute) async -> MacSessionPaneRestoredLookup,
        onAccepted: @MainActor (MacSelectedSessionTarget) -> Void = { _ in }
    ) async -> [MacSelectedSessionTarget] {
        await completeRestoredLookups(
            attempts: restorationAttempts(matching: .pending),
            lookup: lookup,
            onAccepted: onAccepted
        )
    }

    /// Visible Retry for disconnected restored routes. Stopped sessions stay
    /// history-only; this never resumes them.
    @discardableResult
    func retryDisconnectedRestoredSessions(
        lookup: @MainActor (MacSessionPaneRoute) async -> MacSessionPaneRestoredLookup,
        onAccepted: @MainActor (MacSelectedSessionTarget) -> Void = { _ in }
    ) async -> [MacSelectedSessionTarget] {
        await retryDisconnectedRestoration(paneIDs: nil, lookup: lookup, onAccepted: onAccepted)
    }

    @discardableResult
    func retryDisconnectedRestoration(
        paneID: MacSessionPaneID,
        lookup: @MainActor (MacSessionPaneRoute) async -> MacSessionPaneRestoredLookup,
        onAccepted: @MainActor (MacSelectedSessionTarget) -> Void = { _ in }
    ) async -> [MacSelectedSessionTarget] {
        await retryDisconnectedRestoration(paneIDs: [paneID], lookup: lookup, onAccepted: onAccepted)
    }

    private func retryDisconnectedRestoration(
        paneIDs: [MacSessionPaneID]?,
        lookup: @MainActor (MacSessionPaneRoute) async -> MacSessionPaneRestoredLookup,
        onAccepted: @MainActor (MacSelectedSessionTarget) -> Void = { _ in }
    ) async -> [MacSelectedSessionTarget] {
        let attempts = restorationAttempts(matching: .disconnected, paneIDs: paneIDs).map {
            attempt -> RestorationAttempt in
            attempt.runtime.bumpRestorationAttempt()
            attempt.runtime.restorationError = MacSessionPaneRuntime.pendingRestorationMessage
            return RestorationAttempt(
                paneID: attempt.paneID,
                route: attempt.route,
                runtime: attempt.runtime,
                generation: attempt.runtime.restorationAttemptGeneration
            )
        }
        return await completeRestoredLookups(attempts: attempts, lookup: lookup, onAccepted: onAccepted)
    }

    private enum RestorationMatch {
        case pending
        case disconnected
    }

    private struct RestorationAttempt {
        let paneID: MacSessionPaneID
        let route: MacSessionPaneRoute
        let runtime: MacSessionPaneRuntime
        let generation: UInt
    }

    private func restorationAttempts(
        matching: RestorationMatch,
        paneIDs: [MacSessionPaneID]? = nil
    ) -> [RestorationAttempt] {
        let message = matching == .pending
            ? MacSessionPaneRuntime.pendingRestorationMessage
            : MacSessionPaneRuntime.disconnectedRestorationMessage
        return (layout?.panes ?? []).compactMap { pane in
            guard let route = pane.route,
                  let runtime = runtimesByPaneID[pane.id],
                  runtime.restorationError == message else {
                return nil
            }
            if let paneIDs, !paneIDs.contains(pane.id) {
                return nil
            }
            return RestorationAttempt(
                paneID: pane.id,
                route: route,
                runtime: runtime,
                generation: runtime.restorationAttemptGeneration
            )
        }
    }

    private func completeRestoredLookups(
        attempts: [RestorationAttempt],
        lookup: @MainActor (MacSessionPaneRoute) async -> MacSessionPaneRestoredLookup,
        onAccepted: @MainActor (MacSelectedSessionTarget) -> Void
    ) async -> [MacSelectedSessionTarget] {
        var accepted: [MacSelectedSessionTarget] = []
        let cancelled = RestorationCancellationFlag()
        await withTaskCancellationHandler {
            for attempt in attempts {
                guard !cancelled.isCancelled, stillOwnsRestoration(attempt) else { continue }
                let result = await lookup(attempt.route)
                guard !cancelled.isCancelled, stillOwnsRestoration(attempt) else { continue }
                if let target = applyRestoration(result, to: attempt) {
                    onAccepted(target)
                    accepted.append(target)
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
        return accepted
    }

    private func stillOwnsRestoration(_ attempt: RestorationAttempt) -> Bool {
        guard let runtime = runtimesByPaneID[attempt.paneID], runtime === attempt.runtime else {
            return false
        }
        guard runtime.restorationAttemptGeneration == attempt.generation else {
            return false
        }
        guard layout?.panes.first(where: { $0.id == attempt.paneID })?.route == attempt.route else {
            return false
        }
        return runtime.restorationError == MacSessionPaneRuntime.pendingRestorationMessage
    }

    @discardableResult
    private func applyRestoration(
        _ result: MacSessionPaneRestoredLookup,
        to attempt: RestorationAttempt
    ) -> MacSelectedSessionTarget? {
        guard stillOwnsRestoration(attempt) else { return nil }
        switch result {
        case .found(let target):
            guard target.sessionId == attempt.route.sessionID else { return nil }
            attempt.runtime.updateTarget(target)
            return target
        case .unavailable:
            attempt.runtime.restorationError = MacSessionPaneRuntime.unavailableRestorationMessage
            return nil
        case .disconnected:
            attempt.runtime.restorationError = MacSessionPaneRuntime.disconnectedRestorationMessage
            return nil
        }
    }

    private func resolvedTarget(for route: MacSessionPaneRoute?) -> MacSelectedSessionTarget? {
        guard let route else { return nil }
        return resolveRestoredRoute(route)
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

    static func placeholderTarget(for route: MacSessionPaneRoute) -> MacSelectedSessionTarget {
        let workspaceID: String?
        let control: ControlSessionMetadata?
        switch route {
        case .workspace(let id, _):
            workspaceID = id
            control = nil
        case .control:
            workspaceID = nil
            control = ControlSessionMetadata(
                domain: .agents,
                intent: .revise,
                targetId: nil,
                targetName: nil
            )
        }
        let session = Session(
            id: route.sessionID,
            workspaceId: workspaceID,
            workspaceName: workspaceID,
            name: nil,
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivity: Date(timeIntervalSince1970: 0),
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            control: control
        )
        return MacSelectedSessionTarget(
            workspaceId: workspaceID ?? "",
            sessionId: route.sessionID,
            summary: SessionSummary(from: session)
        )
    }
}
