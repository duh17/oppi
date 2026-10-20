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

    @Test func agentStyleOverridesSettingsOnlyForThatAgentOnThatServer() {
        let defaults = UserDefaults.standard
        let keys = [AppPreferences.ChatDisplay.styleKey, AppPreferences.ChatDisplay.agentStylesKey]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        keys.forEach(defaults.removeObject(forKey:))
        AppPreferences.ChatDisplay.setStyle(.compact)

        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatDisplay.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        AppPreferences.ChatDisplay.setAgentStyle(.chat, serverId: "server-a", agentId: "agent-1")
        #expect(notifications == 1)
        #expect(AppPreferences.ChatDisplay.style(serverId: "server-a", agentId: "agent-1") == .chat)
        // Another Agent, the same Agent ID on another server, and a session
        // without an Agent keep following Settings.
        #expect(AppPreferences.ChatDisplay.style(serverId: "server-a", agentId: "agent-2") == .compact)
        #expect(AppPreferences.ChatDisplay.style(serverId: "server-b", agentId: "agent-1") == .compact)
        #expect(AppPreferences.ChatDisplay.style(serverId: "server-a", agentId: nil) == .compact)
        #expect(AppPreferences.ChatDisplay.style(serverId: nil, agentId: "agent-1") == .compact)

        // A Settings change does not move an Agent that has its own style.
        AppPreferences.ChatDisplay.setStyle(.full)
        #expect(notifications == 2)
        #expect(AppPreferences.ChatDisplay.style(serverId: "server-a", agentId: "agent-1") == .chat)

        // Setting the same style again does not redraw open chats.
        AppPreferences.ChatDisplay.setAgentStyle(.chat, serverId: "server-a", agentId: "agent-1")
        #expect(notifications == 2)

        // Clearing returns the Agent to Settings.
        AppPreferences.ChatDisplay.setAgentStyle(nil, serverId: "server-a", agentId: "agent-1")
        #expect(notifications == 3)
        #expect(AppPreferences.ChatDisplay.agentStyle(serverId: "server-a", agentId: "agent-1") == nil)
        #expect(AppPreferences.ChatDisplay.style(serverId: "server-a", agentId: "agent-1") == .full)
    }
}
