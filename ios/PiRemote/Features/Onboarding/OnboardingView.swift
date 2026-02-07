import SwiftUI

struct OnboardingView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation

    @State private var showScanner = false
    @State private var showManualEntry = false
    @State private var connectionTest: ConnectionTestState = .idle

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
                    Button("Scan QR Code") {
                        showScanner = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Enter manually") {
                        showManualEntry = true
                    }
                    .font(.subheadline)

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
                            showScanner = true
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

        let api = APIClient(baseURL: credentials.baseURL, token: credentials.token)

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
            connection.configure(credentials: credentials)

            // Load sessions
            let sessions = try await api.listSessions()
            connection.sessionStore.sessions = sessions

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
                    TextField("Token", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
