import Foundation
import Testing
@testable import Oppi

@Suite("Settings adapters")
struct SettingsAdaptersTests {
    // MARK: - Device

    @Test("A device setting reads its default until something is stored, then the stored value")
    func deviceReadsDefaultThenStored() throws {
        let adapter = DeviceAdapter(defaults: makeSettingsDefaults())
        let provider = SettingsCatalog.autoNameProvider
        #expect(try adapter.read(provider) == .server)

        try adapter.write(provider, .onDevice)
        #expect(try adapter.read(provider) == .onDevice)
    }

    @Test("A device value is stored in the form the preference stores: a raw string, a boolean")
    func deviceStoresThePreferencesForm() throws {
        let defaults = makeSettingsDefaults()
        let adapter = DeviceAdapter(defaults: defaults)
        try adapter.write(SettingsCatalog.autoNameProvider, .off)
        #expect(defaults.string(forKey: AppPreferenceStore.Session.autoTitleProviderKey) == "off")

        let flag = SettingDeclaration<Bool>(
            id: "test.flag", key: "test.flag", storage: .device(perServer: false), default: false,
            copy: SettingCopy(title: "Flag")
        )
        try adapter.write(flag, true)
        #expect(defaults.object(forKey: "test.flag") as? Bool == true)
        #expect(try adapter.read(flag) == true)
    }

    @Test("A stored value that no longer decodes reads as the default")
    func deviceUnreadableValueReadsDefault() throws {
        let defaults = makeSettingsDefaults()
        defaults.set("someday-a-fourth-provider", forKey: AppPreferenceStore.Session.autoTitleProviderKey)
        #expect(try DeviceAdapter(defaults: defaults).read(SettingsCatalog.autoNameProvider) == .server)
    }

    @Test("The adapter and the preference read and write the same value")
    func deviceSharesTheKeyWithAppPreferences() throws {
        let key = AppPreferenceStore.Session.autoTitleProviderKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        let adapter = DeviceAdapter()
        try adapter.write(SettingsCatalog.autoNameProvider, .onDevice)
        #expect(AppPreferences.Session.autoTitleProvider == .onDevice)

        AppPreferences.Session.setAutoTitleProvider(.off)
        #expect(try adapter.read(SettingsCatalog.autoNameProvider) == .off)
    }

    @Test("A per-server device value has no adapter yet and says so")
    func devicePerServerIsUnsupported() {
        let perServer = SettingDeclaration<Bool>(
            id: "test.perServer", key: "test.perServer", storage: .device(perServer: true), default: false,
            copy: SettingCopy(title: "Per server")
        )
        let adapter = DeviceAdapter(defaults: makeSettingsDefaults())
        #expect(throws: SettingsError.self) { try adapter.read(perServer) }
        #expect(throws: SettingsError.self) { try adapter.write(perServer, true) }
    }

    // MARK: - Server

    @Test("A server value is one field of the route's document, or the default when the field is missing or null")
    func serverValueOfField() {
        let model = SettingsCatalog.autoNameServerModel
        let enabled = SettingsCatalog.autoNameServerEnabled
        let document = SettingsServerDocument(fields: ["enabled": true, "model": "anthropic/claude-haiku-5"], revision: 2)
        #expect(ServerAdapter.value(of: enabled, in: document) == true)
        #expect(ServerAdapter.value(of: model, in: document) == "anthropic/claude-haiku-5")

        let sparse = SettingsServerDocument(fields: ["model": .null])
        #expect(ServerAdapter.value(of: model, in: sparse) == model.default)
        #expect(ServerAdapter.value(of: enabled, in: sparse) == enabled.default)
        // A field of the wrong type is not a value.
        #expect(ServerAdapter.value(of: enabled, in: SettingsServerDocument(fields: ["enabled": "yes"])) == enabled.default)
    }

    @Test("A write sends only its own field, and the base revision only for a revisioned route")
    @MainActor
    func serverSavesOneField() async throws {
        let transport = FakeSettingsTransport()
        let adapter = ServerAdapter { _ in transport }
        let model = SettingsCatalog.autoNameServerModel

        _ = try await adapter.save(model, "openai/gpt-5-mini", endpoint: .autoTitle, revisioned: true, baseRevision: 4, serverId: "s1")
        _ = try await adapter.save(model, "openai/gpt-5", endpoint: .autoTitle, revisioned: false, baseRevision: 5, serverId: "s1")

        #expect(transport.saves == [
            .init(endpoint: .autoTitle, fields: ["model": "openai/gpt-5-mini"], baseRevision: 4),
            .init(endpoint: .autoTitle, fields: ["model": "openai/gpt-5"], baseRevision: nil),
        ])
    }

    @Test("A server that cannot be reached is unavailable, not a crash")
    @MainActor
    func serverWithoutTransportIsUnavailable() async {
        let adapter = ServerAdapter { _ in nil }
        await #expect(throws: SettingsError.self) { try await adapter.load(.autoTitle, serverId: "s1") }
    }
}
