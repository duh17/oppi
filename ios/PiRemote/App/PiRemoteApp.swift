import SwiftUI

@main
struct PiRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .task {
                    await setupNotifications()
                    await reconnectOnLaunch()
                }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await connection.reconnectIfNeeded() }
        case .background:
            connection.flushAndSuspend()
            RestorationState.save(from: connection, navigation: navigation)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func setupNotifications() async {
        let notificationService = PermissionNotificationService.shared
        await notificationService.setup()

        // Wire notification actions back to the connection
        notificationService.onPermissionResponse = { [weak connection] permissionId, action in
            guard let connection else { return }
            Task {
                try? await connection.respondToPermission(id: permissionId, action: action)
            }
        }

        // Configure push registration with the connection
        PushRegistration.shared.configure(connection: connection)

        // Navigate to session when user taps a push notification body
        notificationService.onNavigateToPermission = { [weak connection] _, sessionId in
            guard let connection, !sessionId.isEmpty else { return }
            connection.sessionStore.activeSessionId = sessionId
            navigation.selectedTab = .sessions
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

        // 2. Restore UI state (tab, active session, draft)
        if let restored = RestorationState.load() {
            navigation.selectedTab = AppTab(rawString: restored.selectedTab)
            connection.sessionStore.activeSessionId = restored.activeSessionId
            connection.composerDraft = restored.composerDraft
        }

        // 3. Refresh session list
        guard let api = connection.apiClient else { return }
        do {
            let sessions = try await api.listSessions()
            connection.sessionStore.sessions = sessions

            // 4. Register for push notifications (after successful server connection)
            await PushRegistration.shared.requestAndRegister()
        } catch {
            // Offline — show cached state (empty for now)
        }
    }
}
