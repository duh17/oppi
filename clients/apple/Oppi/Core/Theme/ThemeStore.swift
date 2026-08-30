import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Notification.Name {
    /// Main-actor notification for persistent UIKit surfaces that are not
    /// recreated by SwiftUI when the active Oppi theme changes.
    static let oppiThemeDidChange = Notification.Name("dev.chenda.oppi.themeDidChange")
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case manual
    case system

    var id: Self { self }

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .system: return "Match System"
        }
    }

    var detail: String {
        switch self {
        case .manual:
            return "Use one selected theme everywhere."
        case .system:
            #if os(macOS)
            return "Follow macOS light and dark appearance, using your selected presets for each."
            #else
            return "Follow iOS light and dark appearance, using your selected presets for each."
            #endif
        }
    }
}

@MainActor @Observable
final class ThemeStore {
    private static let modeKey = "\(AppIdentifiers.subsystem).theme.mode"
    private static let lightThemeKey = "\(AppIdentifiers.subsystem).theme.light.id"
    private static let darkThemeKey = "\(AppIdentifiers.subsystem).theme.dark.id"

    @ObservationIgnored private let systemColorSchemeProvider: (ColorScheme) -> ColorScheme

    var mode: ThemeMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .system {
                // When leaving a forced manual scheme, SwiftUI can report the
                // previous environment value for one transaction. Read the
                // platform system appearance first so chrome and palette stay aligned.
                refreshSystemColorSchemeFromSystemTraits()
            }
            applyResolvedTheme()
        }
    }

    var manualThemeID: ThemeID {
        didSet {
            guard manualThemeID != oldValue else { return }
            UserDefaults.standard.set(manualThemeID.rawValue, forKey: ThemeID.storageKey)
            applyResolvedTheme()
        }
    }

    var lightThemeID: ThemeID {
        didSet {
            let matched = lightThemeID.matching(scheme: .light)
            if matched != lightThemeID {
                lightThemeID = matched
                return
            }
            guard lightThemeID != oldValue else { return }
            UserDefaults.standard.set(lightThemeID.rawValue, forKey: Self.lightThemeKey)
            applyResolvedTheme()
        }
    }

    var darkThemeID: ThemeID {
        didSet {
            let matched = darkThemeID.matching(scheme: .dark)
            if matched != darkThemeID {
                darkThemeID = matched
                return
            }
            guard darkThemeID != oldValue else { return }
            UserDefaults.standard.set(darkThemeID.rawValue, forKey: Self.darkThemeKey)
            applyResolvedTheme()
        }
    }

    private var systemColorScheme: ColorScheme {
        didSet {
            guard systemColorScheme != oldValue else { return }
            applyResolvedTheme()
        }
    }

    private(set) var activeThemeID: ThemeID

    /// Backward-compatible single theme selection. Setting this returns to manual mode.
    var selectedThemeID: ThemeID {
        get { manualThemeID }
        set {
            mode = .manual
            manualThemeID = newValue
        }
    }

    var appTheme: AppTheme {
        activeThemeID.appTheme
    }

    var preferredColorScheme: ColorScheme? {
        mode == .system ? nil : activeThemeID.preferredColorScheme
    }

    init(
        initialSystemColorScheme: ColorScheme? = nil,
        systemColorSchemeProvider: ((ColorScheme) -> ColorScheme)? = nil
    ) {
        let systemColorSchemeProvider = systemColorSchemeProvider ?? { fallback in
            Self.currentSystemColorScheme(fallback: fallback)
        }
        let observedSystemColorScheme = initialSystemColorScheme ?? systemColorSchemeProvider(.dark)
        CustomThemeStore.migrateRenamedThemes()
        let persistedManual = CustomThemeStore.migratedThemeID(ThemeID.loadPersisted())
        if persistedManual != ThemeID.loadPersisted() {
            UserDefaults.standard.set(persistedManual.rawValue, forKey: ThemeID.storageKey)
        }
        let persistedMode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(ThemeMode.init(rawValue:)) ?? .manual
        let persistedLight = CustomThemeStore.migratedThemeID(
            Self.persistedTheme(
                key: Self.lightThemeKey,
                fallback: .light,
                scheme: .light
            )
        )
        let persistedDark = CustomThemeStore.migratedThemeID(
            Self.persistedTheme(
                key: Self.darkThemeKey,
                fallback: persistedManual.preferredColorScheme == .light ? .dark : persistedManual,
                scheme: .dark
            )
        )

        self.systemColorSchemeProvider = systemColorSchemeProvider
        systemColorScheme = observedSystemColorScheme
        mode = persistedMode
        manualThemeID = persistedManual
        lightThemeID = persistedLight
        darkThemeID = persistedDark
        activeThemeID = persistedMode == .system
            ? (observedSystemColorScheme == .light ? persistedLight : persistedDark)
            : persistedManual
        ThemeRuntimeState.setThemeID(activeThemeID)
    }

    func updateSystemColorScheme(_ colorScheme: ColorScheme) {
        systemColorScheme = colorScheme
    }

    func removeImportedTheme(named name: String) {
        CustomThemeStore.delete(name: name)
        if case .custom(let current) = manualThemeID, current == name {
            manualThemeID = .dark
        }
        if case .custom(let current) = lightThemeID, current == name {
            lightThemeID = .light
        }
        if case .custom(let current) = darkThemeID, current == name {
            darkThemeID = .dark
        }
    }

    /// Load a Light/Dark preset, keep it on the matching side of the picker,
    /// and rewrite a stored mismatch so the next launch does not re-clamp.
    private static func persistedTheme(key: String, fallback: ThemeID, scheme: ColorScheme) -> ThemeID {
        let stored = UserDefaults.standard.string(forKey: key)
        let raw = stored.map(ThemeID.init(rawValue:)) ?? fallback
        let matched = raw.matching(scheme: scheme)
        if let stored, matched.rawValue != stored {
            UserDefaults.standard.set(matched.rawValue, forKey: key)
        }
        return matched
    }

    private static func currentSystemColorScheme(fallback: ColorScheme = .dark) -> ColorScheme {
        #if canImport(UIKit)
        guard let userInterfaceStyle = currentForegroundWindowScene()?.screen.traitCollection.userInterfaceStyle else {
            return fallback
        }
        switch userInterfaceStyle {
        case .light:
            return .light
        case .dark:
            return .dark
        case .unspecified:
            return fallback
        @unknown default:
            return fallback
        }
        #elseif canImport(AppKit)
        // Do not read `NSApp.effectiveAppearance` here. ThemeStore is created
        // from SwiftUI `App.init`, and that AppKit call traps before the
        // application object is ready. `MacThemeColorSchemeSyncView` refreshes
        // from the SwiftUI environment once the window is up.
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
            return .dark
        }
        return .light
        #else
        return fallback
        #endif
    }

    #if canImport(UIKit)
    /// Foreground-active window scene, used to resolve system appearance
    /// without the deprecated `UIScreen.main` singleton (iOS 26).
    private static func currentForegroundWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    #endif

    private func refreshSystemColorSchemeFromSystemTraits() {
        systemColorScheme = systemColorSchemeProvider(systemColorScheme)
    }

    private func resolvedThemeID() -> ThemeID {
        switch mode {
        case .manual:
            return manualThemeID
        case .system:
            return systemColorScheme == .light ? lightThemeID : darkThemeID
        }
    }

    private func applyResolvedTheme(evictCaches: Bool = true) {
        let nextThemeID = resolvedThemeID()
        guard activeThemeID != nextThemeID else { return }
        activeThemeID = nextThemeID
        ThemeRuntimeState.setThemeID(nextThemeID)
        NotificationCenter.default.post(
            name: .oppiThemeDidChange,
            object: self,
            userInfo: ["themeID": nextThemeID.rawValue]
        )
        if evictCaches {
            #if canImport(UIKit)
            ToolRowRenderCache.evictAll()
            #endif
        }
    }
}
