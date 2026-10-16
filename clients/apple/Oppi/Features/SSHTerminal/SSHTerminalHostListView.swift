import SwiftUI

/// Device-local host list. Row tap connects. Edit and Add push the setup form.
/// Appearing loads defaults only: it does not dial and does not read the Keychain.
/// Coming back from the form or the terminal reloads the list.
struct SSHTerminalHostListView: View {
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var experimentEnabled = false
    @Environment(\.screenNavigator) private var navigator
    @State private var profiles: [SSHTerminalProfile] = []
    @State private var editAfterTerminal: UUID?
    @State private var connectingProfile = SSHTerminalProfile()
    @State private var session = SSHTerminalConnectSession()
    @State private var metadataIsCorrupt = false
    @State private var pendingDelete: SSHTerminalProfile?
    @State private var confirmingReset = false

    var body: some View {
        List {
            if metadataIsCorrupt {
                Section {
                    Text(SSHTerminalProfileStoreError.corruptMetadata.localizedDescription)
                }
            }
            if session.connecting || session.failure != nil || session.hostFailure != nil {
                Section {
                    if session.connecting {
                        SSHTerminalConnectProgress(savingHostOnly: session.savingHostOnly) { session.cancel() }
                    }
                    if let failure = session.failure {
                        Text("Disconnected — \(failure)").foregroundStyle(.themeRed)
                            .accessibilityIdentifier("sshTerminal.failure")
                    }
                    SSHTerminalTrustRows(
                        hostFailure: session.hostFailure, connecting: session.connecting,
                        trust: { session.trustAndConnect(profile: connectingProfile, experimentEnabled: experimentEnabled, onSaved: { _ in reload() }) },
                        requestForget: { session.forgetConfirmation = true }
                    )
                }
            }
            if profiles.isEmpty && !metadataIsCorrupt {
                Section {
                    Text("No saved hosts.")
                        .foregroundStyle(.themeComment)
                    Button("Add Host") { openEditor(profileID: nil) }
                        .accessibilityIdentifier("sshTerminal.host.add")
                }
            } else if !profiles.isEmpty {
                Section {
                    ForEach(profiles) { profile in
                        hostRow(profile)
                    }
                }
            }
            if metadataIsCorrupt {
                Section {
                    Button("Reset Host List", role: .destructive) { confirmingReset = true }
                        .accessibilityIdentifier("sshTerminal.resetHostList")
                }
            }
        }
        .accessibilityIdentifier("sshTerminal.hostList")
        .settingsPage("SSH Terminal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Host", systemImage: "plus") { openEditor(profileID: nil) }
                    .accessibilityIdentifier("sshTerminal.host.add")
            }
        }
        .sshTerminalConnection(
            session: session, profile: $connectingProfile, experimentEnabled: experimentEnabled,
            editHost: editConnectedHost,
            submitPassword: { connect(connectingProfile, password: $0) }
        )
        .onAppear { reload() }
        .onChange(of: session.showsTerminal) { _, visible in
            guard !visible, let id = editAfterTerminal else { return }
            editAfterTerminal = nil
            openEditor(profileID: id)
        }
        .confirmationDialog(
            "Reset the host list?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Host List", role: .destructive) { resetHostList() }
        } message: {
            Text("The saved host data cannot be read. This removes it so you can add your hosts again.")
        }
        .confirmationDialog(
            "Delete this host and its saved password?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("Delete Host", role: .destructive) {
                pendingDelete = nil
                delete(profile)
            }
        }
    }

    private func hostRow(_ profile: SSHTerminalProfile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                connect(profile)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.endpointLabel)
                    if let port = profile.portLabel {
                        Text(port).font(.subheadline).foregroundStyle(.themeComment)
                    }
                    Text(profile.startupLabel)
                        .font(.subheadline).foregroundStyle(.themeComment).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(session.connecting || session.passwordPrompt)
            .accessibilityIdentifier("sshTerminal.host.row.\(profile.id.uuidString)")
            .accessibilityHint("Connect")
            Button("Edit") { openEditor(profileID: profile.id) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("sshTerminal.host.edit.\(profile.id.uuidString)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete Host", role: .destructive) { pendingDelete = profile }
                .accessibilityIdentifier("sshTerminal.host.delete")
        }
    }

    /// The setup form: a new host when `profileID` is nil.
    private func openEditor(profileID: UUID?) {
        navigator.push { SSHTerminalSetupView(profileID: profileID) }
    }

    private func connect(_ profile: SSHTerminalProfile, password: String? = nil) {
        connectingProfile = profile.normalized()
        session.connect(profile: connectingProfile, suppliedPassword: password, experimentEnabled: experimentEnabled) { _ in
            reload()
        }
    }

    private func editConnectedHost() {
        if let id = session.connectedProfile?.id { editAfterTerminal = id }
        session.showsTerminal = false
    }

    private func delete(_ profile: SSHTerminalProfile) {
        do {
            if session.connectedProfile?.id == profile.id { session.cancel() }
            try SSHTerminalProfileStore().delete(id: profile.id)
            reload()
        } catch {
            session.failure = error.localizedDescription
        }
    }

    /// Corrupt metadata cannot name per-profile password accounts, so this
    /// drops only the unreadable defaults value. It does not scan the Keychain.
    private func resetHostList() {
        SSHTerminalProfileStore().discardCorruptMetadata()
        reload()
    }

    private func reload() {
        let store = SSHTerminalProfileStore()
        metadataIsCorrupt = store.metadataIsCorrupt
        profiles = store.load()
        if metadataIsCorrupt { profiles = [] }
    }
}
