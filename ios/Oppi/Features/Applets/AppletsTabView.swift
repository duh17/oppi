import SwiftUI

/// Grid view of applets for the active server's workspaces.
struct AppletsTabView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(AppletStore.self) private var appletStore

    @State private var selectedWorkspaceId: String?

    private var workspaces: [Workspace] {
        connection.workspaceStore.workspaces
    }

    private var activeWorkspaceId: String? {
        selectedWorkspaceId ?? workspaces.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspaces.count > 1 {
                workspacePicker
            }

            if appletStore.isLoading && appletStore.applets.isEmpty {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Loading applets...")
                }
            } else if appletStore.applets.isEmpty {
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
        .task(id: activeWorkspaceId) {
            if let wid = activeWorkspaceId, let api = connection.apiClient {
                await appletStore.load(workspaceId: wid, api: api)
            }
        }
        .refreshable {
            if let wid = activeWorkspaceId, let api = connection.apiClient {
                await appletStore.load(workspaceId: wid, api: api)
            }
        }
    }

    // MARK: - Workspace Picker

    private var workspacePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(workspaces) { ws in
                    Button {
                        selectedWorkspaceId = ws.id
                    } label: {
                        Text(ws.name)
                            .font(.subheadline.weight(activeWorkspaceId == ws.id ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                activeWorkspaceId == ws.id
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Grid

    private var appletGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 12
            ) {
                ForEach(appletStore.applets) { applet in
                    NavigationLink(value: applet) {
                        AppletCard(applet: applet)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationDestination(for: Applet.self) { applet in
            AppletViewerView(applet: applet)
        }
    }
}

// MARK: - Card

private struct AppletCard: View {
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
