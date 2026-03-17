import SwiftUI
import CoreImage.CIFilterBuiltins
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "PairingView")

/// Step 4: Generate a QR code for iPhone pairing via `oppi pair --json`.
struct PairingView: View {

    let onDone: () -> Void

    @State private var pairingInfo: PairingInfo?
    @State private var qrImage: NSImage?
    @State private var error: String?
    @State private var isLoading = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("Pair Your iPhone")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Open Oppi on your iPhone and scan this QR code.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            Spacer()

            if isLoading {
                ProgressView("Generating invite...")
            } else if let qrImage, let pairingInfo {
                VStack(spacing: 16) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if let serverURL = pairingInfo.serverURL {
                        Text(serverURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        if let url = pairingInfo.inviteURL {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copied = true
                            // Reset after 2 seconds
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        }
                    } label: {
                        Label(
                            copied ? "Copied" : "Copy Invite Link",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(pairingInfo.inviteURL == nil)
                }
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        generatePairing()
                    }
                    .padding(.top, 4)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .task {
            generatePairing()
        }
    }

    // MARK: - Generate

    private func generatePairing() {
        isLoading = true
        error = nil
        pairingInfo = nil
        qrImage = nil

        Task.detached {
            do {
                let info = try await PairingView.runPairCommand()

                let image: NSImage? = if let inviteURL = info.inviteURL {
                    PairingView.generateQRCode(from: inviteURL)
                } else {
                    nil
                }

                await MainActor.run {
                    pairingInfo = info
                    qrImage = image
                    isLoading = false
                    if image == nil {
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

    // MARK: - Run oppi pair --json

    private static func runPairCommand() async throws -> PairingInfo {
        guard let nodePath = await MainActor.run(body: { ServerProcessManager.resolveNodePath() }) else {
            throw PairingError.nodeNotFound
        }
        guard let cliPath = await MainActor.run(body: { ServerProcessManager.resolveServerCLIPath() }) else {
            throw PairingError.cliNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [cliPath, "pair", "--json"]

        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + currentPath
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw PairingError.commandFailed(errText)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw PairingError.emptyOutput
        }

        let info = try JSONDecoder().decode(PairingInfo.self, from: data)
        logger.info("Pairing info generated: host=\(info.host ?? "unknown")")
        return info
    }

    // MARK: - QR code generation

    private nonisolated static func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for crisp rendering
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: scale)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

// MARK: - Types

private struct PairingInfo: Decodable {
    let host: String?
    let port: Int?
    let scheme: String?
    let name: String?
    let pairingToken: String?
    let fingerprint: String?
    let tlsCertFingerprint: String?
    let inviteURL: String?

    var serverURL: String? {
        guard let scheme, let host, let port else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    enum CodingKeys: String, CodingKey {
        case host, port, scheme, name, pairingToken, fingerprint, tlsCertFingerprint, inviteURL
    }
}

private enum PairingError: LocalizedError {
    case nodeNotFound
    case cliNotFound
    case commandFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .nodeNotFound: "Node.js not found"
        case .cliNotFound: "Server CLI not found"
        case .commandFailed(let msg): "Pair command failed: \(msg)"
        case .emptyOutput: "No output from pair command"
        }
    }
}
