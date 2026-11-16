import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Pins")

/// One server's pins (`GET /pins` plus `pins_changed`). Each `ServerConnection`
/// owns one; the Pinned screen, the File Browser's Pinned section, and the
/// pane launcher read it.
///
/// Every change is a `PUT /pins` of the whole order from the revision this
/// store holds. When another device changed the list first, the server
/// answers 409 with its list; the store applies the one change again to
/// that list, by pin id, once. A second conflict gives up and shows the
/// server's list.
@MainActor @Observable
final class PinStore {
    /// Nil until the first read answers.
    private(set) var list: PinsList?
    @ObservationIgnored private var refreshSequence: UInt64 = 0

    var pins: [Pin] { list?.pins ?? [] }

    /// The saved pin for `target`, if any.
    func pin(for target: PinTarget) -> Pin? {
        pins.first { $0.target == target }
    }

    /// Reads the list. An answer older than the list held (a newer change
    /// arrived meanwhile) is dropped.
    func refresh(api: APIClient) async {
        refreshSequence &+= 1
        let sequence = refreshSequence
        do {
            let fetched = try await api.listPins()
            guard sequence == refreshSequence else { return }
            accept(fetched)
        } catch {
            logger.error("Failed to read pins: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A `pins_changed` event: read again unless this store already holds it.
    func noteChanged(revision: Int, api: APIClient?) {
        guard let api, revision != list?.revision else { return }
        Task { await refresh(api: api) }
    }

    /// Pins `target` and answers its pin (the saved one when it was pinned already).
    @discardableResult
    func add(_ target: PinTarget, api: APIClient) async throws -> Pin? {
        let result = try await api.addPin(target)
        accept(PinsList(revision: result.revision, pins: result.pins))
        return result.pins.first { $0.id == result.pinId }
    }

    func remove(_ id: String, api: APIClient) async throws {
        try await save(api: api) { pins in pins.filter { $0.id != id }.map(Self.entry) }
    }

    /// A blank label brings back the target's own name.
    func rename(_ id: String, to label: String, api: APIClient) async throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        try await save(api: api) { pins in
            pins.map { $0.id == id ? PinOrderEntry(id: id, label: trimmed.isEmpty ? nil : trimmed) : Self.entry($0) }
        }
    }

    /// Edit mode's Done for one screen's pins (a workspace root shows only
    /// its own; the Pinned screen groups sessions, folders, and files): each
    /// group's ids in their new order go back into the places that group's
    /// pins held, and `removed` go. Every other pin, and one another device
    /// added meanwhile, keeps its place.
    func setOrder(groups: [[String]], removed: Set<String>, api: APIClient) async throws {
        try await save(api: api) { pins in
            let byId = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var moved = groups.map { ids in ids.compactMap { byId[$0] }.filter { !removed.contains($0.id) }[...] }
            var groupOf: [String: Int] = [:]
            for (index, ids) in groups.enumerated() {
                for id in ids { groupOf[id] = index }
            }
            return pins.compactMap { pin in
                if removed.contains(pin.id) { return nil }
                guard let group = groupOf[pin.id] else { return Self.entry(pin) }
                return Self.entry(moved[group].popFirst() ?? pin)
            }
        }
    }

    /// Sends `change` applied to the list held, and once more to the
    /// server's list if that answer is a revision conflict. A change that
    /// leaves the list as it is sends nothing.
    private func save(api: APIClient, change: ([Pin]) -> [PinOrderEntry]) async throws {
        if list == nil { await refresh(api: api) }
        guard let base = list else { throw APIError.invalidResponse }
        guard change(base.pins) != base.pins.map(Self.entry) else { return }
        do {
            accept(try await api.savePins(baseRevision: base.revision, change(base.pins)))
        } catch let conflict as PinsRevisionConflict {
            accept(conflict.current)
            do {
                accept(try await api.savePins(baseRevision: conflict.current.revision, change(conflict.current.pins)))
            } catch let again as PinsRevisionConflict {
                accept(again.current)
                throw again
            }
        }
    }

    private func accept(_ next: PinsList) {
        if let list, next.revision < list.revision { return }
        if list != next { list = next }
    }

    private static func entry(_ pin: Pin) -> PinOrderEntry {
        PinOrderEntry(id: pin.id, label: pin.label)
    }
}
