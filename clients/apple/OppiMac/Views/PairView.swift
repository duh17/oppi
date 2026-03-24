import SwiftUI
import CoreImage.CIFilterBuiltins
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "PairView")

/// Sidebar view for generating new pairing invites.
///
/// Runs `oppi pair --json` via ProcessRunner, generates a QR code,
/// and shows the invite URL for copying.
struct PairView: View {

    @State private var inviteURL: String?
    @State private var serverURL: String?
    @State private var qrImage: NSImage?
    @State private var error: String?
    @State private var isLoading = false
    @State private var copied = false

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating invite...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let qrImage {
                Section("QR Code") {
                    HStack {
                        Spacer()
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                    .padding(.vertical, 8)

                    Text("Open Oppi on your iPhone and scan this code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let serverURL {
                Section("Server") {
                    LabeledContent("URL") {
                        Text(serverURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if let inviteURL {
                Section {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(inviteURL, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(
                            copied ? "Copied" : "Copy Invite Link",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Generate New Invite") {
                    generatePairing()
                }
                .disabled(isLoading)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Pair")
        .task {
            generatePairing()
        }
    }

    private func generatePairing() {
        isLoading = true
        error = nil
        inviteURL = nil
        serverURL = nil
        qrImage = nil

        Task.detached {
            guard let nodePath = await MainActor.run(body: { ServerProcessManager.resolveNodePath() }) else {
                await MainActor.run {
                    error = "Node.js not found"
                    isLoading = false
                }
                return
            }
            guard let cliPath = await MainActor.run(body: { ServerProcessManager.resolveServerCLIPath() }) else {
                await MainActor.run {
                    error = "Server CLI not found"
                    isLoading = false
                }
                return
            }

            do {
                let result = try await ProcessRunner.runCapturingStderr(
                    executable: nodePath,
                    arguments: [cliPath, "pair", "--json"]
                )

                guard result.exitCode == 0 else {
                    let errText = result.stderr.isEmpty ? "Unknown error" : result.stderr
                    await MainActor.run {
                        error = "Pair command failed: \(errText)"
                        isLoading = false
                    }
                    return
                }

                guard let data = result.stdout.data(using: .utf8), !data.isEmpty else {
                    await MainActor.run {
                        error = "No output from pair command"
                        isLoading = false
                    }
                    return
                }

                let info = try JSONDecoder().decode(PairInfo.self, from: data)
                logger.info("Pairing info generated: host=\(info.host ?? "unknown")")

                let image: NSImage? = if let url = info.inviteURL {
                    PairView.generateQRCode(from: url)
                } else {
                    nil
                }

                await MainActor.run {
                    inviteURL = info.inviteURL
                    serverURL = info.serverDisplayURL
                    qrImage = image
                    isLoading = false
                    if image == nil && info.inviteURL != nil {
                        error = "Could not generate QR code"
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    // MARK: - QR code

    private nonisolated static func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: scale)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

// MARK: - Types

private struct PairInfo: Decodable {
    let host: String?
    let port: Int?
    let scheme: String?
    let inviteURL: String?

    var serverDisplayURL: String? {
        guard let scheme, let host, let port else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    enum CodingKeys: String, CodingKey {
        case host, port, scheme, inviteURL
    }
}
