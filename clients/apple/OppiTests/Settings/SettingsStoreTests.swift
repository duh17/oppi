import Foundation
import Testing
@testable import Oppi

@Suite("SettingsStore", .serialized)
@MainActor
struct SettingsStoreTests {
    private let enabled = SettingsCatalog.serverMetricsEnabled
    private let label = testLabelSetting
    private let haptics = SettingsCatalog.hapticFeedback

    /// One paired server's store, over a fake route.
    private func makeServerStore(
        _ transport: FakeSettingsTransport,
        serverId: String = "s1",
        afterWrite: @escaping @MainActor (String) -> Void = { _ in }
    ) -> SettingsStore {
        SettingsStore(serverId: serverId, server: ServerAdapter { _ in transport }, afterWrite: afterWrite)
    }

    /// The device store, on a suite of its own.
    private func makeDeviceStore(
        defaults: UserDefaults,
        afterWrite: @escaping @MainActor (String) -> Void = { _ in }
    ) -> SettingsStore {
        SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil }, afterWrite: afterWrite)
    }

    /// Lets the store's own tasks run until `condition` holds.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A server store whose `label` and `enabled` are loaded.
    private func loaded(_ transport: FakeSettingsTransport, serverId: String = "s1") async -> SettingsStore {
        let store = makeServerStore(transport, serverId: serverId)
        _ = (store.read(enabled), store.read(label))
        await until { store.read(enabled).current != nil }
        return store
    }

    // MARK: - Device

    @Test("The device store reads and writes through the adapter, and set returns the settled value")
    func deviceStoreWritesThroughTheAdapter() async throws {
        let defaults = try makeSettingsDefaults()
        let store = makeDeviceStore(defaults: defaults)

        #expect(store.read(haptics) == .value(true, revision: nil))
        let settled = await store.set(haptics, false).value
        #expect(settled == .value(false, revision: nil))
        #expect(store.read(haptics) == .value(false, revision: nil))
        #expect(defaults.object(forKey: AppPreferenceStore.Interaction.hapticFeedbackEnabledKey) as? Bool == false)
    }

    @Test("A stored write runs the store's hook with the setting's id, and a refused one does not")
    func afterWriteRunsForStoredWrites() async throws {
        var written: [String] = []
        let device = makeDeviceStore(defaults: try makeSettingsDefaults(), afterWrite: { written.append($0) })
        let transport = FakeSettingsTransport()
        let server = makeServerStore(transport, afterWrite: { written.append($0) })

        _ = await device.set(SettingsCatalog.keepAwakeAfterActivity, .fiveMinutes).value
        #expect(written == [SettingsCatalog.keepAwakeAfterActivity.id])
        #expect(device.read(SettingsCatalog.keepAwakeAfterActivity) == .value(.fiveMinutes, revision: nil))

        _ = server.read(label)
        await until { server.read(label).current != nil }
        _ = await server.set(label, "").value
        #expect(written == [SettingsCatalog.keepAwakeAfterActivity.id])

        _ = await server.set(label, "second").value
        #expect(written == [SettingsCatalog.keepAwakeAfterActivity.id, label.id])
    }

    @Test("A refused value is not written, and the row says why")
    func validationRefusesBeforeAnyWrite() async {
        let transport = FakeSettingsTransport()
        let store = await loaded(transport)

        let refused = await store.set(label, "").value

        #expect(refused == .failed(last: "first", reason: "Give it a label."))
        #expect(store.read(label) == refused)
        #expect(store.failureReason(id: label.id) == "Give it a label.")
        #expect(!store.canRetry(id: label.id))
        #expect(transport.saves.isEmpty)
    }

    // MARK: - Server

    @Test("A server setting loads on its first read, and every setting on the route shares the load")
    func serverLoadsOnFirstRead() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true, "label": "shared"], revision: 4)
        let store = makeServerStore(transport)

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
        let store = await loaded(transport)

        // The document moved on without this store: another writer, or a path that bypassed it.
        transport.changeElsewhere(["enabled": true])
        #expect(store.read(enabled) == .value(false, revision: 4))

        let fresh = await store.reload(enabled)
        #expect(fresh == .value(true, revision: 5))
        #expect(transport.loads == 2)

        let settled = await store.set(enabled, false).value
        #expect(settled == .value(false, revision: 6))
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": false], baseRevision: 5)])
    }

    @Test("reload of a setting that was never read loads it")
    func reloadLoadsAnUnreadSetting() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true], revision: 4)
        let store = makeServerStore(transport)
        #expect(await store.reload(enabled) == .value(true, revision: 4))
        #expect(transport.loads == 1)
    }

    @Test("reload waits for a save in flight, and keeps a failed fetch's last value")
    func reloadWaitsForSavesAndSurvivesFailure() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)

        let gate = SettingsGate()
        transport.holdSaves(gate)
        let write = store.set(enabled, true)
        await until { !transport.saves.isEmpty }
        async let reloaded = store.reload(enabled)
        // The fetch has not run while the save is held.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(transport.loads == 1)
        await gate.open()
        _ = await write.value
        #expect(await reloaded == .value(true, revision: 5))

        transport.failNextLoad(with: SettingsTestError())
        #expect(await store.reload(enabled) == .failed(last: true, reason: "The server said no."))
    }

    @Test("A write shows the new value as saving, then the stored one with its revision, and returns it")
    func serverWriteSettlesToTheStoredValue() async {
        let transport = FakeSettingsTransport(revision: 4)
        let gate = SettingsGate()
        let store = await loaded(transport)

        transport.holdSaves(gate)
        let write = store.set(enabled, true)
        #expect(store.read(enabled) == .saving(shown: true, previous: false))
        await gate.open()
        let settled = await write.value

        #expect(settled == .value(true, revision: 5))
        #expect(store.read(enabled) == settled)
        // The other setting on the route took the new revision, so its next write is not stale.
        #expect(store.read(label) == .value("first", revision: 5))
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 4)])
    }

    @Test("A second writer asking for the value being saved waits for that save and shares its result")
    func secondWriterOfTheSameValueSharesTheSave() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)
        let gate = SettingsGate()
        transport.holdSaves(gate)

        let first = store.set(enabled, true)
        await until { !transport.saves.isEmpty }
        // The first save is in flight; asking for the same value joins it.
        let second = store.set(enabled, true)
        #expect(store.read(enabled) == .saving(shown: true, previous: false))
        await gate.open()

        let settledFirst = await first.value
        let settledSecond = await second.value
        #expect(settledFirst == .value(true, revision: 5))
        #expect(settledSecond == settledFirst)
        #expect(settledSecond != .saving(shown: true, previous: false))
        #expect(transport.saves.count == 1)
    }

    @Test("A second writer asking for a different value queues behind the save in flight and returns its own result")
    func secondWriterOfAnotherValueQueues() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)
        let gate = SettingsGate()
        transport.holdSaves(gate)

        let first = store.set(enabled, true)
        await until { !transport.saves.isEmpty }
        // Save 1 (true) is in flight; false is a different value and must not be dropped.
        let second = store.set(enabled, false)
        #expect(store.read(enabled) == .saving(shown: true, previous: false))
        #expect(transport.saves.count == 1)
        await gate.open()

        let settledFirst = await first.value
        let settledSecond = await second.value
        #expect(settledFirst == .value(true, revision: 5))
        #expect(settledSecond == .value(false, revision: 6))
        // Two saves went out, in order, each against the revision the last produced.
        #expect(transport.saves == [
            .init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 4),
            .init(endpoint: .serverMetrics, fields: ["enabled": false], baseRevision: 5),
        ])
        #expect(store.read(enabled) == .value(false, revision: 6))
    }

    @Test("Last tap wins: true in flight, then false, then true go out in that order and the setting ends true")
    func lastTapWins() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)
        let gate = SettingsGate()
        transport.holdSaves(gate)

        let first = store.set(enabled, true)
        await until { !transport.saves.isEmpty }
        let second = store.set(enabled, false)
        // Asked for true while false is queued: it waits for false, it does not share true's save.
        let third = store.set(enabled, true)
        #expect(store.read(enabled) == .saving(shown: true, previous: false))
        await gate.open()

        #expect(await first.value == .value(true, revision: 5))
        #expect(await second.value == .value(false, revision: 6))
        #expect(await third.value == .value(true, revision: 7))
        #expect(transport.saves == [
            .init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 4),
            .init(endpoint: .serverMetrics, fields: ["enabled": false], baseRevision: 5),
            .init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 6),
        ])
        #expect(store.read(enabled) == .value(true, revision: 7))
    }

    @Test("A save that is cancelled rolls back, and is not left saving")
    func cancelledSaveRollsBack() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)

        transport.failNextSave(with: CancellationError())
        let reverted = await store.set(enabled, true).value

        #expect(reverted == .value(false, revision: nil))
        #expect(store.read(enabled) == reverted)
        #expect(!store.canRetry(id: enabled.id))
        // Nothing is wedged: the next write goes out.
        #expect(await store.set(enabled, true).value == .value(true, revision: 5))
    }

    @Test("A writer queued behind a save that is cancelled still writes, and nothing waits forever")
    func queuedWriterSurvivesACancelledSave() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)
        let gate = SettingsGate()
        transport.holdSaves(gate)
        transport.failNextSave(with: CancellationError())

        let first = store.set(enabled, true)
        await until { !transport.saves.isEmpty }
        let second = store.set(enabled, true)
        await gate.open()

        #expect(await first.value == .value(false, revision: nil))
        // The first save never settled, so the queued one is the one that writes.
        #expect(await second.value == .value(true, revision: 5))
        #expect(transport.saves.count == 2)
        #expect(store.read(enabled) == .value(true, revision: 5))
    }

    @Test("A failed write rolls back to the previous value with the reason, and Retry writes it again")
    func serverFailureRollsBackAndRetries() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)

        transport.failNextSave(with: SettingsTestError())
        let failed = await store.set(enabled, true).value
        #expect(failed == .failed(last: false, reason: "The server said no."))
        #expect(store.read(enabled) == failed)
        #expect(store.canRetry(id: enabled.id))

        await store.retry(id: enabled.id).value
        #expect(store.read(enabled) == .value(true, revision: 5))
        #expect(transport.saves.count == 2)
        #expect(!store.canRetry(id: enabled.id))
    }

    @Test("A revision conflict reloads the server's value, says it changed elsewhere, and leaves the row editable")
    func conflictReloads() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)

        // Another device changed the label after this one loaded.
        transport.changeElsewhere(["label": "elsewhere"])
        let latest = await store.set(label, "mine").value

        #expect(latest == .failed(last: "elsewhere", reason: "Changed on another device; showing the latest."))
        #expect(store.read(label) == latest)
        // A message, not a failure to retry: nothing to run again, and the row can be changed.
        #expect(!store.canRetry(id: label.id))
        #expect(transport.saves.count == 1)
        #expect(transport.loads == 2)

        let saved = await store.set(label, "mine").value
        #expect(saved == .value("mine", revision: 6))
        #expect(transport.saves.map(\.baseRevision) == [4, 5])
    }

    @Test("A document older than the one held is ignored")
    func olderDocumentIsIgnored() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)

        // The conflict's reload is answered with a document from before the one held.
        transport.changeElsewhere(["label": "elsewhere"])
        transport.answerNextLoad(with: SettingsServerDocument(fields: ["enabled": false, "label": "ancient"], revision: 2))
        _ = await store.set(label, "mine").value

        // The ancient document did not become the base of the next write or the value shown.
        #expect(store.read(label).current == "first")
        _ = await store.set(label, "again").value
        #expect(transport.saves.map(\.baseRevision) == [4, 4])
    }

    @Test("A setting first read after its route loaded reads that document instead of asking again")
    func laterSettingReadsTheLoadedDocument() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true, "label": "shared"], revision: 4)
        let store = makeServerStore(transport)
        _ = store.read(enabled)
        await until { store.read(enabled).current != nil }

        // Not .loading, and no second request.
        #expect(store.read(label) == .value("shared", revision: 4))
        _ = await store.set(label, "changed").value
        #expect(transport.loads == 1)
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["label": "changed"], baseRevision: 4)])
    }

    @Test("A route with no revision is written without one and has no conflict path")
    func unrevisionedRoute() async {
        let transport = FakeSettingsTransport(revision: nil)
        let store = await loaded(transport)
        #expect(store.read(enabled) == .value(false, revision: nil))

        let settled = await store.set(enabled, true).value

        #expect(settled == .value(true, revision: nil))
        #expect(transport.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: nil)])
    }

    @Test("Writes to one route run in order, each against the revision the last one produced")
    func writesToOneRouteAreSerial() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = await loaded(transport)

        let first = store.set(enabled, true)
        let second = store.set(label, "second")
        _ = await first.value
        _ = await second.value

        #expect(transport.saves.map(\.baseRevision) == [4, 5])
        #expect(store.read(enabled) == .value(true, revision: 6))
        #expect(store.read(label) == .value("second", revision: 6))
    }

    @Test("A server that cannot be reached fails the load with Retry, and Retry loads again")
    func unreachableServerFailsWithRetry() async {
        let transport = FakeSettingsTransport()
        let reachable = Box(false)
        let store = SettingsStore(serverId: "s1", server: ServerAdapter { [reachable] _ in reachable.value ? transport : nil })
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
        let store = makeServerStore(transport)
        _ = store.read(enabled)
        await until { store.read(enabled).failureReason != nil }
        #expect(store.read(enabled) == .failed(last: nil, reason: "The server said no."))

        store.retry(id: enabled.id)
        await until { store.read(enabled).current != nil }
        #expect(store.read(enabled) == .value(false, revision: 4))
    }

    // MARK: - Two servers

    @Test("Two servers' stores at once: a save in flight for one never touches the other's loads, saves, or documents")
    func twoServersDoNotShareState() async {
        let a = FakeSettingsTransport(fields: ["enabled": false, "label": "a"], revision: 1)
        let b = FakeSettingsTransport(fields: ["enabled": false, "label": "b"], revision: 10)
        let storeA = await loaded(a, serverId: "A")
        let storeB = await loaded(b, serverId: "B")

        // B's save is in flight...
        let gate = SettingsGate()
        b.holdSaves(gate)
        let writeB = storeB.set(enabled, true)
        await until { !b.saves.isEmpty }

        // ...while A reloads and saves, and both succeed.
        #expect(await storeA.reload(label) == .value("a", revision: 1))
        let settledA = await storeA.set(enabled, true).value
        #expect(settledA == .value(true, revision: 2))
        #expect(await storeA.reload(label) == .value("a", revision: 2))
        #expect(storeB.read(enabled) == .saving(shown: true, previous: false))

        await gate.open()
        let settledB = await writeB.value
        #expect(settledB == .value(true, revision: 11))

        // Each store holds its own server's documents; none of the other's leaked in.
        #expect(await storeA.reload(enabled) == .value(true, revision: 2))
        #expect(await storeB.reload(label) == .value("b", revision: 11))
        #expect(a.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 1)])
        #expect(b.saves == [.init(endpoint: .serverMetrics, fields: ["enabled": true], baseRevision: 10)])
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
