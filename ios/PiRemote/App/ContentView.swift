import SwiftUI

struct ContentView: View {
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation

        if navigation.showOnboarding {
            OnboardingView()
        } else {
            TabView(selection: $nav.selectedTab) {
                SwiftUI.Tab("Sessions", systemImage: "terminal", value: AppTab.sessions) {
                    NavigationStack {
                        SessionListView()
                    }
                }
                SwiftUI.Tab("Live", systemImage: "list.bullet.rectangle", value: AppTab.live) {
                    NavigationStack {
                        LiveFeedView()
                    }
                }
                SwiftUI.Tab("Settings", systemImage: "gear", value: AppTab.settings) {
                    NavigationStack {
                        SettingsView()
                    }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
        }
    }
}
