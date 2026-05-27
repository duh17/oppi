import Testing
import Foundation
@testable import Oppi

@Suite("AppPreferences.Browser")
struct BrowserPreferencesTests {
    private let linkOpeningModeKey = "\(AppIdentifiers.subsystem).browser.linkOpeningMode"

    @Test func defaultsToInAppBrowser() {
        UserDefaults.standard.removeObject(forKey: linkOpeningModeKey)
        defer { UserDefaults.standard.removeObject(forKey: linkOpeningModeKey) }

        #expect(AppPreferences.Browser.linkOpeningMode == .inApp)
    }

    @Test func persistsExternalBrowserChoice() {
        UserDefaults.standard.removeObject(forKey: linkOpeningModeKey)
        defer { UserDefaults.standard.removeObject(forKey: linkOpeningModeKey) }

        AppPreferences.Browser.setLinkOpeningMode(.external)

        #expect(AppPreferences.Browser.linkOpeningMode == .external)
    }
}
