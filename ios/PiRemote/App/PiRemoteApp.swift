import SwiftUI

@main
struct PiRemoteApp: App {
    @State private var connection = ServerConnection()
    @State private var navigation = AppNavigation()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(connection.sessionStore)
                .environment(connection.permissionStore)
                .environment(connection.reducer)
                .environment(connection.reducer.toolOutputStore)
                .environment(navigation)
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                .task { await reconnectOnLaunch() }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await connection.reconnectIfNeeded() }
        case .background, .inactive:
            break
        @unknown default:
            break
        }
    }

    private func reconnectOnLaunch() async {
        // 1. Load credentials from Keychain
        guard let creds = KeychainService.loadCredentials() else {
            navigation.showOnboarding = true
            return
        }

        navigation.showOnboarding = false
        connection.configure(credentials: creds)

        // 2. Refresh session list
        guard let api = connection.apiClient else { return }
        do {
            let sessions = try await api.listSessions()
            connection.sessionStore.sessions = sessions
        } catch {
            // Offline — show cached state (empty for now)
        }
    }
}
