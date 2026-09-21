import Foundation

/// Visual style for the composer dictation control.
///
/// `ring` is the legacy stroke. `composing` and `breathing` are Metal orbs.
enum DictationIndicatorStyle: String, CaseIterable, Sendable {
    case composing
    case breathing
    case ring

    var displayName: String {
        switch self {
        case .composing: return "Composing"
        case .breathing: return "Breathing"
        case .ring: return "Ring"
        }
    }

    /// Current dictation indicator style from the shared preference store.
    static var current: Self {
        AppPreferenceStore.Appearance.dictationIndicatorStyle
    }
}
