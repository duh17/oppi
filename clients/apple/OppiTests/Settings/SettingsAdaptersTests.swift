import Foundation
import Testing
@testable import Oppi

@Suite("Settings adapters")
struct SettingsAdaptersTests {
    // MARK: - Device

    @Test("A device setting reads its default until something is stored, then the stored value")
    func deviceReadsDefaultThenStored() throws {
        let adapter = DeviceAdapter(defaults: makeSettingsDefaults())
        let links = SettingsCatalog.openLinks
        #expect(try adapter.read(links) == .inApp)

        try adapter.write(links, .external)
        #expect(try adapter.read(links) == .external)
    }

    @Test("A device value is stored in the form the preference stores: a boolean, an integer, a raw string")
    func deviceStoresThePreferencesForm() throws {
        let defaults = makeSettingsDefaults()
        let adapter = DeviceAdapter(defaults: defaults)

        try adapter.write(SettingsCatalog.hapticFeedback, false)
        #expect(defaults.object(forKey: AppPreferenceStore.Interaction.hapticFeedbackEnabledKey) as? Bool == false)

        try adapter.write(SettingsCatalog.keepAwakeAfterActivity, .fiveMinutes)
        #expect(defaults.object(forKey: AppPreferenceStore.ScreenAwake.timeoutPresetKey) as? Int == 300)

        try adapter.write(SettingsCatalog.openLinks, .external)
        #expect(defaults.string(forKey: AppPreferenceStore.Browser.linkOpeningModeKey) == "external")
    }

    @Test("A stored value that no longer decodes reads as the default")
    func deviceUnreadableValueReadsDefault() throws {
        let defaults = makeSettingsDefaults()
        defaults.set("someday-a-third-browser", forKey: AppPreferenceStore.Browser.linkOpeningModeKey)
        defaults.set(7, forKey: AppPreferenceStore.ScreenAwake.timeoutPresetKey)
        let adapter = DeviceAdapter(defaults: defaults)
        #expect(try adapter.read(SettingsCatalog.openLinks) == .inApp)
        #expect(try adapter.read(SettingsCatalog.keepAwakeAfterActivity) == .twoMinutes)
    }

    @Test("The adapter and each preference share one key and one stored form, in a suite of their own")
    func deviceSharesTheKeyAndFormWithThePreference() throws {
        let defaults = makeSettingsDefaults()
        let adapter = DeviceAdapter(defaults: defaults)

        // What the adapter stores, the preference decodes.
        try adapter.write(SettingsCatalog.keepAwakeAfterActivity, .tenMinutes)
        let storedPreset = defaults.object(forKey: AppPreferenceStore.ScreenAwake.timeoutPresetKey) as? Int
        #expect(storedPreset.flatMap(AppPreferenceStore.ScreenAwake.TimeoutPreset.init(rawValue:)) == .tenMinutes)

        // What the preference stores (`setTimeoutPreset` stores the raw value), the adapter reads.
        defaults.set(AppPreferenceStore.ScreenAwake.TimeoutPreset.oneMinute.rawValue, forKey: AppPreferenceStore.ScreenAwake.timeoutPresetKey)
        #expect(try adapter.read(SettingsCatalog.keepAwakeAfterActivity) == .oneMinute)
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
        let metrics = SettingsCatalog.serverMetricsEnabled
        let document = SettingsServerDocument(fields: ["enabled": true], revision: 2)
        #expect(ServerAdapter.value(of: metrics, in: document) == true)

        #expect(ServerAdapter.value(of: metrics, in: SettingsServerDocument(fields: ["enabled": .null])) == metrics.default)
        #expect(ServerAdapter.value(of: metrics, in: SettingsServerDocument(fields: [:])) == metrics.default)
        // A field of the wrong type is not a value.
        #expect(ServerAdapter.value(of: metrics, in: SettingsServerDocument(fields: ["enabled": "yes"])) == metrics.default)
    }

    @Test("A write sends only its own field, and the base revision only for a revisioned route")
    @MainActor
    func serverSavesOneField() async throws {
        let transport = FakeSettingsTransport()
        let adapter = ServerAdapter { _ in transport }

        _ = try await adapter.save(testLabelSetting, "one", endpoint: .serverMetrics, revisioned: true, baseRevision: 4, serverId: "s1")
        _ = try await adapter.save(testLabelSetting, "two", endpoint: .serverMetrics, revisioned: false, baseRevision: 5, serverId: "s1")

        #expect(transport.saves == [
            .init(endpoint: .serverMetrics, fields: ["label": "one"], baseRevision: 4),
            .init(endpoint: .serverMetrics, fields: ["label": "two"], baseRevision: nil),
        ])
    }

    @Test("A server that cannot be reached is unavailable, not a crash")
    @MainActor
    func serverWithoutTransportIsUnavailable() async {
        let adapter = ServerAdapter { _ in nil }
        await #expect(throws: SettingsError.self) { try await adapter.load(.serverMetrics, serverId: "s1") }
    }
}
