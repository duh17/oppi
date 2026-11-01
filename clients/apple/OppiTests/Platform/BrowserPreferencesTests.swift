import Testing
import Foundation
@testable import Oppi

/// On a defaults suite of its own: the app's link preference is never touched.
@Suite("AppPreferenceStore.Browser")
struct BrowserPreferencesTests {
    private typealias Store = AppPreferenceStore.Browser

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "BrowserPreferencesTests.\(UUID().uuidString)"))
    }

    @Test func defaultsToInAppBrowser() throws {
        #expect(Store.linkOpeningMode(in: try makeDefaults()) == .inApp)
    }

    @Test func persistsExternalBrowserChoice() throws {
        let defaults = try makeDefaults()
        Store.setLinkOpeningMode(.external, in: defaults)

        #expect(Store.linkOpeningMode(in: defaults) == .external)
        #expect(defaults.string(forKey: "\(AppIdentifiers.subsystem).browser.linkOpeningMode") == "external")
    }
}
