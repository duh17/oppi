import SwiftUI

/// Lists server themes: tap to import and apply, edit one with an Oppi control
/// session, or describe a new one in the composer, as Agents and Schedules do.
struct ThemeImportView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ThemeStore.self) private var themeStore

    @State private var remoteThemes: [RemoteThemeSummary] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var importingName: String?
    @State private var removingTheme: RemoteThemeSummary?
    @State private var revisingTheme: RemoteThemeSummary?

    var body: some View {
        List {
            if isLoading && remoteThemes.isEmpty {
                ProgressView("Fetching themes…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if remoteThemes.isEmpty {
                if let error {
                    ContentUnavailableView(
                        "Unable to Load Themes",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView(
                        "No Custom Themes",
                        systemImage: "paintpalette",
                        description: Text("Describe a theme below and Oppi writes it to your server.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(remoteThemes) { summary in
                        themeRow(summary)
                    }
                } footer: {
                    Text("Tap a theme to import and apply it. Swipe or touch and hold to edit it with Oppi.")
                }
            }
        }
        .settingsPage("Custom Themes")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let error, !remoteThemes.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .accessibilityIdentifier("themes.error")
                }

                GuidedControlSessionComposer(
                    domain: .themes,
                    intent: .create,
                    placeholder: "Describe a new theme…"
                )
            }
        }
        .refreshable { await loadThemes() }
        .task { await loadThemes() }
        .routerModal(item: $revisingTheme, presentation: .sheet.inNavigation()) { summary in
            GuidedControlSessionSheet(
                domain: .themes,
                intent: .revise,
                targetId: summary.filename,
                targetName: summary.name,
                targetPath: summary.path,
                placeholder: "Describe how this theme should change…"
            )
        }
        .confirmationDialog(
            removingTheme.map { "Delete \($0.name) from this device?" } ?? "Delete Theme",
            isPresented: Binding(
                get: { removingTheme != nil },
                set: { if !$0 { removingTheme = nil } }
            ),
            titleVisibility: .visible,
            presenting: removingTheme
        ) { summary in
            Button("Delete Theme", role: .destructive) {
                themeStore.removeImportedTheme(named: summary.name)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The imported copy is removed. You can import it again from the server.")
        }
    }

    private func themeRow(_ summary: RemoteThemeSummary) -> some View {
        let isImported = CustomThemeStore.load(name: summary.name) != nil
        return Button {
            Task { await importTheme(summary) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .foregroundStyle(.themeFg)
                    Text(summary.colorScheme)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }

                Spacer()

                if importingName == summary.filename {
                    ProgressView()
                        .controlSize(.small)
                } else if isImported {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.themeGreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("themes.row.\(summary.filename)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isImported {
                Button("Delete from Device", systemImage: "trash", role: .destructive) {
                    removingTheme = summary
                }
            }
            Button("Edit with Oppi", systemImage: "text.bubble") {
                revisingTheme = summary
            }
            .tint(.themeBlue)
            .accessibilityIdentifier("themes.row.\(summary.filename).swipeEdit")
        }
        .contextMenu {
            Button("Edit with Oppi", systemImage: "text.bubble") {
                revisingTheme = summary
            }
            .accessibilityIdentifier("themes.row.\(summary.filename).edit")
            if isImported {
                Button("Delete from Device", systemImage: "trash", role: .destructive) {
                    removingTheme = summary
                }
            }
        }
    }

    @MainActor
    private func loadThemes() async {
        guard let api = apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            remoteThemes = try await api.listThemes()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importTheme(_ summary: RemoteThemeSummary) async {
        guard let api = apiClient else { return }
        importingName = summary.filename
        do {
            let theme = try await api.getTheme(name: summary.filename)
            guard theme.toPalette() != nil else {
                importingName = nil
                return
            }
            CustomThemeStore.save(theme)
            themeStore.selectedThemeID = .custom(theme.name)
            AppHaptics.success()
            importingName = nil
        } catch {
            importingName = nil
        }
    }
}
