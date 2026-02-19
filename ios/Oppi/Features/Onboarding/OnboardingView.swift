import SwiftUI
import VisionKit

/// Mode for the onboarding flow.
enum OnboardingMode {
    /// First-time setup or re-launch with no servers.
    case initial
    /// Adding an additional server from Settings.
    case addServer
}

struct OnboardingView: View {
    var mode: OnboardingMode = .initial

    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss

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

                Text("Oppi")
                    .font(.largeTitle.bold())

                Text("Control your pi agents\nfrom your phone.")
                    .font(.body)
                    .foregroundStyle(.themeComment)
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
                        .foregroundStyle(.themeGreen)
                        .font(.headline)

                case .failed(let error):
                    VStack(spacing: 8) {
                        Label("Connection failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.themeRed)
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.themeComment)

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

            if mode == .initial, connection.credentials != nil {
                Button("Back to current server") {
                    connectionTest = .idle
                    navigation.showOnboarding = false
                }
                .font(.footnote)
            }

            if mode == .addServer {
                Button("Cancel") {
                    dismiss()
                }
                .font(.footnote)
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

        do {
            let bootstrap = try await InviteBootstrapService.validateAndBootstrap(
                credentials: credentials,
                existingCredentials: nil
            ) { reason in
                await BiometricService.shared.authenticate(reason: reason)
            }

            let effectiveCreds = bootstrap.effectiveCredentials

            // Add to ServerStore (handles fingerprint dedup via addOrUpdate)
            serverStore.addOrUpdate(from: effectiveCreds)

            guard connection.configure(credentials: effectiveCreds) else {
                connectionTest = .failed("Connection blocked by server transport policy")
                return
            }

            // Load sessions
            connection.sessionStore.markSyncStarted()
            connection.sessionStore.applyServerSnapshot(bootstrap.sessions)
            connection.sessionStore.markSyncSucceeded()

            connectionTest = .success

            // Short delay then transition
            try? await Task.sleep(for: .milliseconds(600))

            switch mode {
            case .initial:
                navigation.showOnboarding = false
            case .addServer:
                dismiss()
            }
        } catch {
            connection.sessionStore.markSyncFailed()
            connectionTest = .failed(error.localizedDescription)
        }
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
                    TextField("Host (e.g. my-mac.local)", text: $host)
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

struct InviteBootstrapResult {
    let effectiveCredentials: ServerCredentials
    let sessions: [Session]
}

enum InviteBootstrapError: LocalizedError, Equatable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

@MainActor
enum InviteBootstrapService {
    static func validateAndBootstrap(
        credentials: ServerCredentials,
        existingCredentials: ServerCredentials?,
        confirmTrust: @MainActor (String) async -> Bool
    ) async throws -> InviteBootstrapResult {
        guard let baseURL = URL(string: "http://\(credentials.host):\(credentials.port)") else {
            throw InviteBootstrapError.message(
                "Invalid server address: \(credentials.host):\(credentials.port)"
            )
        }

        let bootstrapAPI = APIClient(baseURL: baseURL, token: credentials.token)

        let effectiveToken: String
        if let pairingToken = credentials.pairingToken, !pairingToken.isEmpty {
            do {
                let pairResult = try await bootstrapAPI.pairDevice(pairingToken: pairingToken)
                effectiveToken = pairResult.deviceToken
            } catch {
                throw InviteBootstrapError.message("Pairing failed. Request a fresh invite and try again.")
            }
        } else {
            effectiveToken = credentials.token
        }

        let api = APIClient(baseURL: baseURL, token: effectiveToken)

        let healthy = try await api.health()
        guard healthy else {
            throw InviteBootstrapError.message("Server is not healthy")
        }

        _ = try await api.me()

        let sameTarget = isSameServer(existingCredentials, credentials)
        let existingFingerprint = existingCredentials?.normalizedServerFingerprint
        let inviteFingerprint = credentials.normalizedServerFingerprint
        let requiresTrustReset = sameTarget
            && existingFingerprint != nil
            && inviteFingerprint != nil
            && existingFingerprint != inviteFingerprint

        let requiresInviteTrust = inviteFingerprint != nil

        if requiresTrustReset || requiresInviteTrust {
            let reason: String
            if requiresTrustReset {
                reason = "Server identity changed for \(credentials.host). Confirm trust reset."
            } else {
                let displayFingerprint = inviteFingerprint ?? "unknown"
                reason = "Trust \(credentials.host) (\(shortFingerprint(displayFingerprint)))"
            }

            let trusted = await confirmTrust(reason)
            guard trusted else {
                throw InviteBootstrapError.message("Trust confirmation cancelled")
            }
        }

        let effectiveCredentials = credentials.withAuthToken(effectiveToken)
        let sessions = try await api.listSessions()

        return InviteBootstrapResult(
            effectiveCredentials: effectiveCredentials,
            sessions: sessions
        )
    }

    private static func isSameServer(_ lhs: ServerCredentials?, _ rhs: ServerCredentials) -> Bool {
        guard let lhs else { return false }
        return lhs.port == rhs.port && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
    }

    private static func shortFingerprint(_ fingerprint: String) -> String {
        if fingerprint.count > 24 {
            return String(fingerprint.prefix(24)) + "…"
        }
        return fingerprint
    }
}
