import SwiftUI

extension SlashCommand.Source {
    var iconColor: Color {
        switch self {
        case .builtin: return .themeBlue
        case .extension: return .themePurple
        case .prompt: return .themeGreen
        case .skill: return .themeYellow
        }
    }
}
