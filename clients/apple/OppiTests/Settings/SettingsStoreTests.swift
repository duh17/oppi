import Foundation
import Testing
@testable import Oppi

@Suite("SettingsStore", .serialized)
@MainActor
struct SettingsStoreTests {
    private let enabled = SettingsCatalog.serverMetricsEnabled
    private let label = testLabelSetting
    private let haptics = SettingsCatalog.hapticFeedback

    private func makeStore(
        _ transports: [String: FakeSettingsTransport],
        defaults: UserDefaults = makeSettingsDefaults(),
        afterWrite: @escaping @MainActor (String) -> Void = { _ in }
    ) -> SettingsStore {
        SettingsStore(
            device: DeviceAdapter(defaults: defaults),
            server: ServerAdapter { transports[$0] },
            afterWrite: afterWrite
        )
    }

    /// Lets the store's own tasks run until `condition` holds.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - Device

    @Test("A device setting reads and writes through the adapter and never touches a server")
    func deviceSettingNeverTouchesTheServer() async {
        let transport = FakeSettingsTransport()
        let defaults = makeSettingsDefaults()
        let store = makeStore(["s1": transport], defaults: defaults)
        store.attach(serverId: "s1")

        #expect(store.read(haptics) == .value(true, revision: nil))
        await store.set(haptics, false).value
        #expect(store.read(haptics) == .value(false, revision: nil))
        #expect(defaults.object(forKey: AppPreferenceStore.Interaction.hapticFeedbackEnabledKey) as? Bool == false)

        #expect(transport.saves.isEmpty)
        #expect(transport.loads == 0)
    }

    @Test("A stored write runs the hook with the setting's id, and a refused one does not")
    func afterWriteRunsForStoredWrites() async {
        var written: [String] = []
        let store = makeStore(["s1": FakeSettingsTransport()], afterWrite: { written.append($0) })
        store.attach(serverId: "s1")

        await store.set(SettingsCatalog.keepAwakeAfterActivity, .fiveMinutes).value
        #expect(written == [SettingsCatalog.keepAwakeAfterActivity.id])
        #expect(store.read(SettingsCatalog.keepAwakeAfterActivity) == .value(.fiveMinutes, revision: nil))

        _ = store.read(label)
        await until { store.read(label).current != nil }
        await store.set(label, "").value
        #expect(written == [SettingsCatalog.keepAwakeAfterActivity.id])

        await store.set(label, "second").value
        #expect(written == [SettingsCatalog.keepAwakeAfterActivity.id, label.id])
    }

    @Test("A refused value is not written, and the row says why")
    func validationRefusesBeforeAnyWrite() async {
        let transport = FakeSettingsTransport()
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(label)
        await until { store.read(label).current != nil }

        await store.set(label, "").value

        #expect(store.read(label) == .failed(last: "first", reason: "Give it a label."))
        #expect(store.failureReason(id: label.id) == "Give it a label.")
        #expect(!store.canRetry(id: label.id))
        #expect(transport.saves.isEmpty)
    }

    // MARK: - Server

    @Test("A server setting loads on its first read, and every setting on the route shares the load")
    func serverLoadsOnFirstRead() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true, "label": "shared"], revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")

        #expect(store.read(enabled) == .loading)
        #expect(store.read(label) == .loading)
        await until { store.read(enabled).current != nil }

        #expect(store.read(enabled) == .value(true, revision: 4))
        #expect(store.read(label) == .value("shared", revision: 4))
        #expect(transport.loads == 1)
    }

    @Test("reload fetches the document again, so a write after it is not based on a stale one")
    func reloadRefreshesTheDocumentBeforeAWrite() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).current != nil }

        // The document moved on without this store: another writer, or a path that bypassed it.
        transport.changeElsewhere(["enabled": true])
        #expect(store.read(enabled) == .value(false, revision: 4))

        let fresh = await store.reload(enabled)
        #expect(fresh == .value(true, revision: 5))
        #expect(transport.loads == 2)

        await store.set(enabled, false).value
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": false], baseRevision: 5)])
        #expect(store.read(enabled) == .value(false, revision: 6))
    }

    @Test("reload of a setting that was never read loads it")
    func reloadLoadsAnUnreadSetting() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true], revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        #expect(await store.reload(enabled) == .value(true, revision: 4))
        #expect(transport.loads == 1)
    }

    @Test("reload waits for a save in flight, and keeps a failed fetch's last value")
    func reloadWaitsForSavesAndSurvivesFailure() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).current != nil }

        let gate = SettingsGate()
        transport.holdSaves(gate)
        let write = store.set(enabled, true)
        await until { !transport.saves.isEmpty }
        async let reloaded = store.reload(enabled)
        // The fetch has not run while the save is held.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(transport.loads == 1)
        await gate.open()
        await write.value
        #expect(await reloaded == .value(true, revision: 5))

        transport.failNextLoad(with: SettingsTestError())
        #expect(await store.reload(enabled) == .failed(last: true, reason: "The server said no."))
    }

    @Test("A write shows the new value as saving, then the stored one with its revision")
    func serverWriteSettlesToTheStoredValue() async {
        let transport = FakeSettingsTransport(revision: 4)
        let gate = SettingsGate()
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = (store.read(enabled), store.read(label))
        await until { store.read(enabled).current != nil }

        transport.holdSaves(gate)
        let write = store.set(enabled, true)
        #expect(store.read(enabled) == .saving(shown: true, previous: false))
        // The row cannot be changed again while it saves.
        store.set(enabled, false)
        await gate.open()
        await write.value

        #expect(store.read(enabled) == .value(true, revision: 5))
        // The other setting on the route took the new revision, so its next write is not stale.
        #expect(store.read(label) == .value("first", revision: 5))
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 4)])
    }

    @Test("A failed write rolls back to the previous value with the reason, and Retry writes it again")
    func serverFailureRollsBackAndRetries() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).current != nil }

        transport.failNextSave(with: SettingsTestError())
        await store.set(enabled, true).value
        #expect(store.read(enabled) == .failed(last: false, reason: "The server said no."))
        #expect(store.canRetry(id: enabled.id))

        await store.retry(id: enabled.id).value
        #expect(store.read(enabled) == .value(true, revision: 5))
        #expect(transport.saves.count == 2)
        #expect(!store.canRetry(id: enabled.id))
    }

    @Test("A revision conflict reloads the server's value, says it changed elsewhere, and leaves the row editable")
    func conflictReloads() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(label)
        await until { store.read(label).current != nil }

        // Another device changed the label after this one loaded.
        transport.changeElsewhere(["label": "elsewhere"])
        await store.set(label, "mine").value

        #expect(store.read(label) == .failed(last: "elsewhere", reason: "Changed on another device; showing the latest."))
        // A message, not a failure to retry: nothing to run again, and the row can be changed.
        #expect(!store.canRetry(id: label.id))
        #expect(transport.saves.count == 1)
        #expect(transport.loads == 2)

        await store.set(label, "mine").value
        #expect(store.read(label) == .value("mine", revision: 6))
        #expect(transport.saves.map(\.baseRevision) == [4, 5])
    }

    @Test("A document older than the one held is ignored")
    func olderDocumentIsIgnored() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(label)
        await until { store.read(label).current != nil }

        // The conflict's reload is answered with a document from before the one held.
        transport.changeElsewhere(["label": "elsewhere"])
        transport.answerNextLoad(with: SettingsServerDocument(fields: ["enabled": false, "label": "ancient"], revision: 2))
        await store.set(label, "mine").value

        // The ancient document did not become the base of the next write or the value shown.
        #expect(store.read(label).current == "first")
        await store.set(label, "again").value
        #expect(transport.saves.map(\.baseRevision) == [4, 4])
    }

    @Test("A setting first read after its route loaded reads that document instead of asking again")
    func laterSettingReadsTheLoadedDocument() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true, "label": "shared"], revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).current != nil }

        // Not .loading, and no second request.
        #expect(store.read(label) == .value("shared", revision: 4))
        await store.set(label, "changed").value
        #expect(transport.loads == 1)
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["label": "changed"], baseRevision: 4)])
    }

    @Test("A route with no revision is written without one and has no conflict path")
    func unrevisionedRoute() async {
        let transport = FakeSettingsTransport(revision: nil)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).current != nil }
        #expect(store.read(enabled) == .value(false, revision: nil))

        await store.set(enabled, true).value

        #expect(store.read(enabled) == .value(true, revision: nil))
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: nil)])
    }

    @Test("Writes to one route run in order, each against the revision the last one produced")
    func writesToOneRouteAreSerial() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        _ = store.read(label)
        await until { store.read(enabled).current != nil }

        let first = store.set(enabled, true)
        let second = store.set(label, "second")
        await first.value
        await second.value

        #expect(transport.saves.map(\.baseRevision) == [4, 5])
        #expect(store.read(enabled) == .value(true, revision: 6))
        #expect(store.read(label) == .value("second", revision: 6))
    }

    @Test("A server that cannot be reached fails the load with Retry, and Retry loads again")
    func unreachableServerFailsWithRetry() async {
        let transport = FakeSettingsTransport()
        let reachable = Box(false)
        let store = SettingsStore(
            device: DeviceAdapter(defaults: makeSettingsDefaults()),
            server: ServerAdapter { [reachable] _ in reachable.value ? transport : nil }
        )
        store.attach(serverId: "s1")
        _ = store.read(label)
        await until { store.read(label).failureReason != nil }
        #expect(store.read(label) == .failed(last: nil, reason: "The server is not reachable."))
        #expect(store.canRetry(id: label.id))

        reachable.value = true
        store.retry(id: label.id)
        await until { store.read(label).current != nil }
        #expect(store.read(label) == .value("first", revision: 4))
    }

    @Test("A load failure can be retried")
    func loadFailureThenRetry() async {
        let transport = FakeSettingsTransport()
        transport.failNextLoad(with: SettingsTestError())
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).failureReason != nil }
        #expect(store.read(enabled) == .failed(last: nil, reason: "The server said no."))

        store.retry(id: enabled.id)
        await until { store.read(enabled).current != nil }
        #expect(store.read(enabled) == .value(false, revision: 4))
    }

    // MARK: - Context

    @Test("With no server attached a server setting is unavailable and a device setting still works")
    func noServer() async {
        let store = makeStore([:])
        #expect(store.read(label).unavailableReason != nil)
        await store.set(label, "x").value
        #expect(store.read(label).unavailableReason != nil)
        await store.set(haptics, false).value
        #expect(store.read(haptics) == .value(false, revision: nil))
    }

    @Test("A switch to another server drops what was loaded and ignores a write still in flight for the old one")
    func contextSwitchDropsStaleResults() async {
        let old = FakeSettingsTransport(fields: ["enabled": false, "label": "old"], revision: 1)
        let new = FakeSettingsTransport(fields: ["enabled": true, "label": "new"], revision: 7)
        let store = makeStore(["s1": old, "s2": new])
        store.attach(serverId: "s1")
        _ = store.read(label)
        await until { store.read(label).current != nil }

        let gate = SettingsGate()
        old.holdSaves(gate)
        let write = store.set(label, "changed")
        await until { !old.saves.isEmpty }
        #expect(store.read(label) == .saving(shown: "changed", previous: "old"))

        store.attach(serverId: "s2")
        #expect(store.read(label) == .loading)
        await until { store.read(label).current != nil }
        #expect(store.read(label) == .value("new", revision: 7))

        await gate.open()
        await write.value

        // The old server's answer landed after the switch and changed nothing.
        #expect(store.read(label) == .value("new", revision: 7))
        #expect(new.saves.isEmpty)
    }

    @Test("A load still in flight for the old server is ignored too, even when the app comes back to it")
    func staleLoadIsIgnored() async {
        let old = FakeSettingsTransport(fields: ["enabled": false, "label": "old"], revision: 1)
        let gate = SettingsGate()
        old.holdLoads(gate)
        let store = makeStore(["s1": old, "s2": FakeSettingsTransport(fields: ["enabled": true, "label": "new"], revision: 7)])
        store.attach(serverId: "s1")
        _ = store.read(label)
        await until { old.loads == 1 }

        store.attach(serverId: "s2")
        store.attach(serverId: "s1")
        #expect(store.read(label) == .loading)
        await gate.open()
        // The first answer is for a context that ended; the second one, asked for after coming back, lands.
        await until { store.read(label).current != nil }
        #expect(store.read(label) == .value("old", revision: 1))
        #expect(old.loads == 2)
    }

    @Test("Attaching the server it already has changes nothing")
    func sameServerKeepsState() async {
        let transport = FakeSettingsTransport()
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(label)
        await until { store.read(label).current != nil }
        store.attach(serverId: "s1")
        #expect(store.read(label) == .value("first", revision: 4))
        #expect(transport.loads == 1)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
