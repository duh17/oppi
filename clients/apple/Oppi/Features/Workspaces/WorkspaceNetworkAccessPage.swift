import SwiftUI

/// Allowed Hosts of a sandbox workspace. The text is a draft: Save writes it,
/// back discards it. The write carries the sandbox's other config unchanged.
struct WorkspaceNetworkAccessPage: View {
    let model: WorkspaceSettingsModel

    @Environment(\.dismiss) private var dismiss

    @State private var hostsText: String
    @State private var error: String?
    /// A save that finishes after Back must not pop whatever is on top now.
    @State private var isVisible = true

    init(model: WorkspaceSettingsModel) {
        self.model = model
        _hostsText = State(initialValue: Self.text(for: model.workspace.sandboxConfig?.allowedHosts))
    }

    /// An omitted list allows all, like Gondolin's default.
    private static func text(for hosts: [String]?) -> String {
        (hosts ?? ["*"]).joined(separator: "\n")
    }

    private var draftHosts: [String] {
        hostsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var isDirty: Bool {
        draftHosts != (model.workspace.sandboxConfig?.allowedHosts ?? ["*"])
    }

    var body: some View {
        List {
            Section {
                TextEditor(text: $hostsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .themedTextInputCard()
                    .accessibilityIdentifier("workspace.edit.allowedHosts")
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Allowed Hosts")
            } footer: {
                Text("This workspace runs in a sandboxed micro-VM. One host pattern per line. Leave empty to deny all network. Use * to allow all, matching Gondolin\u{2019}s default.")
            }

            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.themeRed)
                        .accessibilityIdentifier("workspace.edit.networkAccess.error")
                }
            }
        }
        .settingsPage("Network Access")
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!isDirty || model.isWritingSandboxConfig)
                .accessibilityIdentifier("workspace.edit.networkAccess.save")
            }
        }
    }

    private func save() async {
        error = nil
        switch await model.saveAllowedHosts(draftHosts) {
        case .saved:
            if isVisible { dismiss() }
        case .failed(let message):
            error = message
        case .superseded:
            break
        }
    }
}
