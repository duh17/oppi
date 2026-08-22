import Foundation
import Testing
@testable import Oppi

@Suite("AppPreferences.ChatDisplay", .serialized)
struct QuietModePreferencesTests {
    @Test func settingChangesNotifyTheChatAndSettingsSurfaces() {
        let defaults = UserDefaults.standard
        let key = AppPreferences.ChatDisplay.compactTurnsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)

        var notifications = 0
        var chatSurfaceValue: Bool?
        var settingsSurfaceValue: Bool?
        let chatToken = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            notifications += 1
            chatSurfaceValue = AppPreferences.ChatDisplay.isCompactTurnsEnabled
        }
        let settingsToken = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            settingsSurfaceValue = AppPreferences.ChatDisplay.isCompactTurnsEnabled
        }
        defer {
            NotificationCenter.default.removeObserver(chatToken)
            NotificationCenter.default.removeObserver(settingsToken)
        }

        AppPreferences.ChatDisplay.setCompactTurnsEnabled(true)
        #expect(notifications == 1)
        #expect(chatSurfaceValue == true)
        #expect(settingsSurfaceValue == true)

        AppPreferences.ChatDisplay.setCompactTurnsEnabled(true)
        #expect(notifications == 1)
    }

    @Test func workStripStyleDefaultsToIconsAndNotifiesOnChange() {
        let defaults = UserDefaults.standard
        let key = AppPreferences.ChatDisplay.workStripStyleKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)

        #expect(AppPreferences.ChatDisplay.workStripStyle == .icons)

        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        AppPreferences.ChatDisplay.setWorkStripStyle(.words)
        #expect(AppPreferences.ChatDisplay.workStripStyle == .words)
        #expect(defaults.string(forKey: key) == "words")
        #expect(notifications == 1)

        AppPreferences.ChatDisplay.setWorkStripStyle(.words)
        #expect(notifications == 1)
    }

    @Test func compactTurnsDefaultsOffAndRemainsDeviceLocal() {
        let defaults = UserDefaults.standard
        let key = AppPreferences.ChatDisplay.compactTurnsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(AppPreferences.ChatDisplay.isCompactTurnsEnabled == false)

        AppPreferences.ChatDisplay.setCompactTurnsEnabled(true)
        #expect(AppPreferences.ChatDisplay.isCompactTurnsEnabled)
        #expect(defaults.object(forKey: key) as? Bool == true)

        AppPreferences.ChatDisplay.setCompactTurnsEnabled(false)
        #expect(AppPreferences.ChatDisplay.isCompactTurnsEnabled == false)
    }
}
