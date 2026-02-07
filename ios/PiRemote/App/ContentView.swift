import SwiftUI

struct ContentView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation
        @Bindable var liveConnection = connection

        Group {
            if navigation.showOnboarding {
                OnboardingView()
            } else {
                TabView(selection: $nav.selectedTab) {
                    SwiftUI.Tab("Sessions", systemImage: "terminal", value: AppTab.sessions) {
                        NavigationStack {
                            SessionListView()
                        }
                    }
                    SwiftUI.Tab("Settings", systemImage: "gear", value: AppTab.settings) {
                        NavigationStack {
                            SettingsView()
                        }
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            }
        }
        .sheet(item: $liveConnection.activeExtensionDialog) { request in
            ExtensionDialogSheet(request: request)
        }
        .alert(
            "Extension",
            isPresented: Binding(
                get: { connection.extensionToast != nil },
                set: { showing in
                    if !showing {
                        connection.extensionToast = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                connection.extensionToast = nil
            }
        } message: {
            Text(connection.extensionToast ?? "")
        }
    }
}

private struct ExtensionDialogSheet: View {
    let request: ExtensionUIRequest

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var inputValue: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let message = request.message {
                    Text(message)
                        .font(.body)
                }

                if showsTextInput {
                    TextField(request.placeholder ?? "Value", text: $inputValue)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if request.method == "select", let options = request.options {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) {
                                submitSelect(option)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle(request.title ?? "Extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelRequest()
                    }
                }

                if request.method == "confirm" || showsTextInput {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Submit") {
                            submitCurrentValue()
                        }
                    }
                }
            }
        }
        .onAppear {
            inputValue = request.prefill ?? ""
        }
    }

    private var showsTextInput: Bool {
        request.method == "input" || request.method == "editor"
    }

    private func submitSelect(_ option: String) {
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(id: request.id, value: option)
                dismiss()
            } catch {
                connection.extensionToast = "Failed to respond: \(error.localizedDescription)"
            }
        }
    }

    private func submitCurrentValue() {
        Task { @MainActor in
            do {
                if request.method == "confirm" {
                    try await connection.respondToExtensionUI(id: request.id, confirmed: true)
                } else {
                    try await connection.respondToExtensionUI(id: request.id, value: inputValue)
                }
                dismiss()
            } catch {
                connection.extensionToast = "Failed to respond: \(error.localizedDescription)"
            }
        }
    }

    private func cancelRequest() {
        Task { @MainActor in
            do {
                try await connection.respondToExtensionUI(id: request.id, cancelled: true)
                dismiss()
            } catch {
                connection.extensionToast = "Failed to cancel: \(error.localizedDescription)"
            }
        }
    }
}
