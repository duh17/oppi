import SwiftUI
import VisionKit
import MultipeerConnectivity

/// Mode for the onboarding flow.
enum OnboardingMode {
    /// First-time setup or re-launch with no servers.
    case initial
    /// Adding an additional server from Settings.
    case addServer
}

struct OnboardingView: View {
    var mode: OnboardingMode = .initial

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss

    @State private var nearbyPairing = NearbyPairingBrowser()
    @State private var showScanner = false
    @State private var showManualEntry = false
    @State private var showNearbyPairing = false
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
                    .font(.appHero)
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
                    Button("Pair Nearby Mac") {
                        showNearbyPairing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if canScan {
                        Button("Scan QR Code") {
                            showScanner = true
                        }
                        .buttonStyle(.bordered)
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
                        .font(.subheadline)
                    }

                case .testing:
                    ProgressView("Pairing…")

                case .success:
                    Label("Connected", systemImage: "checkmark.circle.fill")
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
        .sheet(isPresented: $showNearbyPairing) {
            NearbyPairingSheet(
                browser: nearbyPairing,
                onInviteURL: { url in
                    showNearbyPairing = false
                    Task { await testConnection(inviteURL: url) }
                }
            )
        }
    }

    private func testConnection(inviteURL: URL) async {
        guard let credentials = InviteBootstrapService.credentials(from: inviteURL) else {
            connectionTest = .failed("Received an invalid nearby invite. Try again or use the QR code.")
            return
        }

        await testConnection(credentials)
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

            guard let pairedServer = PairedServer(
                from: effectiveCreds,
                sortOrder: serverStore.servers.count
            ) else {
                connectionTest = .failed("Missing server fingerprint")
                return
            }

            coordinator.addServer(pairedServer, switchTo: false)
            guard coordinator.switchToServer(pairedServer) else {
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
                // Signal WorkspaceHomeView to auto-present create flow
                // after workspaces load (if the server has none).
                navigation.shouldGuideWorkspaceCreation = true
                navigation.selectedTab = .workspaces
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

private struct NearbyPairingSheet: View {
    let browser: NearbyPairingBrowser
    let onInviteURL: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(browser.state.statusText ?? "Looking for nearby Macs…")
                        .foregroundStyle({
                            if case .failed = browser.state {
                                return AnyShapeStyle(.themeRed)
                            }
                            return AnyShapeStyle(.themeComment)
                        }())
                }

                if browser.candidates.isEmpty {
                    Section("Nearby Macs") {
                        ContentUnavailableView(
                            "No Mac Found Yet",
                            systemImage: "macbook.and.iphone",
                            description: Text("Keep Oppi open on your Mac's pairing screen. You can still use the QR code or invite link instead.")
                        )
                    }
                } else {
                    Section("Nearby Macs") {
                        ForEach(browser.candidates) { candidate in
                            Button {
                                browser.invite(candidate)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.displayName)
                                        .foregroundStyle(.themeFg)
                                    if let detailText = candidate.detailText {
                                        Text(detailText)
                                            .font(.caption)
                                            .foregroundStyle(.themeComment)
                                    }
                                }
                            }
                            .disabled(!canInvite)
                        }
                    }
                }
            }
            .navigationTitle("Pair Nearby Mac")
            .navigationBarTitleDisplayMode(.inline)
            .themedListSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry") {
                        browser.retry()
                    }
                }
            }
            .task {
                browser.onInviteURL = onInviteURL
                browser.start()
            }
            .onDisappear {
                browser.onInviteURL = nil
                browser.stop()
            }
        }
    }

    private var canInvite: Bool {
        if case .discovering = browser.state {
            return true
        }
        if case .failed = browser.state {
            return true
        }
        return false
    }
}

// MARK: - Manual Entry

private struct ManualEntryView: View {
    let onConnect: (ServerCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "7749"
    @State private var scheme: ServerScheme = .https
    @State private var token = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    Picker("Scheme", selection: $scheme) {
                        Text("HTTPS").tag(ServerScheme.https)
                        Text("HTTP (insecure)").tag(ServerScheme.http)
                    }
                    .pickerStyle(.segmented)
                    TextField("Host (e.g. my-mac.local)", text: $host)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Authentication") {
                    SecureField("Token", text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name", text: $name)
                }
            }
            .themedListSurface()
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
                            name: name,
                            scheme: scheme
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

protocol InviteBootstrapAPI: Sendable {
    func pairDevice(pairingToken: String, deviceName: String?) async throws -> PairDeviceResponse
    func health() async throws -> Bool
    func me() async throws -> User
    func listSessionsFromWorkspaces(recentDays: Int) async throws -> [Session]
}

extension APIClient: InviteBootstrapAPI {}

@MainActor
enum InviteBootstrapService {
    static func credentials(from inviteURL: URL) -> ServerCredentials? {
        ServerCredentials.decodeInviteURL(inviteURL)
    }

    static func validateAndBootstrap(
        credentials: ServerCredentials,
        existingCredentials: ServerCredentials?,
        confirmTrust: @MainActor (String) async -> Bool,
        apiFactory: @MainActor (URL, String, String?) -> any InviteBootstrapAPI = { baseURL, token, tlsCertFingerprint in
            APIClient(baseURL: baseURL, token: token, tlsCertFingerprint: tlsCertFingerprint)
        }
    ) async throws -> InviteBootstrapResult {
        guard let baseURL = credentials.baseURL else {
            throw InviteBootstrapError.message(
                "Invalid server address: \(credentials.host):\(credentials.port)"
            )
        }

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

        let bootstrapAPI = apiFactory(
            baseURL,
            credentials.token,
            credentials.normalizedTLSCertFingerprint
        )

        let effectiveToken: String
        if let pairingToken = credentials.pairingToken, !pairingToken.isEmpty {
            do {
                let pairResult = try await bootstrapAPI.pairDevice(
                    pairingToken: pairingToken,
                    deviceName: nil
                )
                effectiveToken = pairResult.deviceToken
            } catch {
                throw InviteBootstrapError.message(pairingFailureMessage(for: error, host: credentials.host))
            }
        } else {
            effectiveToken = credentials.token
        }

        let api = apiFactory(
            baseURL,
            effectiveToken,
            credentials.normalizedTLSCertFingerprint
        )

        let healthy = try await api.health()
        guard healthy else {
            throw InviteBootstrapError.message("Server is not healthy")
        }

        _ = try await api.me()

        let effectiveCredentials = credentials.withAuthToken(effectiveToken)
        let sessions = try await api.listSessionsFromWorkspaces(recentDays: 3)

        return InviteBootstrapResult(
            effectiveCredentials: effectiveCredentials,
            sessions: sessions
        )
    }

    static func pairingFailureMessage(for error: Error, host: String) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .invalidResponse:
                return "Server returned an invalid pairing response. Request a fresh invite and try again."
            case .server(401, let message)
                where message.localizedCaseInsensitiveContains("invalid or expired pairing token"):
                return "Invite link expired or was already used. Request a fresh invite."
            case .server(429, _):
                return "Too many invalid pairing attempts. Wait a moment, request a fresh invite, and try again."
            case .server(let status, let message):
                return "Pairing failed with server error (\(status)): \(message)"
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                    .cannotFindHost,
                    .cannotConnectToHost,
                    .networkConnectionLost,
                    .notConnectedToInternet,
                    .dnsLookupFailed,
                    .cannotLoadFromNetwork:
                return "Could not reach \(host). Check the address, VPN, or network and try again."
            case .secureConnectionFailed,
                    .serverCertificateHasBadDate,
                    .serverCertificateHasUnknownRoot,
                    .serverCertificateNotYetValid,
                    .serverCertificateUntrusted,
                    .clientCertificateRejected,
                    .clientCertificateRequired:
                return "Secure connection to \(host) failed. Verify the invite host and certificate, then try again."
            default:
                break
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return "Pairing failed: \(message)"
        }

        return "Pairing failed. Request a fresh invite and try again."
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
