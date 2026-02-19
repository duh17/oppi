import SwiftUI

/// Fetches available themes from the server and lets the user import + apply them.
struct ThemeImportView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss

    @State private var remoteThemes: [RemoteThemeSummary] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var importingName: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Fetching themes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if remoteThemes.isEmpty {
                ContentUnavailableView(
                    "No Custom Themes",
                    systemImage: "paintbrush",
                    description: Text("No themes found on server.\nAsk the agent to create one!")
                )
            } else {
                themeList
            }
        }
        .navigationTitle("Import Theme")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadThemes() }
    }

    private var themeList: some View {
        List {
            ForEach(remoteThemes) { summary in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name)
                            .font(.body.weight(.medium))
                        Text(summary.colorScheme)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }

                    Spacer()

                    if importingName == summary.filename {
                        ProgressView()
                            .controlSize(.small)
                    } else if CustomThemeStore.load(name: summary.name) != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.themeGreen)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await importTheme(summary) }
                }
            }
        }
    }

    private func loadThemes() async {
        guard let api = connection.apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }
        do {
            remoteThemes = try await api.listThemes()
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func importTheme(_ summary: RemoteThemeSummary) async {
        guard let api = connection.apiClient else { return }
        importingName = summary.filename
        do {
            let theme = try await api.getTheme(name: summary.filename)
            guard theme.toPalette() != nil else {
                importingName = nil
                return
            }
            CustomThemeStore.save(theme)
            themeStore.selectedThemeID = .custom(theme.name)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            importingName = nil
        } catch {
            importingName = nil
        }
    }
}
