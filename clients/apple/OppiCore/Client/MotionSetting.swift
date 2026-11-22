import Foundation

/// How much of the app moves: the person's choice in Settings → Chat →
/// Animations.
///
/// `full` (shown as On) is every animation the app has, which is what it had
/// before this setting existed. `moments` (shown as Short) keeps decorative
/// loops still (the busy spinner, the dictation indicator, the sidebar's mark,
/// an icon that plays on its own page) and still plays a moment: one short
/// burst when something happens, as a session's icon does when it needs the
/// person. `off` plays nothing and every icon keeps its first frame.
///
/// The names are labels: the stored raw values stay, so a stored choice keeps
/// its meaning across the rename.
enum MotionSetting: String, CaseIterable, Sendable, Codable {
    case full
    case moments
    case off

    var displayName: String {
        switch self {
        case .full: "On"
        case .moments: "Short"
        case .off: "Off"
        }
    }

    /// Motion that never ends on its own.
    var playsLoops: Bool { self == .full }

    /// One short burst (`IconChoiceUIView.playBurst`) at a moment: a chat opens,
    /// a turn ends, a session needs the person.
    var playsMoments: Bool { self != .off }
}
