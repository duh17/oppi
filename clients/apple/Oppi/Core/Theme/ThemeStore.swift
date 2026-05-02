import Foundation
import SwiftUI

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

    var mode: ThemeMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
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

    private var systemColorScheme: ColorScheme = .dark {
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

    init() {
        let persistedManual = ThemeID.loadPersisted()
        let persistedMode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(ThemeMode.init(rawValue:)) ?? .manual
        let persistedLight = UserDefaults.standard.string(forKey: Self.lightThemeKey)
            .map(ThemeID.init(rawValue:)) ?? .light
        let persistedDark = UserDefaults.standard.string(forKey: Self.darkThemeKey)
            .map(ThemeID.init(rawValue:)) ?? (persistedManual.preferredColorScheme == .light ? .dark : persistedManual)

        mode = persistedMode
        manualThemeID = persistedManual
        lightThemeID = persistedLight
        darkThemeID = persistedDark
        activeThemeID = persistedMode == .system ? persistedDark : persistedManual
        ThemeRuntimeState.setThemeID(activeThemeID)
    }

    func updateSystemColorScheme(_ colorScheme: ColorScheme) {
        systemColorScheme = colorScheme
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
        if evictCaches {
            ToolRowRenderCache.evictAll()
        }
    }
}
