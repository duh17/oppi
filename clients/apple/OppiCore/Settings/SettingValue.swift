import Foundation

/// What a setting's row shows right now. One state machine for every setting,
/// whichever storage it lives in; `SettingsStore` is the only writer.
///
/// ```
/// loading ──load──▶ value ◀────────────────┐
///                    │ set                  │ saved / reloaded
///                    ▼                      │
///                  saving ──error──▶ failed(last: previous, reason)
/// ```
enum SettingValue<Value: Equatable & Sendable>: Equatable, Sendable {
    /// Nothing is known yet: a server value that has not arrived.
    case loading
    /// The stored value, and the revision it came with. A store with no
    /// revision (a device value, or a server that does not revision this
    /// setting) has `nil`.
    case value(Value, revision: Int?)
    /// A write is in flight: `shown` is what the person picked, `previous` is
    /// what comes back if the write fails.
    case saving(shown: Value, previous: Value)
    /// A load or a write failed. `last` is the last value known to be stored
    /// (`nil` when a load never succeeded).
    case failed(last: Value?, reason: String)
    /// The setting cannot be read or written here at all: no server is
    /// selected, or its storage is not supported yet. An unreachable server is
    /// `failed`, which can be retried.
    case unavailable(reason: String)

    /// The value a row draws: the stored one, the one being saved, or the last
    /// one known after a failure.
    var current: Value? {
        switch self {
        case .value(let value, _): value
        case .saving(let shown, _): shown
        case .failed(let last, _): last
        case .loading, .unavailable: nil
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    /// The reason to show under the row.
    var failureReason: String? {
        if case .failed(_, let reason) = self { return reason }
        return nil
    }

    /// The reason a row says "Unavailable" for.
    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// Whether a change can start: there is a known value to roll back to.
    var canBeginSaving: Bool {
        switch self {
        case .value: true
        case .failed(let last, _): last != nil
        case .loading, .saving, .unavailable: false
        }
    }

    // MARK: - Transitions

    /// A value arrived from the store: loaded, reloaded after a conflict, or
    /// the stored copy a write returned.
    func loaded(_ value: Value, revision: Int?) -> Self {
        .value(value, revision: revision)
    }

    /// A change was requested. `nil` when there is nothing known to roll back
    /// to (still loading, already saving, unavailable, or a load that failed).
    func beginSaving(_ new: Value) -> Self? {
        guard let previous = current, canBeginSaving else { return nil }
        return .saving(shown: new, previous: previous)
    }

    /// The write was accepted. `stored` is the value the store reports back;
    /// without one, what was shown is what is stored.
    func saved(stored: Value? = nil, revision: Int?) -> Self {
        switch self {
        case .saving(let shown, _): .value(stored ?? shown, revision: revision)
        case .value, .failed, .loading, .unavailable:
            stored.map { .value($0, revision: revision) } ?? self
        }
    }

    /// The write was not applied because the stored value moved on: back to
    /// the previous value, to be replaced by the reloaded one.
    func revertedToPrevious() -> Self {
        if case .saving(_, let previous) = self { return .value(previous, revision: nil) }
        return self
    }

    /// The write failed: back to the previous value, with the reason.
    func rolledBack(reason: String) -> Self {
        switch self {
        case .saving(_, let previous): .failed(last: previous, reason: reason)
        case .value(let value, _): .failed(last: value, reason: reason)
        case .failed(let last, _): .failed(last: last, reason: reason)
        case .loading, .unavailable: .failed(last: nil, reason: reason)
        }
    }

    /// A load failed. A value that was already known stays as `last`.
    func loadFailed(reason: String) -> Self {
        .failed(last: current, reason: reason)
    }
}
