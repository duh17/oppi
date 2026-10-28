import Foundation
import Testing
@testable import Oppi

@Suite("Settings catalog")
struct SettingsCatalogTests {
    @Test("Every setting has its own id, and no two settings share a place in storage")
    func identitiesAreUnique() {
        let ids = SettingsCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let places = SettingsCatalog.all.map { "\($0.storage)|\($0.key)" }
        #expect(Set(places).count == places.count)
    }

    @Test("Auto-Name's provider is the device preference on its existing key and default")
    func autoNameProviderIsThePreference() {
        let provider = SettingsCatalog.autoNameProvider
        #expect(provider.key == AppPreferenceStore.Session.autoTitleProviderKey)
        #expect(provider.storage == .device(perServer: false))

        let original = UserDefaults.standard.object(forKey: provider.key)
        defer { UserDefaults.standard.set(original, forKey: provider.key) }
        UserDefaults.standard.removeObject(forKey: provider.key)
        #expect(AppPreferences.Session.autoTitleProvider == provider.default)
    }

    @Test("The server's Auto-Name settings live on the auto-title route, which revisions its document")
    func autoNameServerSettingsAreOnTheRoute() {
        for descriptor in [SettingsCatalog.autoNameServerEnabled.descriptor, SettingsCatalog.autoNameServerModel.descriptor] {
            #expect(descriptor.storage == .server(.autoTitle, revisioned: true))
        }
        #expect(SettingEndpoint.autoTitle.path == "/server/auto-title")
        #expect(SettingsCatalog.autoNameServerEnabled.key == "enabled")
        #expect(SettingsCatalog.autoNameServerModel.key == "model")
    }

    @Test("A model must be chosen")
    func modelValidation() {
        let model = SettingsCatalog.autoNameServerModel
        #expect(model.validate("  ") != nil)
        #expect(model.validate("anthropic/claude-haiku-5") == nil)
    }

    @Test("A setting's scope follows its storage and the names it is shown under")
    func scopeFollowsStorage() {
        #expect(SettingStorage.device(perServer: false).scope(serverName: "mac-studio", workspaceName: nil) == .device)
        #expect(SettingStorage.device(perServer: true).scope(serverName: "mac-studio", workspaceName: nil) == .deviceOnServer("mac-studio"))
        #expect(SettingStorage.server(.autoTitle, revisioned: true).scope(serverName: "mac-studio", workspaceName: nil) == .server("mac-studio"))
        #expect(SettingStorage.workspace(field: "name").scope(serverName: "mac-studio", workspaceName: "oppi") == .workspace("oppi"))
        #expect(SettingStorage.deviceOnServer(.autoTitle, field: "x").scope(serverName: "mac-studio", workspaceName: nil) == .deviceOnServer("mac-studio"))
        #expect(SettingStorage.piOwned(.autoTitle, level: .global).scope(serverName: "mac-studio", workspaceName: nil) == .server("mac-studio"))
    }
}
