import SwiftUI

// Shared vocabulary for settings-like pages: App Settings today, Server and
// Workspace settings next. Holds no store or connection references so it can
// live in Core/Views; pages pass explicit values.

extension View {
    /// Container for every settings page: inset-grouped list on the themed
    /// surface, readable width on iPad, and a navigation title. The root of a
    /// settings area uses `.large`; pushed section pages use `.inline`.
    func settingsPage(
        _ title: String,
        titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline
    ) -> some View {
        listStyle(.insetGrouped)
            .themedListSurface()
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(titleDisplayMode)
    }
}

/// A level-1 settings row: a real `NavigationLink` with a plain theme-colored
/// symbol, a Title Case title, and an optional secondary current-value summary.
struct SettingsIndexRow<Destination: View>: View {
    private let title: String
    private let icon: Image
    private let value: String?
    private let destination: Destination

    init(
        _ title: String,
        systemImage: String,
        value: String? = nil,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.icon = Image(systemName: systemImage)
        self.value = value
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            LabeledContent {
                if let value {
                    Text(value)
                        .foregroundStyle(.themeComment)
                }
            } label: {
                Label {
                    Text(title)
                } icon: {
                    icon
                        .foregroundStyle(.themeBlue)
                }
            }
        }
    }
}
