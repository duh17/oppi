import Foundation
import Observation

/// The one place a setting is validated, saved, rolled back, and reloaded.
///
/// A page declares a setting in `SettingsCatalog` and asks the store for it;
/// it never reads `UserDefaults` or calls a server route itself. The store
/// owns the state machine (`SettingValue`) and picks the adapter by the
/// declaration's `SettingStorage`:
///
/// - `set`: validate, show the new value as `saving`, write through the
///   adapter, then `value`. A failed write rolls back to `failed(last:)` with
///   the reason, and `retry` runs the same write again.
/// - A server route that revisions its document gets its last known revision as
///   the write's base. A `revision_conflict` reloads the document instead of
///   failing, and the row says once that it changed on another device (a
///   failure line with no Retry); a response with no `revision` is an
///   unrevisioned route and has no conflict path. A document older than the one
///   already held (an answer that arrived out of order) is ignored.
/// - Writes to one route run one at a time, so two settings on the same
///   document never conflict with each other.
/// - `attach(serverId:)` switches the server context. Everything loaded for the
///   previous one is dropped, and a result still in flight for it is ignored
///   when it lands, as `ServerSettingsModel` does.
///
/// Read state through `read(_:)` in a view's `updateProperties()`: an
/// `@Observable` store re-runs the page when a setting's state changes. A
/// server setting starts loading on its first read, unless another setting on
/// its route has already loaded the document: then it reads from that one.
///
/// Only the device and server adapters exist so far; a declaration with any
/// other storage reads as unavailable until its adapter is added here.
@MainActor @Observable
final class SettingsStore {
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
    @ObservationIgnored private let serverName: @MainActor (String) -> String?
    @ObservationIgnored private var serverId: String?
    /// Changes whenever the context does, including back to the same server, so
    /// a result requested before a switch never lands after it.
    @ObservationIgnored private var context = 0
    @ObservationIgnored private var documents: [SettingEndpoint: SettingsServerDocument] = [:]
    @ObservationIgnored private var bindings: [SettingEndpoint: [String: Binding]] = [:]
    @ObservationIgnored private var loading: Set<SettingEndpoint> = []
    @ObservationIgnored private var lastSave: [SettingEndpoint: Task<Void, Never>] = [:]
    @ObservationIgnored private var retries: [String: () -> Task<Void, Never>] = [:]

    init(
        device: DeviceAdapter = DeviceAdapter(),
        server: ServerAdapter,
        serverName: @escaping @MainActor (String) -> String? = { _ in nil }
    ) {
        self.device = device
        self.server = server
        self.serverName = serverName
    }

    // MARK: - Context

    /// Points the store at a server, or at none. The same server again changes
    /// nothing; another one drops what was loaded and what is in flight.
    func attach(serverId newId: String?) {
        guard newId != serverId else { return }
        serverId = newId
        context += 1
        states = [:]
        documents = [:]
        loading = []
        lastSave = [:]
        retries = [:]
    }

    /// The scope a page says for `declaration`, from its storage and the
    /// attached server's name.
    func scope<Value>(of declaration: SettingDeclaration<Value>) -> SettingsScope {
        declaration.storage.scope(serverName: serverId.flatMap(serverName), workspaceName: nil)
    }

    // MARK: - Read

    func read<Value>(_ declaration: SettingDeclaration<Value>) -> SettingValue<Value> {
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
            guard serverId != nil else { return .unavailable(reason: String(localized: "No server is selected.")) }
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

    // MARK: - Write

    /// Validates `value`, shows it as `saving`, writes it, and settles to
    /// `value` or `failed`. The returned task finishes when the write has settled.
    @discardableResult
    func set<Value>(_ declaration: SettingDeclaration<Value>, _ value: Value) -> Task<Void, Never> {
        let current = read(declaration)
        // Nothing known to roll back to: still loading, saving, or unavailable.
        guard current.canBeginSaving else { return Task {} }
        retries[declaration.id] = nil
        if let reason = declaration.validate(value) {
            states[declaration.id] = SettingValue<Value>.failed(last: current.current, reason: reason)
            return Task {}
        }
        switch declaration.storage {
        case .device:
            do {
                try device.write(declaration, value)
                states[declaration.id] = nil
            } catch {
                states[declaration.id] = current.rolledBack(reason: Self.reason(error))
            }
            deviceWrites += 1
            return Task {}
        case .server(let endpoint, let revisioned):
            guard let serverId, let saving = current.beginSaving(value) else { return Task {} }
            states[declaration.id] = saving
            return saveToServer(declaration, value, endpoint: endpoint, revisioned: revisioned, serverId: serverId)
        case .workspace, .deviceOnServer, .piOwned:
            return Task {}
        }
    }

    /// Runs again what failed: the write that was rolled back, or the load that
    /// never arrived.
    @discardableResult
    func retry<Value>(_ declaration: SettingDeclaration<Value>) -> Task<Void, Never> {
        retry(id: declaration.id)
    }

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
        revisioned: Bool,
        serverId requested: String
    ) -> Task<Void, Never> {
        let requestedContext = context
        let previous = lastSave[endpoint]
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, requestedContext == context else { return }
            do {
                let document = try await server.save(
                    declaration,
                    value,
                    endpoint: endpoint,
                    revisioned: revisioned,
                    baseRevision: documents[endpoint]?.revision,
                    serverId: requested
                )
                guard requestedContext == context else { return }
                if let held = states[declaration.id] as? SettingValue<Value> {
                    states[declaration.id] = held.saved(
                        stored: ServerAdapter.value(of: declaration, in: document),
                        revision: document.revision
                    )
                }
                accept(document, for: endpoint)
            } catch is CancellationError {
                return
            } catch SettingsError.revisionConflict {
                guard requestedContext == context else { return }
                // Someone else changed the document: show what is stored now, and say so.
                if let held = states[declaration.id] as? SettingValue<Value> {
                    states[declaration.id] = held.revertedToPrevious()
                }
                let reloaded = await reload(endpoint, serverId: requested, requestedContext: requestedContext)
                if reloaded, requestedContext == context, let document = documents[endpoint] {
                    states[declaration.id] = SettingValue<Value>.failed(
                        last: ServerAdapter.value(of: declaration, in: document),
                        reason: SettingsError.revisionConflict.reason
                    )
                }
            } catch {
                guard requestedContext == context else { return }
                let held = states[declaration.id] as? SettingValue<Value> ?? .loading
                states[declaration.id] = Self.settled(held, after: error)
                retries[declaration.id] = { [weak self] in self?.set(declaration, value) ?? Task {} }
            }
        }
        lastSave[endpoint] = task
        return task
    }

    private func loadIfNeeded(_ endpoint: SettingEndpoint) {
        guard let serverId, !loading.contains(endpoint) else { return }
        loading.insert(endpoint)
        let requestedContext = context
        Task { @MainActor [weak self] in
            _ = await self?.reload(endpoint, serverId: serverId, requestedContext: requestedContext)
        }
    }

    /// Fetches the route's document and applies it to every setting bound to it.
    /// `true` when a document arrived in the current context.
    private func reload(_ endpoint: SettingEndpoint, serverId requested: String, requestedContext: Int) async -> Bool {
        do {
            let document = try await server.load(endpoint, serverId: requested)
            guard requestedContext == context else { return false }
            loading.remove(endpoint)
            accept(document, for: endpoint)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard requestedContext == context else { return false }
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
