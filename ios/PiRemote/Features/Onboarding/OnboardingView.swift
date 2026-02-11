import SwiftUI
import VisionKit

struct OnboardingView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation

    @State private var showScanner = false
    @State private var showManualEntry = false
    @State private var connectionTest: ConnectionTestState = .idle

    /// VisionKit scanner requires camera + on-device ML support.
    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                Text("Pi Remote")
                    .font(.largeTitle.bold())

                Text("Control your pi agents\nfrom your phone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 16) {
                switch connectionTest {
                case .idle:
                    if canScan {
                        Button("Scan QR Code") {
                            showScanner = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    if canScan {
                        Button("Enter manually") {
                            showManualEntry = true
                        }
                        .font(.subheadline)
                    } else {
                        Button("Connect to Server") {
                            showManualEntry = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                case .testing:
                    ProgressView("Testing connection…")

                case .success:
                    Label("Connected!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)

                case .failed(let error):
                    VStack(spacing: 8) {
                        Label("Connection failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Try Again") {
                            if canScan {
                                showScanner = true
                            } else {
                                showManualEntry = true
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showScanner) {
            QRScannerView { credentials in
                showScanner = false
                Task { await testConnection(credentials) }
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualEntryView { credentials in
                showManualEntry = false
                Task { await testConnection(credentials) }
            }
        }
    }

    private func testConnection(_ credentials: ServerCredentials) async {
        connectionTest = .testing

        // Validate URL before attempting connection
        guard let baseURL = URL(string: "http://\(credentials.host):\(credentials.port)") else {
            connectionTest = .failed("Invalid server address: \(credentials.host):\(credentials.port)")
            return
        }

        let api = APIClient(baseURL: baseURL, token: credentials.token)

        do {
            let healthy = try await api.health()
            guard healthy else {
                connectionTest = .failed("Server is not healthy")
                return
            }

            let profile: ServerSecurityProfile?
            do {
                profile = try await api.securityProfile()
            } catch {
                if credentials.inviteVersion == 2 {
                    connectionTest = .failed("Server is missing security profile endpoint required for signed invite trust")
                    return
                }
                profile = nil
            }

            if let profile {
                if let violation = ConnectionSecurityPolicy.evaluate(host: credentials.host, profile: profile) {
                    connectionTest = .failed(violation.localizedDescription)
                    return
                }

                if let inviteMismatch = inviteMismatchReason(credentials: credentials, profile: profile) {
                    connectionTest = .failed(inviteMismatch)
                    return
                }
            }

            // Confirm bearer token is valid after trust checks.
            _ = try await api.me()

            let existing = KeychainService.loadCredentials()
            let sameTarget = isSameServer(existing, credentials)
            let existingFingerprint = existing?.normalizedServerFingerprint
            let profileFingerprint = profile?.identity.normalizedFingerprint
            let requiresTrustReset = sameTarget
                && existingFingerprint != nil
                && profileFingerprint != nil
                && existingFingerprint != profileFingerprint

            let requiresPinnedTrust = (profile?.requirePinnedServerIdentity ?? false) && profileFingerprint != nil
            let requiresInviteTrust = credentials.inviteVersion == 2 && credentials.normalizedServerFingerprint != nil

            if requiresTrustReset || requiresPinnedTrust || requiresInviteTrust {
                let reason: String
                if requiresTrustReset {
                    reason = "Server identity changed for \(credentials.host). Confirm trust reset."
                } else {
                    let displayFingerprint = profileFingerprint ?? credentials.normalizedServerFingerprint ?? "unknown"
                    reason = "Trust \(credentials.host) (\(shortFingerprint(displayFingerprint)))"
                }

                let trusted = await BiometricService.shared.authenticate(reason: reason)
                guard trusted else {
                    connectionTest = .failed("Trust confirmation cancelled")
                    return
                }
            }

            let effectiveCredentials = profile.map(credentials.applyingSecurityProfile) ?? credentials

            // Save credentials and transition
            try KeychainService.saveCredentials(effectiveCredentials)
            guard connection.configure(credentials: effectiveCredentials) else {
                connectionTest = .failed("Connection blocked by server transport policy")
                return
            }

            // Load sessions
            connection.sessionStore.markSyncStarted()
            let sessions = try await api.listSessions()
            connection.sessionStore.applyServerSnapshot(sessions)
            connection.sessionStore.markSyncSucceeded()

            connectionTest = .success

            // Short delay then transition
            try? await Task.sleep(for: .milliseconds(600))
            navigation.showOnboarding = false
        } catch {
            connection.sessionStore.markSyncFailed()
            connectionTest = .failed(error.localizedDescription)
        }
    }

    private func inviteMismatchReason(
        credentials: ServerCredentials,
        profile: ServerSecurityProfile
    ) -> String? {
        guard credentials.inviteVersion == 2 else { return nil }

        let inviteFingerprint = credentials.normalizedServerFingerprint
        let profileFingerprint = profile.identity.normalizedFingerprint

        if let inviteFingerprint,
           let profileFingerprint,
           inviteFingerprint != profileFingerprint {
            return "Signed invite fingerprint mismatch. Refusing connection."
        }

        if let inviteKeyId = credentials.inviteKeyId,
           !inviteKeyId.isEmpty,
           inviteKeyId != profile.identity.keyId {
            return "Signed invite key mismatch (kid changed). Refusing connection."
        }

        if let inviteProfile = credentials.securityProfile,
           !inviteProfile.isEmpty,
           inviteProfile != profile.profile {
            return "Signed invite profile mismatch. Refusing connection."
        }

        return nil
    }

    private func isSameServer(_ lhs: ServerCredentials?, _ rhs: ServerCredentials) -> Bool {
        guard let lhs else { return false }
        return lhs.port == rhs.port && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
    }

    private func shortFingerprint(_ fingerprint: String) -> String {
        if fingerprint.count > 24 {
            return String(fingerprint.prefix(24)) + "…"
        }
        return fingerprint
    }
}

private enum ConnectionTestState {
    case idle
    case testing
    case success
    case failed(String)
}

// MARK: - Manual Entry

private struct ManualEntryView: View {
    let onConnect: (ServerCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "7749"
    @State private var token = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Host (e.g. mac-studio.local)", text: $host)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Auth") {
                    SecureField("Token", text: $token)
                        .textContentType(.password)
                    TextField("Name", text: $name)
                }
            }
            .navigationTitle("Connect Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        let creds = ServerCredentials(
                            host: host,
                            port: Int(port) ?? 7749,
                            token: token,
                            name: name
                        )
                        onConnect(creds)
                    }
                    .disabled(host.isEmpty || token.isEmpty)
                }
            }
        }
    }
}
