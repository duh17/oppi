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

    /// Keep the All Sessions empty-state copy from stacking under the setup card.
    static func shouldShowInboxEmptyState(isEmpty: Bool, showsProviderSetup: Bool) -> Bool {
        isEmpty && !showsProviderSetup
    }
}

struct ProviderSetupPromptCard: View {
    let message: String
    let openAccessibilityIdentifier: String
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish server setup", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.themeComment)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Button("Configure Model Provider", action: onConfigure)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(openAccessibilityIdentifier)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.themeComment.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.themeComment.opacity(0.18), lineWidth: 1)
        )
    }
}

struct ProviderSetupPromptListSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Section {
            content
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
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
