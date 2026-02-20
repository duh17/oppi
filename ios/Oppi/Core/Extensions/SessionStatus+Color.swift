import SwiftUI

extension SessionStatus {
    /// Status indicator color (tokyo night palette).
    var color: Color {
        switch self {
        case .starting: return .themeBlue
        case .ready: return .themeGreen
        case .busy: return .themeYellow
        case .stopping: return .themeOrange
        case .stopped: return .themeComment
        case .error: return .themeRed
        }
    }
}
