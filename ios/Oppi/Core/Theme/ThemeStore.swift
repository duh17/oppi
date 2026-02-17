import Foundation
import SwiftUI

@MainActor @Observable
final class ThemeStore {
    var selectedThemeID: ThemeID {
        didSet {
            guard selectedThemeID != oldValue else { return }
            UserDefaults.standard.set(selectedThemeID.rawValue, forKey: ThemeID.storageKey)
            ThemeRuntimeState.setThemeID(selectedThemeID)
        }
    }

    var appTheme: AppTheme {
        selectedThemeID.appTheme
    }

    var preferredColorScheme: ColorScheme {
        selectedThemeID.preferredColorScheme
    }

    init() {
        let persisted = ThemeID.loadPersisted()
        selectedThemeID = persisted
        ThemeRuntimeState.setThemeID(persisted)
    }
}
