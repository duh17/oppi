import SwiftUI

struct SettingsAppearancePage: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        List {
            Section {
                Picker("Theme Source", selection: Binding(
                    get: { themeStore.mode },
                    set: { themeStore.mode = $0 }
                )) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } footer: {
                Text(themeStore.mode.detail)
            }

            Section {
                if themeStore.mode == .manual {
                    themePicker("Theme", selection: Binding(
                        get: { themeStore.manualThemeID },
                        set: { themeStore.manualThemeID = $0 }
                    ), matching: nil)
                } else {
                    themePicker("Light Theme", selection: Binding(
                        get: { themeStore.lightThemeID },
                        set: { themeStore.lightThemeID = $0 }
                    ), matching: .light)

                    themePicker("Dark Theme", selection: Binding(
                        get: { themeStore.darkThemeID },
                        set: { themeStore.darkThemeID = $0 }
                    ), matching: .dark)
                }
            } footer: {
                if themeStore.mode == .manual {
                    if !themeStore.manualThemeID.detail.isEmpty {
                        Text(themeStore.manualThemeID.detail)
                    }
                } else {
                    Text("Uses your iOS Display & Brightness setting, including Apple's automatic schedule.")
                }
            }

            Section {
                SettingsIndexActionRow {
                    navigator.push { ThemeImportView() }
                } label: {
                    Text("Custom Themes")
                }
                .accessibilityLabel("Custom Themes")
                .accessibilityIdentifier("settings.appearance.customThemes")
            } footer: {
                Text(
                    "Import themes from your server, or describe a new one and Oppi writes it. Themes are JSON files in the Oppi data directory (usually ~/.config/oppi/themes); Pi TUI themes in ~/.pi/agent/themes are converted automatically."
                )
            }
        }
        .settingsPage("Appearance")
    }

    @ViewBuilder
    private func themePicker(
        _ title: String,
        selection: Binding<ThemeID>,
        matching scheme: ColorScheme?
    ) -> some View {
        Picker(title, selection: selection) {
            let themes = ThemeID.pickerThemes(matching: scheme)
            let builtins = themes.filter { !$0.isImported }
            let imported = themes.filter(\.isImported)
            Section("Built-in") {
                ForEach(builtins, id: \.self) { themeID in
                    Text(themeID.displayName).tag(themeID)
                }
            }
            if !imported.isEmpty {
                Section("Imported") {
                    ForEach(imported, id: \.self) { themeID in
                        Text(themeID.displayName).tag(themeID)
                    }
                }
            }
        }
    }
}
