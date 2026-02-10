import SwiftUI

extension SessionStatus {
    /// Status indicator color (tokyo night palette).
    var color: Color {
        switch self {
        case .starting: return .tokyoBlue
        case .ready: return .tokyoGreen
        case .busy: return .tokyoYellow
        case .stopping: return .tokyoOrange
        case .stopped: return .tokyoComment
        case .error: return .tokyoRed
        }
    }
}
