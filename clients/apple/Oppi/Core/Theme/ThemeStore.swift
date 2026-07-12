import Foundation
import SwiftUI
import UIKit

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
            return "Follow iOS light and dark appearance, using your selected presets for each."
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
                // previous environment value for one transaction. Read UIKit's
                // system trait first so List/Form chrome and palette stay aligned.
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
            guard lightThemeID != oldValue else { return }
            UserDefaults.standard.set(lightThemeID.rawValue, forKey: Self.lightThemeKey)
            applyResolvedTheme()
        }
    }

    var darkThemeID: ThemeID {
        didSet {
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
        let persistedManual = ThemeID.loadPersisted()
        let persistedMode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(ThemeMode.init(rawValue:)) ?? .manual
        let persistedLight = UserDefaults.standard.string(forKey: Self.lightThemeKey)
            .map(ThemeID.init(rawValue:)) ?? .light
        let persistedDark = UserDefaults.standard.string(forKey: Self.darkThemeKey)
            .map(ThemeID.init(rawValue:)) ?? (persistedManual.preferredColorScheme == .light ? .dark : persistedManual)

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

    private static func currentSystemColorScheme(fallback: ColorScheme = .dark) -> ColorScheme {
        switch UIScreen.main.traitCollection.userInterfaceStyle {
        case .light:
            return .light
        case .dark:
            return .dark
        case .unspecified:
            return fallback
        @unknown default:
            return fallback
        }
    }

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
            ToolRowRenderCache.evictAll()
        }
    }
}
