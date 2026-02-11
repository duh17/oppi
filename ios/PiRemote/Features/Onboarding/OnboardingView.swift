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

            let user = try await api.me()
            _ = user // We could show the name

            // Save credentials and transition
            try KeychainService.saveCredentials(credentials)
            guard connection.configure(credentials: credentials) else {
                connectionTest = .failed("Invalid server address")
                return
            }

            // Load sessions
            let sessions = try await api.listSessions()
            connection.sessionStore.applyServerSnapshot(sessions)

            connectionTest = .success

            // Short delay then transition
            try? await Task.sleep(for: .milliseconds(600))
            navigation.showOnboarding = false
        } catch {
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
