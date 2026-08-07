import SwiftUI

enum ProviderSetupState: Equatable {
    case unknown
    case unavailable
    case needsConfiguration
    case configured

    init(providerStatuses: [ProviderAuthProviderStatus]) {
        self = providerStatuses.contains(where: \.authenticated)
            ? .configured
            : .needsConfiguration
    }
}

enum ProviderSetupPromptPolicy {
    static func shouldShow(for state: ProviderSetupState) -> Bool {
        state == .needsConfiguration
    }
}

struct ProviderConfigurationPresentation: Equatable {
    let state: ProviderSetupState

    var showsLoading: Bool { state == .unknown }
    var showsProviderSections: Bool {
        state == .needsConfiguration || state == .configured
    }

    func summary(connectedCount: Int) -> String {
        switch state {
        case .unknown:
            "Loading…"
        case .unavailable:
            "Unavailable"
        case .needsConfiguration:
            "Setup required"
        case .configured:
            "\(connectedCount) connected"
        }
    }
}

struct ModelProvidersView: View {
    let server: PairedServer

    var body: some View {
        ServerDetailView(server: server, presentation: .modelProviders)
    }
}

struct ServerDetailsScopedDestinationView: View {
    @Environment(ServerStore.self) private var serverStore

    let target: ServerDetailsNavTarget

    var body: some View {
        if let server = serverStore.server(for: target.serverId) {
            ServerDetailView(server: server)
        } else {
            unavailableServerView
        }
    }

    private var unavailableServerView: some View {
        ContentUnavailableView(
            "Server Unavailable",
            systemImage: "server.rack",
            description: Text("This paired server is no longer available.")
        )
        .navigationTitle("Server Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ModelProvidersScopedDestinationView: View {
    @Environment(ServerStore.self) private var serverStore

    let target: ModelProvidersNavTarget

    var body: some View {
        if let server = serverStore.server(for: target.serverId) {
            ModelProvidersView(server: server)
        } else {
            ContentUnavailableView(
                "Server Unavailable",
                systemImage: "server.rack",
                description: Text("This paired server is no longer available.")
            )
            .navigationTitle("Model Providers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
