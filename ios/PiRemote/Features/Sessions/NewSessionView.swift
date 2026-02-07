import SwiftUI

struct NewSessionView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var model = "anthropic/claude-sonnet-4-0"
    @State private var isCreating = false
    @State private var error: String?

    private let suggestedModels = [
        "anthropic/claude-sonnet-4-0",
        "anthropic/claude-opus-4-0",
        "anthropic/claude-haiku-3-5",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session name (optional)", text: $name)
                }

                Section("Model") {
                    TextField("Model identifier", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    ForEach(suggestedModels, id: \.self) { suggestion in
                        Button {
                            model = suggestion
                        } label: {
                            HStack {
                                Text(suggestion.split(separator: "/").last.map(String.init) ?? suggestion)
                                Spacer()
                                if model == suggestion {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createSession() }
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private func createSession() async {
        guard let api = connection.apiClient else { return }
        isCreating = true
        error = nil

        do {
            let session = try await api.createSession(
                name: name.isEmpty ? nil : name,
                model: model.isEmpty ? nil : model
            )
            sessionStore.upsert(session)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}
