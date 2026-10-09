import SwiftUI
import UIKit

struct SettingsAppearancePage: View {
    @Environment(ThemeStore.self) private var themeStore
    @State private var copiedThemePrompt = false

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
                NavigationLink("Custom Themes…") {
                    ThemeImportView()
                }
                .accessibilityIdentifier("settings.appearance.customThemes")

                Button("Create a Theme with Your Agent") {
                    UIPasteboard.general.string = Self.themeCreationPrompt
                    copiedThemePrompt = true
                }
                .accessibilityIdentifier("settings.appearance.createTheme")
            } header: {
                Text("Custom Themes")
            } footer: {
                Text(
                    "Themes are JSON files on your server (`themes` in the Oppi data directory, usually ~/.config/oppi/themes). Pi TUI themes in ~/.pi/agent/themes are converted automatically. You can ask your agent to create one."
                )
            }
        }
        .settingsPage("Appearance")
        .alert("Prompt Copied", isPresented: $copiedThemePrompt) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Paste it into a chat to have your agent write a theme file.")
        }
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

    /// Clipboard prompt for Settings → Appearance → Create a Theme with Your Agent.
    static let themeCreationPrompt = """
    Create an Oppi iOS theme JSON file.

    Where to write it
    - Server themes: `$OPPI_DATA_DIR/themes/` if set, otherwise `~/.config/oppi/themes/`
    - Filename: letters, numbers, underscore, hyphen; ends with .json
    - Pi TUI themes in `~/.pi/agent/themes/` are converted automatically; prefer Oppi JSON unless you are making a TUI theme

    Format and tokens
    - Read docs/themes.md in the Oppi repo (public user docs). It lists every token and what it paints.
    - Required: name, colorScheme ("dark" or "light"), and the color tokens in that doc
    - User card: userMessageBg (fill) and userMessageText (text); assistant replies stay full width
    - Optional: assistantMessageBg (assistant row fill; omit or empty for no fill), userMessageAccent (3 pt leading strip on user cards; omit or empty for no strip)
    - Contrast: text on fills ≥ 4.5:1; userMessageAccent, when set, at least 3:1 against bg

    After writing the file, tell me the theme name so I can import it in Settings → Appearance → Custom Themes.
    """
}
