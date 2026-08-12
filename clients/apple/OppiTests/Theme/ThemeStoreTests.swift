import SwiftUI
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("ThemeStore")
struct ThemeStoreTests {
    private let modeKey = "\(AppIdentifiers.subsystem).theme.mode"
    private let lightThemeKey = "\(AppIdentifiers.subsystem).theme.light.id"
    private let darkThemeKey = "\(AppIdentifiers.subsystem).theme.dark.id"

    @Test func manualModeUsesManualThemeAndForcesScheme() {
        withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeID.night.rawValue, forKey: ThemeID.storageKey)

            let store = ThemeStore()

            #expect(store.mode == .manual)
            #expect(store.manualThemeID == .night)
            #expect(store.activeThemeID == .night)
            #expect(store.preferredColorScheme == .dark)
            #expect(ThemeRuntimeState.currentThemeID() == .night)
        }
    }

    @Test func systemModeMapsSystemSchemeToSeparateThemes() {
        withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeMode.system.rawValue, forKey: modeKey)
            UserDefaults.standard.set(ThemeID.light.rawValue, forKey: lightThemeKey)
            UserDefaults.standard.set(ThemeID.oled.rawValue, forKey: darkThemeKey)

            let store = ThemeStore(initialSystemColorScheme: .dark, systemColorSchemeProvider: { _ in .dark })

            #expect(store.mode == .system)
            #expect(store.preferredColorScheme == nil)
            #expect(store.activeThemeID == .oled)

            store.updateSystemColorScheme(.light)
            #expect(store.activeThemeID == .light)
            #expect(ThemeRuntimeState.currentThemeID() == .light)

            store.updateSystemColorScheme(.dark)
            #expect(store.activeThemeID == .oled)
            #expect(ThemeRuntimeState.currentThemeID() == .oled)
        }
    }

    @Test func systemModeInitializesFromObservedSystemScheme() {
        withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeMode.system.rawValue, forKey: modeKey)
            UserDefaults.standard.set(ThemeID.light.rawValue, forKey: lightThemeKey)
            UserDefaults.standard.set(ThemeID.oled.rawValue, forKey: darkThemeKey)

            let store = ThemeStore(initialSystemColorScheme: .light, systemColorSchemeProvider: { _ in .light })

            #expect(store.mode == .system)
            #expect(store.activeThemeID == .light)
            #expect(ThemeRuntimeState.currentThemeID() == .light)
        }
    }

    @Test func settingSelectedThemeReturnsToManualMode() {
        withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeMode.system.rawValue, forKey: modeKey)

            let store = ThemeStore(initialSystemColorScheme: .dark, systemColorSchemeProvider: { _ in .dark })
            store.selectedThemeID = .light

            #expect(store.mode == .manual)
            #expect(store.manualThemeID == .light)
            #expect(store.activeThemeID == .light)
            #expect(store.preferredColorScheme == .light)
        }
    }

    @Test func switchingToSystemUsesObservedSystemScheme() {
        withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeID.oled.rawValue, forKey: ThemeID.storageKey)
            UserDefaults.standard.set(ThemeID.light.rawValue, forKey: lightThemeKey)
            UserDefaults.standard.set(ThemeID.night.rawValue, forKey: darkThemeKey)

            let store = ThemeStore(initialSystemColorScheme: .dark, systemColorSchemeProvider: { _ in .light })
            store.updateSystemColorScheme(.light)
            store.mode = .system

            #expect(store.activeThemeID == .light)
            #expect(store.preferredColorScheme == nil)
            #expect(ThemeRuntimeState.currentThemeID() == .light)
        }
    }

    @Test func switchingToSystemRefreshesStaleObservedScheme() {
        withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeID.oled.rawValue, forKey: ThemeID.storageKey)
            UserDefaults.standard.set(ThemeID.light.rawValue, forKey: lightThemeKey)
            UserDefaults.standard.set(ThemeID.night.rawValue, forKey: darkThemeKey)

            let store = ThemeStore(initialSystemColorScheme: .dark, systemColorSchemeProvider: { _ in .light })
            store.mode = .system

            #expect(store.activeThemeID == .light)
            #expect(ThemeRuntimeState.currentThemeID() == .light)
        }
    }

    @Test func swiftUIThemeShapeStylesResolveFromTheirEnvironment() {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        ThemeRuntimeState.setThemeID(.dark)

        var lightEnvironment = EnvironmentValues()
        lightEnvironment.theme = .light
        var oledEnvironment = EnvironmentValues()
        oledEnvironment.theme = .oled

        let foreground = ThemeShapeStyle(role: .foreground)
        let background = ThemeShapeStyle(role: .background)

        #expect(UIColor(foreground.color(in: lightEnvironment)) == UIColor(ThemePalettes.light.fg))
        #expect(UIColor(foreground.color(in: oledEnvironment)) == UIColor(ThemePalettes.oled.fg))
        #expect(UIColor(background.color(in: lightEnvironment)) == UIColor(ThemePalettes.light.bg))
        #expect(UIColor(background.color(in: oledEnvironment)) == UIColor(ThemePalettes.oled.bg))
    }

    @Test func mountedSurfaceStylesChangeWhenTheEnvironmentThemeChanges() {
        var environment = EnvironmentValues()
        let background = ThemeShapeStyle(role: .background)
        let foreground = ThemeShapeStyle(role: .foreground)
        let neutralActivity = ThemeShapeStyle(role: .comment)

        environment.theme = .dark
        let darkBackground = UIColor(background.color(in: environment))
        let darkForeground = UIColor(foreground.color(in: environment))
        let darkNeutralActivity = UIColor(neutralActivity.color(in: environment))

        environment.theme = .light
        #expect(UIColor(background.color(in: environment)) != darkBackground)
        #expect(UIColor(foreground.color(in: environment)) != darkForeground)
        #expect(UIColor(neutralActivity.color(in: environment)) != darkNeutralActivity)
        #expect(UIColor(background.color(in: environment)) == UIColor(ThemePalettes.light.bg))
        #expect(UIColor(foreground.color(in: environment)) == UIColor(ThemePalettes.light.fg))
        #expect(UIColor(neutralActivity.color(in: environment)) == UIColor(ThemePalettes.light.comment))
    }

    private func withCleanThemeDefaults(_ body: () -> Void) {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        let keys = [ThemeID.storageKey, modeKey, lightThemeKey, darkThemeKey]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })

        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        defer {
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
                if let value = originals[key], let value {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
            ThemeRuntimeState.setThemeID(originalThemeID)
        }

        body()
    }
}
