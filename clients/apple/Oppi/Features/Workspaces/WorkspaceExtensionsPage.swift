import SwiftUI

/// Oppi and Pi extensions for one workspace, one toggle each. A toggle writes
/// Pi settings at once; the list shows the server's answer after the write.
struct WorkspaceExtensionsPage: View {
    let model: WorkspaceSettingsModel

    private var oppiExtensions: [ExtensionInfo] { model.extensions.filter(\.isOppi) }
    private var piExtensions: [ExtensionInfo] { model.extensions.filter { !$0.isOppi } }

    var body: some View {
        List {
            if model.isLoadingExtensions && model.extensions.isEmpty {
                Section {
                    Text("Loading extensions\u{2026}")
                        .foregroundStyle(.themeComment)
                }
            } else {
                if !oppiExtensions.isEmpty {
                    Section("Oppi Extensions") {
                        ForEach(oppiExtensions) { ext in
                            row(ext)
                        }
                    }
                }

                Section {
                    if piExtensions.isEmpty {
                        Text("No Pi extensions found.")
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(piExtensions) { ext in
                            row(ext)
                        }
                    }

                    if let extensionsError = model.extensionsError {
                        Text(extensionsError)
                            .font(.caption2)
                            .foregroundStyle(.themeOrange)
                            .accessibilityIdentifier("workspace.edit.extensions.error")
                    }
                } header: {
                    Text("Pi Extensions")
                } footer: {
                    Text(model.piResourceFooter)
                }
            }
        }
        .settingsPage("Extensions")
        .task {
            await model.loadPiResourcesIfNeeded()
        }
    }

    private func row(_ ext: ExtensionInfo) -> some View {
        let isEnabled = model.displayedEnabled(.extensions, path: ext.path, server: ext.enabled)
        let isPending = model.isPending(.extensions, path: ext.path)
        return Toggle(
            isOn: Binding(
                get: { isEnabled },
                set: { enabled in
                    Task { await model.setPiResource(.extensions, path: ext.path, enabled: enabled) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(ext.name)
                        .foregroundStyle(isEnabled ? .themeFg : .themeComment)
                    if isPending {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(ext.subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }
        }
        .disabled(isPending || !model.canTogglePiResources)
        .accessibilityIdentifier("workspace.edit.extension.\(ext.name)")
    }
}
