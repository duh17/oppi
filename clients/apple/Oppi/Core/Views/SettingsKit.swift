import SwiftUI

// Shared vocabulary for settings-like pages: App, Server, and Workspace
// Settings. Holds no store or connection references so it can
// live in Core/Views; pages pass explicit values.

extension View {
    /// Container for every settings page: inset-grouped list on the themed
    /// surface, readable width on iPad, and a navigation title. Pushed section
    /// pages use `.inline`. Nil leaves the title size to the screen's host: the
    /// Settings root the router hosts with a large title (`ScreenBars.largeTitle`),
    /// which stays inline on the Duo's vertical rail, where SwiftUI's `.large`
    /// would show no title.
    @ViewBuilder
    func settingsPage(
        _ title: String,
        titleDisplayMode: NavigationBarItem.TitleDisplayMode? = .inline
    ) -> some View {
        let page = listStyle(.insetGrouped)
            .themedListSurface()
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
            .navigationTitle(title)
        if let titleDisplayMode {
            page.navigationBarTitleDisplayMode(titleDisplayMode)
        } else {
            page
        }
    }
}

/// A level-1 settings row: a plain theme-colored symbol, a Title Case title,
/// and an optional secondary current-value summary. Tapping pushes
/// `destination` through the screen navigator. The page is its own hosted
/// screen with the app root's services; a presenter-local value it needs
/// (a server scope, a model) goes on the destination explicitly. The closure
/// runs in the pushed screen, so `@Observable` reads in it stay live.
struct SettingsIndexRow<Destination: View>: View {
    private let title: String
    private let systemImage: String
    private let value: String?
    private let destination: () -> Destination

    @Environment(\.screenNavigator) private var navigator

    init(
        _ title: String,
        systemImage: String,
        value: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.destination = destination
    }

    var body: some View {
        SettingsIndexActionRow(value: value) {
            navigator.push(content: destination)
        } label: {
            SettingsRowLabel(title, systemImage: systemImage)
        }
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
    }
}

/// Title and theme-colored symbol shared by every level-1 row.
struct SettingsRowLabel: View {
    private let title: String
    private let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.themeBlue)
        }
    }
}

/// The system-style disclosure chevron for a row whose push goes through
/// app-owned navigation, drawn by `SettingsIndexActionRow`.
struct SettingsDisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A row that pushes through app-owned navigation: a screen navigator push
/// (`SettingsIndexRow`) or a tracked `AppNavigation` route. It is a plain
/// `Button` laid out like a list disclosure row: label leading, value and the
/// system chevron in the value column.
///
/// Callers set the accessibility label, value, and identifier.
struct SettingsIndexActionRow<Label: View>: View {
    private let value: String?
    private let valueStyle: ThemeShapeStyle
    private let action: () -> Void
    private let label: Label

    init(
        value: String? = nil,
        valueStyle: ThemeShapeStyle = .themeComment,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.value = value
        self.valueStyle = valueStyle
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 8) {
                    if let value {
                        Text(value)
                            .foregroundStyle(valueStyle)
                            .lineLimit(1)
                    }
                    SettingsDisclosureChevron()
                }
            } label: {
                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
