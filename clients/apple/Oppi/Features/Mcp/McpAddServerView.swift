import SwiftUI

struct McpAddServerView: View {
    let client: APIClient
    let scopes: [McpScopeSnapshot]
    let serverName: String
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scopeId = "global"
    @State private var mode = "url"
    @State private var name = ""
    @State private var url = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var cwd = ""
    @State private var pairs = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var callbackPort = ""
    @State private var exposure = McpExposure.codemode
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Configuration") {
                    LabeledContent("Host", value: serverName)
                    TextField("Server name", text: $name)
                        .accessibilityIdentifier("mcp.add.name")
                    Picker("Scope", selection: $scopeId) {
                        ForEach(scopes) { Text($0.title).tag($0.id) }
                    }
                    .accessibilityIdentifier("mcp.add.scope")
                    if scopes.first(where: { $0.id == scopeId })?.kind == "project" {
                        Text("Saved to this workspace's .pi/mcp.json. Pi only loads project servers after you trust the project on the host.")
                            .font(.footnote).foregroundStyle(.themeComment)
                    }
                    Picker("Transport", selection: $mode) {
                        Text("URL").tag("url")
                        Text("Command").tag("command")
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("mcp.add.transport")
                    Picker("Exposure", selection: $exposure) {
                        ForEach(McpExposure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                if mode == "url" {
                    Section("Streamable HTTP") {
                        TextField("https://example.com/mcp", text: $url).keyboardType(.URL)
                            .accessibilityIdentifier("mcp.add.url")
                        TextField("Headers: one KEY=VALUE per line", text: $pairs, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    Section("Optional OAuth Client") {
                        TextField("Client ID", text: $clientId)
                        TextField("Client secret reference: ${NAME}", text: $clientSecret)
                        TextField("Callback port (automatic if empty)", text: $callbackPort)
                            .keyboardType(.numberPad)
                    }
                } else {
                    Section("Standard Input / Output") {
                        TextField("Executable (not a shell command)", text: $command)
                            .accessibilityIdentifier("mcp.add.command")
                        TextField("Arguments: one per line", text: $arguments, axis: .vertical)
                            .lineLimit(3...8)
                        TextField("Working directory (optional)", text: $cwd)
                        TextField("Environment: one KEY=VALUE per line", text: $pairs, axis: .vertical)
                            .lineLimit(3...8)
                    }
                }
                Section {
                    Text("Use ${NAME} references instead of literal secrets. For example: API_KEY=${TOOLS_KEY}, or Authorization=Bearer ${TOKEN}. Values are resolved on the host; literal values are redacted when read back.")
                        .font(.footnote).foregroundStyle(.themeComment)
                    if mode == "command" {
                        Text("Adding a command authorizes Pi to run it on the host when the scope is trusted and the server is enabled.")
                            .font(.footnote).foregroundStyle(.themeOrange)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.themeRed) } }
                if saving { Section { ProgressView("Adding server…") } }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(saving)
            .themedListSurface()
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
            .navigationTitle("Add MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(saving || name.isEmpty || (mode == "url" ? url.isEmpty : command.isEmpty))
                        .accessibilityIdentifier("mcp.add.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: mode) { _, _ in pairs = "" }
        }
    }

    private func add() {
        do {
            var values: [String: String] = [:]
            for line in pairs.split(separator: "\n") {
                guard let separator = line.firstIndex(of: "="), separator != line.startIndex else {
                    error = "Use KEY=VALUE on each line."; return
                }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, values[key] == nil else { error = "Keys must be non-empty and unique."; return }
                values[key] = String(line[line.index(after: separator)...])
            }
            var input = McpAddServerRequest(scopeId: scopeId, name: name, exposure: exposure)
            if mode == "url" {
                input.url = url
                input.headers = values.isEmpty ? nil : values
                var oauth = McpServerConfig.OAuth()
                oauth.clientId = clientId.isEmpty ? nil : clientId
                oauth.clientSecret = clientSecret.isEmpty ? nil : clientSecret
                if !callbackPort.isEmpty {
                    guard let port = Int(callbackPort), (1...65535).contains(port) else { error = "Enter a callback port between 1 and 65535."; return }
                    oauth.callbackPort = port
                }
                if oauth.clientId != nil || oauth.clientSecret != nil || oauth.callbackPort != nil { input.oauth = oauth }
            } else {
                input.command = command
                input.args = arguments.isEmpty ? nil : arguments.components(separatedBy: "\n")
                input.cwd = cwd.isEmpty ? nil : cwd
                input.env = values.isEmpty ? nil : values
            }
            saving = true; error = nil
            Task {
                defer { saving = false }
                do { try await client.addMcpServer(input); onAdded(); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
