import SwiftUI
import UIKit

/// Grid of workspace cards shown when creating a new session.
///
/// Tapping a card creates a session with that workspace. Long-press
/// opens the workspace editor. Bottom link navigates to management.
struct WorkspacePickerView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false
    @State private var error: String?
    @State private var editingWorkspace: Workspace?

    private var workspaces: [Workspace] {
        connection.workspaceStore.workspaces
    }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if workspaces.isEmpty {
                    ContentUnavailableView(
                        "No Workspaces",
                        systemImage: "square.grid.2x2",
                        description: Text("Loading workspaces…")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(workspaces) { workspace in
                            WorkspaceCard(workspace: workspace) {
                                Task { await createSession(workspace: workspace) }
                            }
                            .contextMenu {
                                Button {
                                    editingWorkspace = workspace
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                            }
                            .disabled(isCreating)
                        }
                    }
                    .padding()
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink {
                        WorkspaceListView()
                    } label: {
                        Label("Manage Workspaces", systemImage: "slider.horizontal.3")
                            .font(.subheadline)
                    }
                }
            }
            .sheet(item: $editingWorkspace) { workspace in
                WorkspaceEditView(workspace: workspace)
            }
            .task { await loadWorkspaces() }
            .overlay {
                if isCreating {
                    ProgressView("Creating session…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func loadWorkspaces() async {
        await connection.refreshWorkspaceCatalog(force: false)
    }

    private func createSession(workspace: Workspace) async {
        guard let api = connection.apiClient else { return }
        isCreating = true
        error = nil

        do {
            let session = try await api.createWorkspaceSession(workspaceId: workspace.id)
            sessionStore.upsert(session)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}

// MARK: - Workspace Card

private struct WorkspaceCard: View {
    let workspace: Workspace
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                WorkspaceIcon(icon: workspace.icon, size: 36)

                Text(workspace.name)
                    .font(.headline)
                    .lineLimit(1)

                RuntimeBadge(runtime: workspace.runtime)

                if let description = workspace.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                SkillCountBadge(count: workspace.skills.count)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(borderColor, lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
    private var backgroundFill: Color {
        workspace.isContainerRuntime
            ? Color.tokyoGreen.opacity(0.12)
            : Color.tokyoOrange.opacity(0.14)
    }

    private var borderColor: Color {
        workspace.isContainerRuntime
            ? Color.tokyoGreen.opacity(0.55)
            : Color.tokyoOrange.opacity(0.65)
    }
}

// MARK: - Shared Components

/// Displays a workspace icon as either an SF Symbol or emoji.
///
/// SF Symbol names match `[a-z0-9]+(\.[a-z0-9]+)*` — anything else
/// (like emoji) is rendered as text.
struct WorkspaceIcon: View {
    let icon: String?
    let size: CGFloat

    /// Whether the icon string looks like an SF Symbol name.
    private var isSFSymbol: Bool {
        guard let icon, !icon.isEmpty else { return false }
        return icon.allSatisfy { $0.isASCII }
    }

    var body: some View {
        if let icon, !icon.isEmpty {
            if isSFSymbol {
                Image(systemName: icon)
                    .font(.system(size: size))
                    .foregroundStyle(.tokyoBlue)
            } else {
                Text(icon)
                    .font(.system(size: size))
            }
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: size))
                .foregroundStyle(.tokyoBlue)
        }
    }
}

struct RuntimeBadge: View {
    let runtime: String?
    var compact: Bool = false

    private var normalizedRuntime: String {
        switch runtime {
        case "container": return "container"
        case "host": return "host"
        default: return "unknown"
        }
    }

    private var icon: String {
        switch normalizedRuntime {
        case "container":
            return "shippingbox.fill"
        case "host":
            if UIImage(systemName: "macstudio.fill") != nil {
                return "macstudio.fill"
            }
            return "desktopcomputer"
        default:
            return "questionmark.circle.fill"
        }
    }

    private var accessibilityLabel: String {
        switch normalizedRuntime {
        case "container": return "Container runtime"
        case "host": return "Host runtime"
        default: return "Unknown runtime"
        }
    }

    private var fg: Color {
        switch normalizedRuntime {
        case "container": return .tokyoGreen
        case "host": return .tokyoOrange
        default: return .tokyoComment
        }
    }

    private var bg: Color {
        switch normalizedRuntime {
        case "container": return .tokyoGreen.opacity(0.18)
        case "host": return .tokyoOrange.opacity(0.22)
        default: return .tokyoComment.opacity(0.18)
        }
    }

    private var border: Color {
        switch normalizedRuntime {
        case "container": return .tokyoGreen.opacity(0.72)
        case "host": return .tokyoOrange.opacity(0.78)
        default: return .tokyoComment.opacity(0.5)
        }
    }

    private var badgeSize: CGFloat {
        compact ? 20 : 24
    }

    private var symbolSize: CGFloat {
        compact ? 10 : 12
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(bg)

            Circle()
                .stroke(border, lineWidth: 1)

            if normalizedRuntime == "container" {
                Circle()
                    .stroke(Color.tokyoGreen.opacity(0.35), lineWidth: 1)
                    .padding(2)
            }

            Image(systemName: icon)
                .font(.system(size: symbolSize, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(fg)
        }
        .frame(width: badgeSize, height: badgeSize)
        .shadow(
            color: normalizedRuntime == "container" ? Color.tokyoGreen.opacity(0.35) : .clear,
            radius: normalizedRuntime == "container" ? 4 : 0
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Runtime icon with a small status dot overlay in the bottom-trailing corner.
/// Used in the ChatView navigation bar to show runtime + session + sync state.
struct RuntimeStatusBadge: View {
    enum SyncState {
        case live
        case syncing
        case offline
        case stale

        var accessibilityText: String {
            switch self {
            case .live: return "Live"
            case .syncing: return "Syncing"
            case .offline: return "Offline"
            case .stale: return "Stale"
            }
        }
    }

    let runtime: String?
    let statusColor: Color
    var syncState: SyncState = .live

    private var dotFillColor: Color {
        syncState == .offline ? .tokyoComment : statusColor
    }

    private var dotRingColor: Color {
        switch syncState {
        case .live: return .tokyoBg
        case .syncing: return .tokyoBlue
        case .offline: return .tokyoRed
        case .stale: return .tokyoOrange
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RuntimeBadge(runtime: runtime, compact: true)

            Circle()
                .fill(dotFillColor)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(dotRingColor, lineWidth: 1.5)
                )
                .offset(x: 2, y: 2)
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel("\(syncState.accessibilityText) runtime status")
    }
}

extension RuntimeStatusBadge.SyncState {
    init(_ freshness: FreshnessState) {
        switch freshness {
        case .live:
            self = .live
        case .syncing:
            self = .syncing
        case .offline:
            self = .offline
        case .stale:
            self = .stale
        }
    }
}

/// Small badge showing skill count.
private struct SkillCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count) skill\(count == 1 ? "" : "s")")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
