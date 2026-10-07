import SwiftUI

struct McpSignInSheet: View {
    @Bindable var attempt: ProviderAuthFlowAttempt
    @Bindable var owner: McpSignInOwner
    @FocusState private var callbackFocused: Bool

    private func submit() {
        guard owner.canSubmitCallback else { return }
        callbackFocused = false
        Task { await owner.submitCallback() }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(attempt.providerName) {
                    LabeledContent("Host", value: attempt.serverName)
                    LabeledContent("Status", value: ProviderAuthFlowPresentation.statusText(attempt.flow.status))
                }
                if !attempt.isSettled, owner.callbackAccepted || attempt.isSubmitting {
                    Section { ProgressView("Finishing sign-in on the host…") }
                } else if !attempt.isSettled, let auth = attempt.flow.auth {
                    Section {
                        if let url = ProviderAuthFlowPresentation.signInURL(auth.url) {
                            Link("Open Sign-In Page in Safari", destination: url)
                                .accessibilityIdentifier("mcp.auth.open")
                        }
                        TextField("Paste full callback URL", text: $attempt.input)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).submitLabel(.go)
                            .focused($callbackFocused)
                            .onSubmit(submit)
                            .accessibilityIdentifier("mcp.auth.callback")
                        Button("Submit Callback", action: submit)
                            .disabled(!owner.canSubmitCallback)
                            .accessibilityIdentifier("mcp.auth.submit")
                    } header: {
                        Text("Sign In")
                    } footer: {
                        Text("After approval, Safari may fail to load 127.0.0.1. Copy its full callback URL and paste it below. You can also complete sign-in using a browser on the host.")
                    }
                } else if !attempt.isSettled { ProgressView("Preparing sign-in…") }
                if let error = attempt.flow.error { Text(error).foregroundStyle(.themeRed) }
                if let error = attempt.actionError { Text(error).foregroundStyle(.themeRed) }
                if let error = attempt.refreshError { Text(error).foregroundStyle(.themeOrange) }
                if attempt.isGone { Text("The host no longer has this flow. Start a new sign-in.") }
                Section {
                    if attempt.isSettled { Button("Done") { owner.showingSheet = false } }
                    else {
                        Button("Cancel Sign-In", role: .destructive) { Task { await owner.cancel() } }
                            .disabled(attempt.isCancelling)
                    }
                }
            }
            .settingsPage("Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { owner.showingSheet = false } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Submit Callback", action: submit)
                        .disabled(!owner.canSubmitCallback)
                        .accessibilityIdentifier("mcp.auth.submit.keyboard")
                }
            }
        }
        .interactiveDismissDisabled(attempt.isCancelling)
    }
}
