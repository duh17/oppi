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
    private let systemImage: String
    private let value: String?
    private let destination: Destination

    init(
        _ title: String,
        systemImage: String,
        value: String? = nil,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.systemImage = systemImage
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
                SettingsRowLabel(title, systemImage: systemImage)
            }
        }
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

/// A level-1 row whose push must go through app-owned navigation (a tracked
/// route) instead of a `NavigationLink`. It is a plain `Button` laid out like
/// `SettingsIndexRow`: same label and value placement, with the system
/// chevron drawn in the value column.
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
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            } label: {
                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
