import SwiftUI

struct MacExtensionNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let severity: String?
}

/// Pane-local entry point, rather than unsolicited window-modal sheets from
/// several streaming panes. Only the first request can open or respond.
struct MacExtensionRequestCard: View {
    let request: ExtensionUIRequest
    @Bindable var store: MacSessionTraceStore
    @State private var isPresented = false
    @Environment(\.theme) private var theme

    private var isPending: Bool { store.extensionResponseAttempts[request.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.title ?? "Extension request", systemImage: "text.bubble")
                .font(.headline)
            if let source = request.extensionDisplayName {
                Text(source).font(.caption).foregroundStyle(.themeComment)
            }
            HStack {
                Button(request.nativePresentation == .editorSheet ? "Edit response…" : "View request…") {
                    isPresented = true
                }
                .accessibilityIdentifier("mac.extension.open")
                Button("Cancel request") {
                    Task { await store.respondToExtensionRequest(request, payload: .cancelled) }
                }
                .disabled(isPending)
                .accessibilityIdentifier("mac.extension.cancel")
                if isPending { Text("Waiting for server…").font(.caption) }
            }
            if let error = store.extensionResponseErrors[request.id] {
                Text(error).font(.caption).foregroundStyle(.themeRed)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $isPresented) {
            MacExtensionDialogView(request: request, store: store, close: { isPresented = false })
        }
        .onChange(of: store.currentExtensionDialog?.id) { _, id in
            if id != request.id { isPresented = false }
        }
        .accessibilityIdentifier("mac.extension.request")
    }
}

struct MacExtensionDialogView: View {
    let request: ExtensionUIRequest
    @Bindable var store: MacSessionTraceStore
    var close: () -> Void
    @Environment(\.theme) private var theme

    private var isPending: Bool { store.extensionResponseAttempts[request.id] != nil }
    private var isCurrent: Bool { store.currentExtensionDialog?.id == request.id }

    private var currentRequest: ExtensionUIRequest {
        liveDialogRequest() ?? request
    }

    /// Sheets keep the presentation-time view value, including Button actions
    /// and keyboard shortcuts. Resolve the live same-ID snapshot at invoke
    /// time so Cmd-Return cannot send a replaced request the store must drop.
    private func liveDialogRequest() -> ExtensionUIRequest? {
        guard let current = store.currentExtensionDialog,
              current.id == request.id, current.sessionId == request.sessionId else { return nil }
        return current
    }

    private func submitLiveEditor() {
        guard let live = liveDialogRequest() else { return }
        let text = store.extensionEditorText(for: live)
        Task { await store.respondToExtensionRequest(live, payload: ExtensionUIResponsePayload(value: text)) }
    }

    private func cancelLiveEditor() {
        guard let live = liveDialogRequest() else { return }
        Task { await store.respondToExtensionRequest(live, payload: .cancelled) }
    }

    var body: some View {
        // Paint the latest same-ID snapshot. Submit/Cancel read it again at
        // invoke time because SwiftUI may keep the first keyboard shortcut.
        let request = currentRequest
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title ?? "Extension request").font(.title2).lineLimit(2)
            Text(request.extensionDisplayName ?? "Response to this session")
                .font(.caption).foregroundStyle(.themeComment)
            if let message = request.message, !message.isEmpty {
                ScrollView { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 100)
            }
            if request.nativePresentation == .editorSheet {
                TextEditor(text: Binding(
                    get: { store.extensionEditorText(for: request) },
                    set: { store.setExtensionEditorText($0, for: request) }
                ))
                .font(.body)
                .frame(height: 240)
                .disabled(isPending || !isCurrent)
                .accessibilityLabel("Extension response")
                .accessibilityIdentifier("mac.extension.editor")
            } else {
                Text("Unsupported extension UI: \(request.method)")
                    .font(.headline)
                Text("Read the request, then cancel and try the task another way.")
                if let prefill = request.prefill, !prefill.isEmpty {
                    ScrollView { Text(prefill).textSelection(.enabled) }.frame(maxHeight: 200)
                }
            }
            if request.timeoutAt != nil || request.timeout != nil {
                Label("The server controls when this request expires.", systemImage: "timer")
                    .font(.caption).foregroundStyle(.themeComment)
            }
            if let error = store.extensionResponseErrors[request.id] {
                Text(error).foregroundStyle(.themeRed).textSelection(.enabled)
            }
            HStack {
                Button("Close", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                    .help("Keep this request and its draft pending")
                Spacer()
                if isPending { Text("Waiting for server…").font(.caption) }
                Button("Cancel request") {
                    cancelLiveEditor()
                }
                .disabled(isPending || !isCurrent)
                .accessibilityIdentifier("mac.extension.dialog.cancel")
                if request.nativePresentation == .editorSheet {
                    Button("Submit", action: submitLiveEditor)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isPending || !isCurrent)
                    .accessibilityIdentifier("mac.extension.dialog.submit")
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(.themeBg)
        .interactiveDismissDisabled()
        .onChange(of: isCurrent) { _, current in if !current { close() } }
    }
}

struct MacExtensionNoticeView: View {
    let notice: MacExtensionNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Label(notice.message, systemImage: notice.severity == "error" ? "exclamationmark.circle" : "info.circle")
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss notification")
        }
        .font(.callout)
        .padding(10)
        .background(.themeBgDark, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("mac.extension.notice")
        .task(id: notice.id) {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            dismiss()
        }
    }
}
