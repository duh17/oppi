import SwiftUI

/// Applet grid for a single workspace — pushed from WorkspaceDetailView.
struct WorkspaceAppletsView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection
    @Environment(AppletStore.self) private var appletStore
    @Environment(SessionStore.self) private var sessionStore

    @State private var selectedApplet: Applet?
    @State private var pendingDeleteApplet: Applet?
    @State private var navigateToSession: SessionDestination?
    @State private var busyMessage: String?
    @State private var error: String?

    private struct SessionDestination: Identifiable, Hashable {
        let id: String
    }

    private var displayedApplets: [Applet] {
        appletStore.applets(for: workspace.id)
    }

    private var isBusy: Bool {
        busyMessage != nil
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
        .navigationDestination(item: $navigateToSession) { destination in
            ChatView(sessionId: destination.id)
        }
        .task {
            if let api = connection.apiClient {
                await appletStore.load(workspaceId: workspace.id, api: api)
            }
        }
        .refreshable {
            if let api = connection.apiClient {
                await appletStore.load(workspaceId: workspace.id, api: api)
            }
        }
        .overlay {
            if let busyMessage {
                ProgressView(busyMessage)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .alert(
            pendingDeleteApplet.map { "Delete \($0.title)?" } ?? "Delete Applet?",
            isPresented: Binding(
                get: { pendingDeleteApplet != nil },
                set: { if !$0 { pendingDeleteApplet = nil } }
            ),
            presenting: pendingDeleteApplet
        ) { applet in
            Button("Delete", role: .destructive) {
                pendingDeleteApplet = nil
                Task { await deleteApplet(applet) }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteApplet = nil
            }
        } message: { applet in
            Text("This deletes \(applet.title) and all saved versions.")
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
                    .disabled(isBusy)
                    .contextMenu {
                        Button {
                            Task { await editApplet(applet) }
                        } label: {
                            Label("Edit in New Session", systemImage: "square.and.pencil")
                        }

                        Button(role: .destructive) {
                            pendingDeleteApplet = applet
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    @MainActor
    private func editApplet(_ applet: Applet) async {
        guard let api = connection.apiClient else {
            error = "Not connected"
            return
        }

        busyMessage = "Preparing edit session..."
        defer { busyMessage = nil }

        do {
            let session = try await api.createAppletEditSession(
                workspaceId: applet.workspaceId,
                appletId: applet.id
            )
            _ = sessionStore.upsert(session)
            sessionStore.activeSessionId = session.id
            navigateToSession = SessionDestination(id: session.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func deleteApplet(_ applet: Applet) async {
        guard let api = connection.apiClient else {
            error = "Not connected"
            return
        }

        busyMessage = "Deleting applet..."
        defer { busyMessage = nil }

        do {
            try await api.deleteApplet(workspaceId: applet.workspaceId, appletId: applet.id)
            appletStore.remove(id: applet.id)
            if selectedApplet?.id == applet.id {
                selectedApplet = nil
            }
        } catch {
            self.error = error.localizedDescription
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
