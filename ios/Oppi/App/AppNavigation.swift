import SwiftUI

/// Navigation state for the app.
@MainActor @Observable
final class AppNavigation {
    var selectedTab: AppTab = .workspaces
    var showOnboarding: Bool = true
    var showWhatsNew: Bool = false
}

enum AppTab: Hashable {
    case workspaces
    case settings
}
