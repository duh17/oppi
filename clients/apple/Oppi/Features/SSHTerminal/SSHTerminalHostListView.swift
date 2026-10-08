import SwiftUI

enum SSHTerminalEditorRoute: Hashable, Identifiable {
    case add
    case edit(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let id): "edit-\(id.uuidString)"
        }
    }

    var profileID: UUID? {
        if case .edit(let id) = self { return id }
        return nil
    }
}

/// Device-local host list. Row tap connects. Edit and Add open the setup form.
/// Appearing loads defaults only: it does not dial and does not read the Keychain.
struct SSHTerminalHostListView: View {
    @AppStorage(AppPreferences.Experiments.sshTerminalKey) private var experimentEnabled = false
    @State private var profiles: [SSHTerminalProfile] = []
    @State private var editor: SSHTerminalEditorRoute?
    @State private var editAfterTerminal: UUID?
    @State private var connectingProfile = SSHTerminalProfile()
    @State private var session = SSHTerminalConnectSession()
    @State private var metadataIsCorrupt = false
    @State private var pendingDelete: SSHTerminalProfile?
    @State private var confirmingLegacyPasswordDelete = false

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
                    Button("Add Host") { editor = .add }
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
                    Button("Delete Saved Password", role: .destructive) { confirmingLegacyPasswordDelete = true }
                        .accessibilityIdentifier("sshTerminal.deleteLegacyPassword")
                }
            }
        }
        .accessibilityIdentifier("sshTerminal.hostList")
        .settingsPage("SSH Terminal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Host", systemImage: "plus") { editor = .add }
                    .accessibilityIdentifier("sshTerminal.host.add")
            }
        }
        .navigationDestination(item: $editor) { route in
            SSHTerminalSetupView(profileID: route.profileID)
        }
        .sshTerminalConnection(
            session: session, profile: $connectingProfile, experimentEnabled: experimentEnabled,
            editHost: editConnectedHost,
            submitPassword: { connect(connectingProfile, password: $0) }
        )
        .onAppear { reload() }
        .onChange(of: editor) { _, route in if route == nil { reload() } }
        .onChange(of: session.showsTerminal) { _, visible in
            guard !visible, let id = editAfterTerminal else { return }
            editAfterTerminal = nil
            editor = .edit(id)
        }
        .confirmationDialog(
            "Delete the saved password?",
            isPresented: $confirmingLegacyPasswordDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Saved Password", role: .destructive) { deleteLegacyPassword() }
        } message: {
            Text("The saved host data cannot be read. This removes the old saved password and the unreadable host data.")
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
            Button("Edit") { editor = .edit(profile.id) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("sshTerminal.host.edit.\(profile.id.uuidString)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete Host", role: .destructive) { pendingDelete = profile }
                .accessibilityIdentifier("sshTerminal.host.delete")
        }
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

    /// Corrupt metadata cannot name per-profile accounts. Delete only the
    /// legacy password item, then drop undecodable defaults. Do not scan.
    private func deleteLegacyPassword() {
        do {
            try SSHTerminalProfileStore().deleteLegacyPasswordItem()
            SSHTerminalProfileStore().discardCorruptMetadata()
            reload()
        } catch {
            session.failure = error.localizedDescription
        }
    }

    private func reload() {
        let store = SSHTerminalProfileStore()
        metadataIsCorrupt = store.metadataIsCorrupt
        profiles = store.load()
        if metadataIsCorrupt { profiles = [] }
    }
}
