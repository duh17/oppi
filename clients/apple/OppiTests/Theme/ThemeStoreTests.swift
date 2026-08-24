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

    @Test func systemPresetsIgnoreMismatchedColorSchemes() {
        withCleanThemeDefaults {
            UserDefaults.standard.set(ThemeMode.system.rawValue, forKey: modeKey)
            UserDefaults.standard.set(ThemeID.night.rawValue, forKey: lightThemeKey)
            UserDefaults.standard.set(ThemeID.light.rawValue, forKey: darkThemeKey)

            let store = ThemeStore(initialSystemColorScheme: .light, systemColorSchemeProvider: { _ in .light })

            #expect(store.lightThemeID == .light)
            #expect(store.darkThemeID == .dark)
            #expect(store.activeThemeID == .light)
            #expect(UserDefaults.standard.string(forKey: lightThemeKey) == ThemeID.light.rawValue)
            #expect(UserDefaults.standard.string(forKey: darkThemeKey) == ThemeID.dark.rawValue)
        }
    }

    @Test func removingImportedThemeFallsBackToBuiltins() {
        withCleanThemeDefaults {
            let name = "imported-theme-\(UUID().uuidString)"
            defer { CustomThemeStore.delete(name: name) }
            CustomThemeStore.save(Self.makeLightTheme(name: name))

            let store = ThemeStore(initialSystemColorScheme: .light, systemColorSchemeProvider: { _ in .light })
            store.lightThemeID = .custom(name)
            store.removeImportedTheme(named: name)

            #expect(CustomThemeStore.load(name: name) == nil)
            #expect(store.lightThemeID == .light)
        }
    }

    @Test func assigningDarkThemeToLightPresetClampsToLight() {
        withCleanThemeDefaults {
            let store = ThemeStore(initialSystemColorScheme: .light, systemColorSchemeProvider: { _ in .light })
            store.lightThemeID = .night
            #expect(store.lightThemeID == .light)
        }
    }

    @Test func assigningLightThemeToDarkPresetClampsToDark() {
        withCleanThemeDefaults {
            let store = ThemeStore(initialSystemColorScheme: .dark, systemColorSchemeProvider: { _ in .dark })
            store.darkThemeID = .light
            #expect(store.darkThemeID == .dark)
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

    private static func makeLightTheme(name: String) -> RemoteTheme {
        RemoteTheme(
            name: name,
            colorScheme: "light",
            colors: RemoteThemeColors(
                bg: "#fbfaf7", bgDark: "#f2f0ea", bgHighlight: "#e7e4dc",
                fg: "#111111", fgDim: "#4f4f4f", comment: "#777777",
                blue: "#1f1f1f", cyan: "#3a3a3a", green: "#2f3a33",
                orange: "#4a4037", purple: "#303030", red: "#4a2f2f",
                yellow: "#4a4533", thinkingText: "#666666",
                userMessageBg: "#f2f0ea", userMessageText: "#111111",
                toolPendingBg: "#f5f4f0", toolSuccessBg: "#f2f3ef",
                toolErrorBg: "#f3f0ef", toolTitle: "#111111", toolOutput: "#5f5f5f",
                mdHeading: "#111111", mdLink: "#111111", mdLinkUrl: "#777777",
                mdCode: "#1f1f1f", mdCodeBlock: "#333333",
                mdCodeBlockBorder: "#d3d0c7", mdQuote: "#5f5f5f",
                mdQuoteBorder: "#c9c6bd", mdHr: "#d8d5cc",
                mdListBullet: "#111111",
                toolDiffAdded: "#2f3a33", toolDiffRemoved: "#4a2f2f",
                toolDiffContext: "#777777",
                syntaxComment: "#777777", syntaxKeyword: "#111111",
                syntaxFunction: "#1f1f1f", syntaxVariable: "#111111",
                syntaxString: "#333333", syntaxNumber: "#4a4037",
                syntaxType: "#303030", syntaxOperator: "#4f4f4f",
                syntaxPunctuation: "#5f5f5f",
                thinkingOff: "#c9c6bd", thinkingMinimal: "#8b8b8b",
                thinkingLow: "#666666", thinkingMedium: "#4f4f4f",
                thinkingHigh: "#333333", thinkingXhigh: "#111111"
            )
        )
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
