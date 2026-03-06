import SwiftUI

/// Applet grid for a single workspace — pushed from WorkspaceDetailView.
struct WorkspaceAppletsView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection
    @Environment(AppletStore.self) private var appletStore

    @State private var selectedApplet: Applet?

    private var displayedApplets: [Applet] {
        appletStore.applets(for: workspace.id)
    }

    var body: some View {
        Group {
            if appletStore.isLoading && displayedApplets.isEmpty {
                ProgressView("Loading applets...")
            } else if displayedApplets.isEmpty {
                ContentUnavailableView(
                    "No Applets",
                    systemImage: "doc.richtext",
                    description: Text("Ask an agent to create one.\nUse the create_applet tool.")
                )
            } else {
                appletGrid
            }
        }
        .navigationTitle("Applets")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedApplet) { applet in
            AppletViewerView(applet: applet)
        }
        .task {
            if let api = connection.apiClient {
                await appletStore.refreshIfNeeded(workspaceId: workspace.id, api: api)
            }
        }
        .refreshable {
            if let api = connection.apiClient {
                await appletStore.load(workspaceId: workspace.id, api: api)
            }
        }
    }

    private var appletGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 12
            ) {
                ForEach(displayedApplets) { applet in
                    Button {
                        selectedApplet = applet
                    } label: {
                        AppletCard(applet: applet)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

// MARK: - Card

struct AppletCard: View {
    let applet: Applet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.themeBlue)
                Spacer()
                Text("v\(applet.currentVersion)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.themeBlue.opacity(0.12), in: Capsule())
                    .foregroundStyle(.themeBlue)
            }

            Text(applet.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let desc = applet.description {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Text(applet.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }
}
