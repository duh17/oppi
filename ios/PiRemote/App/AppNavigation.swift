import SwiftUI

/// Navigation state for the app.
@MainActor @Observable
final class AppNavigation {
    var selectedTab: AppTab = .sessions
    var showOnboarding: Bool = true
}

enum AppTab: Hashable {
    case sessions
    case settings
}
