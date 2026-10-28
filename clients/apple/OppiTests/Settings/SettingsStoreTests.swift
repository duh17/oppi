import Foundation
import Testing
@testable import Oppi

@Suite("SettingsStore", .serialized)
@MainActor
struct SettingsStoreTests {
    private let enabled = SettingsCatalog.autoNameServerEnabled
    private let model = SettingsCatalog.autoNameServerModel
    private let provider = SettingsCatalog.autoNameProvider

    private func makeStore(
        _ transports: [String: FakeSettingsTransport],
        defaults: UserDefaults = makeSettingsDefaults()
    ) -> SettingsStore {
        SettingsStore(
            device: DeviceAdapter(defaults: defaults),
            server: ServerAdapter { transports[$0] },
            serverName: { $0 == "s1" ? "mac-studio" : nil }
        )
    }

    /// Lets the store's own tasks run until `condition` holds.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - Device

    @Test("A device setting reads and writes through the adapter and never touches a server")
    func deviceSettingNeverWritesTheServer() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true, "model": "anthropic/claude-haiku-5"])
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")

        #expect(store.read(provider) == .value(.server, revision: nil))
        await store.set(provider, .onDevice).value
        #expect(store.read(provider) == .value(.onDevice, revision: nil))
        await store.set(provider, .off).value
        #expect(store.read(provider) == .value(.off, revision: nil))

        // The Auto-Name bug: choosing On-device or Off used to write `enabled: false` to the server.
        #expect(transport.saves.isEmpty)
        #expect(transport.loads == 0)
    }

    @Test("A refused value is not written, and the row says why")
    func validationRefusesBeforeAnyWrite() async {
        let transport = FakeSettingsTransport()
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(model)
        await until { store.read(model).current != nil }

        await store.set(model, "").value

        #expect(store.read(model) == .failed(last: "anthropic/claude-haiku-5", reason: "Choose a model."))
        #expect(store.failureReason(id: model.id) == "Choose a model.")
        #expect(!store.canRetry(id: model.id))
        #expect(transport.saves.isEmpty)
    }

    // MARK: - Server

    @Test("A server setting loads on its first read, and every setting on the route shares the load")
    func serverLoadsOnFirstRead() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true, "model": "openai/gpt-5-mini"], revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")

        #expect(store.read(enabled) == .loading)
        #expect(store.read(model) == .loading)
        await until { store.read(enabled).current != nil }

        #expect(store.read(enabled) == .value(true, revision: 4))
        #expect(store.read(model) == .value("openai/gpt-5-mini", revision: 4))
        #expect(transport.loads == 1)
    }

    @Test("A write shows the new value as saving, then the stored one with its revision")
    func serverWriteSettlesToTheStoredValue() async {
        let transport = FakeSettingsTransport(revision: 4)
        let gate = SettingsGate()
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = (store.read(enabled), store.read(model))
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
        #expect(store.read(model) == .value("anthropic/claude-haiku-5", revision: 5))
        #expect(transport.saves == [.init(endpoint: .autoTitle, fields: ["enabled": true], baseRevision: 4)])
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

        await store.retry(enabled).value
        #expect(store.read(enabled) == .value(true, revision: 5))
        #expect(transport.saves.count == 2)
        #expect(!store.canRetry(id: enabled.id))
    }

    @Test("A revision conflict reloads the server's value, says it changed elsewhere, and leaves the row editable")
    func conflictReloads() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(model)
        await until { store.read(model).current != nil }

        // Another device changed the model after this one loaded.
        transport.changeElsewhere(["model": "openai/gpt-5"])
        await store.set(model, "google/gemini-2.5-pro").value

        #expect(store.read(model) == .failed(last: "openai/gpt-5", reason: "Changed on another device; showing the latest."))
        // A message, not a failure to retry: nothing to run again, and the row can be changed.
        #expect(!store.canRetry(id: model.id))
        #expect(transport.saves.count == 1)
        #expect(transport.loads == 2)

        await store.set(model, "google/gemini-2.5-pro").value
        #expect(store.read(model) == .value("google/gemini-2.5-pro", revision: 6))
        #expect(transport.saves.map(\.baseRevision) == [4, 5])
    }

    @Test("A document older than the one held is ignored")
    func olderDocumentIsIgnored() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(model)
        await until { store.read(model).current != nil }

        // The conflict's reload is answered with a document from before the one held.
        transport.changeElsewhere(["model": "openai/gpt-5"])
        transport.answerNextLoad(with: SettingsServerDocument(fields: ["enabled": false, "model": "a/ancient"], revision: 2))
        await store.set(model, "google/gemini-2.5-pro").value

        // The ancient document did not become the base of the next write or the value shown.
        #expect(store.read(model).current == "anthropic/claude-haiku-5")
        await store.set(model, "openai/gpt-5-mini").value
        #expect(transport.saves.map(\.baseRevision) == [4, 4])
    }

    @Test("A setting first read after its route loaded reads that document instead of asking again")
    func laterSettingReadsTheLoadedDocument() async {
        let transport = FakeSettingsTransport(fields: ["enabled": true, "model": "openai/gpt-5-mini"], revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).current != nil }

        // Not .loading, and no second request.
        #expect(store.read(model) == .value("openai/gpt-5-mini", revision: 4))
        await store.set(model, "openai/gpt-5").value
        #expect(transport.loads == 1)
        #expect(transport.saves == [.init(endpoint: .autoTitle, fields: ["model": "openai/gpt-5"], baseRevision: 4)])
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
        #expect(transport.saves == [.init(endpoint: .autoTitle, fields: ["enabled": true], baseRevision: nil)])
    }

    @Test("Writes to one route run in order, each against the revision the last one produced")
    func writesToOneRouteAreSerial() async {
        let transport = FakeSettingsTransport(revision: 4)
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        _ = store.read(model)
        await until { store.read(enabled).current != nil }

        let first = store.set(enabled, true)
        let second = store.set(model, "openai/gpt-5-mini")
        await first.value
        await second.value

        #expect(transport.saves.map(\.baseRevision) == [4, 5])
        #expect(store.read(enabled) == .value(true, revision: 6))
        #expect(store.read(model) == .value("openai/gpt-5-mini", revision: 6))
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
        _ = store.read(model)
        await until { store.read(model).failureReason != nil }
        #expect(store.read(model) == .failed(last: nil, reason: "The server is not reachable."))
        #expect(store.canRetry(id: model.id))

        reachable.value = true
        store.retry(model)
        await until { store.read(model).current != nil }
        #expect(store.read(model) == .value("anthropic/claude-haiku-5", revision: 4))
    }

    @Test("A load failure keeps the other settings' retry independent of a stale answer")
    func loadFailureThenRetry() async {
        let transport = FakeSettingsTransport()
        transport.failNextLoad(with: SettingsTestError())
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(enabled)
        await until { store.read(enabled).failureReason != nil }
        #expect(store.read(enabled) == .failed(last: nil, reason: "The server said no."))

        store.retry(enabled)
        await until { store.read(enabled).current != nil }
        #expect(store.read(enabled) == .value(false, revision: 4))
    }

    // MARK: - Context

    @Test("With no server attached a server setting is unavailable and a device setting still works")
    func noServer() async {
        let store = makeStore([:])
        #expect(store.read(model).unavailableReason != nil)
        await store.set(model, "openai/gpt-5").value
        #expect(store.read(model).unavailableReason != nil)
        await store.set(provider, .off).value
        #expect(store.read(provider) == .value(.off, revision: nil))
    }

    @Test("A switch to another server drops what was loaded and ignores a write still in flight for the old one")
    func contextSwitchDropsStaleResults() async {
        let old = FakeSettingsTransport(fields: ["enabled": false, "model": "a/old"], revision: 1)
        let new = FakeSettingsTransport(fields: ["enabled": true, "model": "b/new"], revision: 7)
        let store = makeStore(["s1": old, "s2": new])
        store.attach(serverId: "s1")
        _ = store.read(model)
        await until { store.read(model).current != nil }

        let gate = SettingsGate()
        old.holdSaves(gate)
        let write = store.set(model, "a/changed")
        await until { !old.saves.isEmpty }
        #expect(store.read(model) == .saving(shown: "a/changed", previous: "a/old"))

        store.attach(serverId: "s2")
        #expect(store.read(model) == .loading)
        await until { store.read(model).current != nil }
        #expect(store.read(model) == .value("b/new", revision: 7))

        await gate.open()
        await write.value

        // The old server's answer landed after the switch and changed nothing.
        #expect(store.read(model) == .value("b/new", revision: 7))
        #expect(new.saves.isEmpty)
    }

    @Test("A load still in flight for the old server is ignored too, even when the app comes back to it")
    func staleLoadIsIgnored() async {
        let old = FakeSettingsTransport(fields: ["enabled": false, "model": "a/old"], revision: 1)
        let gate = SettingsGate()
        old.holdLoads(gate)
        let store = makeStore(["s1": old, "s2": FakeSettingsTransport(fields: ["enabled": true, "model": "b/new"], revision: 7)])
        store.attach(serverId: "s1")
        _ = store.read(model)
        await until { old.loads == 1 }

        store.attach(serverId: "s2")
        store.attach(serverId: "s1")
        #expect(store.read(model) == .loading)
        await gate.open()
        // The first answer is for a context that ended; the second one, asked for after coming back, lands.
        await until { store.read(model).current != nil }
        #expect(store.read(model) == .value("a/old", revision: 1))
        #expect(old.loads == 2)
    }

    @Test("Attaching the server it already has changes nothing")
    func sameServerKeepsState() async {
        let transport = FakeSettingsTransport()
        let store = makeStore(["s1": transport])
        store.attach(serverId: "s1")
        _ = store.read(model)
        await until { store.read(model).current != nil }
        store.attach(serverId: "s1")
        #expect(store.read(model) == .value("anthropic/claude-haiku-5", revision: 4))
        #expect(transport.loads == 1)
    }

    @Test("A scope names the attached server")
    func scopeNamesTheServer() {
        let store = makeStore([:])
        #expect(store.scope(of: provider) == .device)
        store.attach(serverId: "s1")
        #expect(store.scope(of: model) == .server("mac-studio"))
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
