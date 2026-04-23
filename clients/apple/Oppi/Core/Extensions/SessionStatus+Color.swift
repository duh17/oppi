import SwiftUI

extension SessionStatus {
    /// Status indicator color for the session list's semantic state language.
    var color: Color {
        switch self {
        case .starting, .busy, .stopping: return .themeBlue
        case .ready: return .themeGreen
        case .stopped: return .themeComment
        case .error: return .themeRed
        }
    }
}
