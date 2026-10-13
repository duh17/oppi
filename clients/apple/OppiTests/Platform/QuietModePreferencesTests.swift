import Foundation
import Testing
@testable import Oppi

@Suite("AppPreferences.ChatDisplay", .serialized)
struct QuietModePreferencesTests {
    @Test func styleDefaultsToFullAndNotifiesTheChatAndSettingsSurfacesOnce() {
        let defaults = UserDefaults.standard
        let key = AppPreferences.ChatDisplay.styleKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)
        #expect(AppPreferences.ChatDisplay.style == .full)

        var notifications = 0
        var chatSurfaceValue: AppPreferences.ChatDisplay.Style?
        var settingsSurfaceValue: AppPreferences.ChatDisplay.Style?
        let chatToken = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            notifications += 1
            chatSurfaceValue = AppPreferences.ChatDisplay.style
        }
        let settingsToken = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            settingsSurfaceValue = AppPreferences.ChatDisplay.style
        }
        defer {
            NotificationCenter.default.removeObserver(chatToken)
            NotificationCenter.default.removeObserver(settingsToken)
        }

        AppPreferences.ChatDisplay.setStyle(.chat)
        #expect(notifications == 1)
        #expect(chatSurfaceValue == .chat)
        #expect(settingsSurfaceValue == .chat)
        #expect(defaults.string(forKey: key) == "chat")

        AppPreferences.ChatDisplay.setStyle(.chat)
        #expect(notifications == 1)
    }

    @Test func eachStyleSetsFoldingAndRowChrome() {
        // Full shows everything; Compact folds work into a strip on the
        // transcript; Chat folds it into a pill on the messaging layout.
        let expected: [(AppPreferences.ChatDisplay.Style, Bool, ChatTimelineChromeStyle)] = [
            (.full, false, .standard),
            (.compact, true, .standard),
            (.chat, true, .conversation),
        ]
        for (style, folds, chrome) in expected {
            #expect(style.foldsWork == folds)
            #expect(ChatTimelineChromeStyle.for(style) == chrome)
        }
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
}
