import Foundation
import Observation

/// The one place a setting is validated, saved, rolled back, and reloaded.
///
/// A page declares a setting in `SettingsCatalog` and asks a store for it; it
/// never reads `UserDefaults` or calls a server route itself. A store has one
/// context for its whole life and never changes it: a **device store**
/// (`serverId == nil`) holds device-scoped declarations, and a **server store**
/// holds one paired server's. The coordinator owns them (one device store, one
/// store per server, dropped when the server is removed), so two screens on
/// different servers never share state, and a result can only land in the store
/// of the server that produced it. A declaration read or written through the wrong
/// kind of store is a bug (`assertionFailure` in Debug) and reads as unavailable.
///
/// The store owns the state machine (`SettingValue`) and picks the adapter by the
/// declaration's `SettingStorage`:
///
/// - `set`: validate, show the new value as `saving`, write through the adapter,
///   then `value`. A failed write rolls back to `failed(last:)` with the reason,
///   and `retry` runs the same write again. The returned task finishes with the
///   settled `SettingValue` of that call: a caller uses it instead of reading the
///   store again after an `await`.
/// - A server route that revisions its document gets its last known revision as
///   the write's base. A `revision_conflict` reloads the document instead of
///   failing, and the row says once that it changed on another device (a
///   failure line with no Retry); a response with no `revision` is an
///   unrevisioned route and has no conflict path. A document older than the one
///   already held (an answer that arrived out of order) is ignored.
/// - Writes to one route run one at a time, so two settings on the same
///   document never conflict with each other.
/// - `reload(_:)` re-fetches a route's document for a caller about to write who
///   must not trust a document that may have gone stale.
///
/// Read state through `read(_:)` in a view's `updateProperties()`: an
/// `@Observable` store re-runs the page when a setting's state changes. A
/// server setting starts loading on its first read, unless another setting on
/// its route has already loaded the document: then it reads from that one.
///
/// `afterWrite` runs on the main actor once a write has been stored (the
/// setting's id): the one place a setting's side effect lives, so a page never
/// writes and then pokes something else itself.
///
/// Only the device and server adapters exist so far; a declaration with any
/// other storage reads as unavailable until its adapter is added here.
@MainActor @Observable
final class SettingsStore {
    /// The paired server this store holds settings for, or `nil` for the device store.
    let serverId: String?

    private var states: [String: Any] = [:]
    /// Bumped by every device write, so a page that read a device setting
    /// re-runs when it changes (device values are not themselves observable).
    private var deviceWrites = 0

    /// How a server route's document reaches one declaration's state.
    private struct Binding {
        /// A document arrived: the new truth, unless this setting's own write is in flight.
        var apply: (SettingsServerDocument) -> Void
        /// A load failed.
        var failLoad: (Error) -> Void
    }

    @ObservationIgnored private let device: DeviceAdapter
    @ObservationIgnored private let server: ServerAdapter
    @ObservationIgnored private let afterWrite: @MainActor (String) -> Void
    @ObservationIgnored private var documents: [SettingEndpoint: SettingsServerDocument] = [:]
    @ObservationIgnored private var bindings: [SettingEndpoint: [String: Binding]] = [:]
    @ObservationIgnored private var loading: Set<SettingEndpoint> = []
    @ObservationIgnored private var lastSave: [SettingEndpoint: Task<Void, Never>] = [:]
    /// The latest writer queued behind a save of each setting (by id): the next
    /// writer waits for it, so queued writers go out in the order they asked.
    @ObservationIgnored private var queueTails: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retries: [String: () -> Task<Void, Never>] = [:]

    init(
        serverId: String? = nil,
        device: DeviceAdapter = DeviceAdapter(),
        server: ServerAdapter,
        afterWrite: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.serverId = serverId
        self.device = device
        self.server = server
        self.afterWrite = afterWrite
    }

    // MARK: - Routing

    /// Whether this store is the one `declaration` belongs in: device
    /// declarations in the device store, server ones in a server store.
    private func routes<Value>(_ declaration: SettingDeclaration<Value>) -> Bool {
        let matches: Bool
        switch declaration.storage {
        case .device: matches = serverId == nil
        case .server, .deviceOnServer, .piOwned, .workspace: matches = serverId != nil
        }
        assert(matches, "\(declaration.id) is read or written through the wrong settings store (server \(serverId ?? "none"))")
        return matches
    }

    // MARK: - Read

    func read<Value>(_ declaration: SettingDeclaration<Value>) -> SettingValue<Value> {
        guard routes(declaration) else {
            return .unavailable(reason: String(localized: "This setting is not available here."))
        }
        switch declaration.storage {
        case .device:
            _ = deviceWrites
            // A refused value stays shown until the next change.
            if let held = states[declaration.id] as? SettingValue<Value>, held.failureReason != nil { return held }
            do {
                return .value(try device.read(declaration), revision: nil)
            } catch {
                return .unavailable(reason: Self.reason(error))
            }
        case .server(let endpoint, _):
            bind(declaration, to: endpoint)
            if let held = states[declaration.id] as? SettingValue<Value> { return held }
            // The route's document is already here (another setting loaded it).
            if let document = documents[endpoint] {
                return .value(ServerAdapter.value(of: declaration, in: document), revision: document.revision)
            }
            loadIfNeeded(endpoint)
            return .loading
        case .workspace, .deviceOnServer, .piOwned:
            return .unavailable(reason: String(localized: "This setting cannot be changed here yet."))
        }
    }

    /// Whether `retry` has something to run for a setting that failed.
    func canRetry(id: String) -> Bool { retries[id] != nil }

    /// The reason a setting is in `failed`, by id, for a row that does not know
    /// the setting's type (the failure row under a setting).
    func failureReason(id: String) -> String? {
        (states[id] as? any FailureReading)?.failureReason
    }

    /// The setting's state after fetching its route's document again, once any
    /// save in flight has settled. For a caller that must base a write on the
    /// current stored value (a button, not a row that draws `loading`): a document
    /// held since an earlier read may be stale for a reason this store never saw.
    func reload<Value>(_ declaration: SettingDeclaration<Value>) async -> SettingValue<Value> {
        guard routes(declaration), case .server(let endpoint, _) = declaration.storage else { return read(declaration) }
        bind(declaration, to: endpoint)
        await lastSave[endpoint]?.value
        _ = await fetch(endpoint)
        return read(declaration)
    }

    // MARK: - Write

    /// Validates `value`, shows it as `saving`, writes it, and settles to
    /// `value` or `failed`. The returned task finishes with the settled state of
    /// this call (for a change that cannot start, the state it found). A call made
    /// while the setting is already saving queues (see `queueWrite`).
    @discardableResult
    func set<Value>(_ declaration: SettingDeclaration<Value>, _ value: Value) -> Task<SettingValue<Value>, Never> {
        let current = read(declaration)
        // Nothing known to roll back to: still loading, or unavailable.
        guard current.canBeginSaving else {
            if case .saving = current, case .server(let endpoint, _) = declaration.storage {
                return queueWrite(declaration, value, endpoint: endpoint, found: current)
            }
            return Task { current }
        }
        return write(declaration, value, current: current)
    }

    /// A writer that finds the setting already saving. It waits for the writer queued
    /// before it (or, with none, the save in flight), so writers go out in the order
    /// they asked and the last one wins; then it returns its own result. One asking for
    /// the value the setting settled to has nothing to write and shares that result.
    /// It never returns the in-flight state.
    ///
    /// It does not wait on a save forever: when it wakes and the setting is still
    /// saving, it waits for the newer save, and gives up (returning what it found)
    /// once no newer save exists, so a save that never settled cannot loop it.
    private func queueWrite<Value>(
        _ declaration: SettingDeclaration<Value>,
        _ value: Value,
        endpoint: SettingEndpoint,
        found: SettingValue<Value>
    ) -> Task<SettingValue<Value>, Never> {
        guard let predecessor = queueTails[declaration.id] ?? lastSave[endpoint] else { return Task { found } }
        let queued = Task<SettingValue<Value>, Never> { @MainActor [weak self] in
            var waited = predecessor
            while true {
                await waited.value
                guard let self else { return found }
                let now = read(declaration)
                if case .value(let stored, _) = now, stored == value { return now }
                if now.canBeginSaving { return await write(declaration, value, current: now).value }
                guard let newer = lastSave[endpoint], newer != waited else { return now }
                waited = newer
            }
        }
        queueTails[declaration.id] = Task { _ = await queued.value }
        return queued
    }

    /// Starts the write of a setting that can begin saving.
    private func write<Value>(
        _ declaration: SettingDeclaration<Value>,
        _ value: Value,
        current: SettingValue<Value>
    ) -> Task<SettingValue<Value>, Never> {
        retries[declaration.id] = nil
        if let reason = declaration.validate(value) {
            let refused = SettingValue<Value>.failed(last: current.current, reason: reason)
            states[declaration.id] = refused
            return Task { refused }
        }
        switch declaration.storage {
        case .device:
            let settled: SettingValue<Value>
            do {
                try device.write(declaration, value)
                states[declaration.id] = nil
                settled = .value(value, revision: nil)
                afterWrite(declaration.id)
            } catch {
                settled = current.rolledBack(reason: Self.reason(error))
                states[declaration.id] = settled
            }
            deviceWrites += 1
            return Task { settled }
        case .server(let endpoint, let revisioned):
            guard let saving = current.beginSaving(value) else { return Task { current } }
            states[declaration.id] = saving
            return saveToServer(declaration, value, endpoint: endpoint, revisioned: revisioned)
        case .workspace, .deviceOnServer, .piOwned:
            return Task { current }
        }
    }

    /// Runs again what failed: the write that was rolled back, or the load that
    /// never arrived.
    @discardableResult
    func retry(id: String) -> Task<Void, Never> {
        guard let action = retries.removeValue(forKey: id) else { return Task {} }
        return action()
    }

    // MARK: - Server

    private func saveToServer<Value>(
        _ declaration: SettingDeclaration<Value>,
        _ value: Value,
        endpoint: SettingEndpoint,
        revisioned: Bool
    ) -> Task<SettingValue<Value>, Never> {
        let previous = lastSave[endpoint]
        let task = Task<SettingValue<Value>, Never> { @MainActor [weak self] in
            await previous?.value
            guard let self, let serverId else {
                return .unavailable(reason: String(localized: "This setting is not available here."))
            }
            let held = states[declaration.id] as? SettingValue<Value> ?? .loading
            do {
                let document = try await server.save(
                    declaration,
                    value,
                    endpoint: endpoint,
                    revisioned: revisioned,
                    baseRevision: documents[endpoint]?.revision,
                    serverId: serverId
                )
                let settled = (states[declaration.id] as? SettingValue<Value> ?? held).saved(
                    stored: ServerAdapter.value(of: declaration, in: document),
                    revision: document.revision
                )
                states[declaration.id] = settled
                accept(document, for: endpoint)
                afterWrite(declaration.id)
                return settled
            } catch is CancellationError {
                // The save never settled: back to the value it started from, so the
                // setting is not left saving (and no writer waits on it).
                let reverted = (states[declaration.id] as? SettingValue<Value> ?? held).revertedToPrevious()
                states[declaration.id] = reverted
                return reverted
            } catch SettingsError.revisionConflict {
                // Someone else changed the document: show what is stored now, and say so.
                if let saving = states[declaration.id] as? SettingValue<Value> {
                    states[declaration.id] = saving.revertedToPrevious()
                }
                let reloaded = await fetch(endpoint)
                if reloaded, let document = documents[endpoint] {
                    let latest = SettingValue<Value>.failed(
                        last: ServerAdapter.value(of: declaration, in: document),
                        reason: SettingsError.revisionConflict.reason
                    )
                    states[declaration.id] = latest
                    return latest
                }
                return states[declaration.id] as? SettingValue<Value> ?? held
            } catch {
                let failed = Self.settled(states[declaration.id] as? SettingValue<Value> ?? held, after: error)
                states[declaration.id] = failed
                retries[declaration.id] = { [weak self] in
                    guard let self else { return Task {} }
                    let again = set(declaration, value)
                    return Task { _ = await again.value }
                }
                return failed
            }
        }
        lastSave[endpoint] = Task { _ = await task.value }
        return task
    }

    private func loadIfNeeded(_ endpoint: SettingEndpoint) {
        guard !loading.contains(endpoint) else { return }
        loading.insert(endpoint)
        Task { @MainActor [weak self] in
            _ = await self?.fetch(endpoint)
        }
    }

    /// Fetches the route's document and applies it to every setting bound to it.
    /// `true` when a document arrived.
    private func fetch(_ endpoint: SettingEndpoint) async -> Bool {
        guard let serverId else { return false }
        do {
            let document = try await server.load(endpoint, serverId: serverId)
            loading.remove(endpoint)
            accept(document, for: endpoint)
            return true
        } catch is CancellationError {
            loading.remove(endpoint)
            return false
        } catch {
            loading.remove(endpoint)
            for binding in (bindings[endpoint] ?? [:]).values { binding.failLoad(error) }
            return false
        }
    }

    private func accept(_ document: SettingsServerDocument, for endpoint: SettingEndpoint) {
        // An answer that arrived out of order must not replace a newer document.
        if let incoming = document.revision, let held = documents[endpoint]?.revision, incoming < held { return }
        documents[endpoint] = document
        for (id, binding) in bindings[endpoint] ?? [:] {
            retries[id] = nil
            binding.apply(document)
        }
    }

    /// Registers how the route's document becomes `declaration`'s state.
    private func bind<Value>(_ declaration: SettingDeclaration<Value>, to endpoint: SettingEndpoint) {
        guard bindings[endpoint]?[declaration.id] == nil else { return }
        bindings[endpoint, default: [:]][declaration.id] = Binding(
            apply: { [weak self] document in
                guard let self else { return }
                if let held = states[declaration.id] as? SettingValue<Value>, held.isSaving { return }
                states[declaration.id] = SettingValue<Value>.value(
                    ServerAdapter.value(of: declaration, in: document),
                    revision: document.revision
                )
            },
            failLoad: { [weak self] error in
                guard let self else { return }
                let held = states[declaration.id] as? SettingValue<Value> ?? .loading
                states[declaration.id] = Self.settled(held, after: error)
                retries[declaration.id] = { [weak self] in
                    guard let self else { return Task {} }
                    states[declaration.id] = nil
                    loadIfNeeded(endpoint)
                    return Task {}
                }
            }
        )
    }

    /// An error leaves a setting failed with its reason and the last value
    /// known, so the row can say why and offer Retry, an unreachable server
    /// included.
    private static func settled<Value>(_ held: SettingValue<Value>, after error: Error) -> SettingValue<Value> {
        held.rolledBack(reason: reason(error))
    }

    private static func reason(_ error: Error) -> String {
        (error as? SettingsError)?.reason ?? error.localizedDescription
    }
}

/// A `SettingValue` read without its value type.
private protocol FailureReading {
    var failureReason: String? { get }
}

extension SettingValue: FailureReading {}
