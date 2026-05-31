import SwiftUI
import CoreImage.CIFilterBuiltins

/// Sidebar view for generating new pairing invites.
///
/// Runs `oppi pair --json` via ProcessRunner, generates a QR code,
/// and shows the invite URL for copying.
struct PairView: View {

    @State private var nearbyPairing = NearbyPairingAdvertiser()
    @State private var inviteURL: String?
    @State private var serverURL: String?
    @State private var qrImage: NSImage?
    @State private var error: String?
    @State private var isLoading = false
    @State private var copied = false
    @State private var pairedClientCount = MacAPIClient.pairedClientCount()

    private var hasPairedClients: Bool {
        pairedClientCount > 0
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        hasPairedClients ? "Pair another device" : "Pair your first iPhone",
                        systemImage: hasPairedClients ? "iphone" : "qrcode"
                    )
                    .font(.title3.weight(.semibold))

                    Text(hasPairedClients
                        ? "Scan this invite from Oppi on your iPhone, or copy the link if the phone is not nearby."
                        : "No phone is paired with this server yet. Keep this Mac awake, then scan the invite from Oppi on your iPhone.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Nearby Pairing") {
                Text(nearbyPairing.state.statusText)
                    .foregroundStyle({
                        if case .failed = nearbyPairing.state {
                            return AnyShapeStyle(.red)
                        }
                        return AnyShapeStyle(.secondary)
                    }())

                Text("Keep this window open to let Oppi on your iPhone discover this Mac nearby. QR and invite-link pairing still work below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Button(hasPairedClients ? "Generate New Invite" : "Refresh QR Code") {
                    generatePairing()
                }
                .disabled(isLoading)
            } footer: {
                Text("Invite links expire quickly and can only be used once.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(hasPairedClients ? "Pair Device" : "Pair iPhone")
        .task {
            pairedClientCount = MacAPIClient.pairedClientCount()
            nearbyPairing.start()
            generatePairing()
        }
        .onDisappear {
            nearbyPairing.stop()
        }
        .alert(
            "Allow Nearby Pairing?",
            isPresented: Binding(
                get: { nearbyPairing.approvalRequest != nil },
                set: { isPresented in
                    if !isPresented, nearbyPairing.approvalRequest != nil {
                        nearbyPairing.rejectPendingInvitation()
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                nearbyPairing.rejectPendingInvitation()
            }
            Button("Pair") {
                nearbyPairing.approvePendingInvitation()
            }
        } message: {
            Text(
                nearbyPairing.approvalRequest.map {
                    "Pair \($0.peerName) with this Mac and send a fresh one-time Oppi invite?"
                } ?? ""
            )
        }
    }

    private func generatePairing() {
        pairedClientCount = MacAPIClient.pairedClientCount()
        isLoading = true
        error = nil
        inviteURL = nil
        serverURL = nil
        qrImage = nil

        Task.detached {
            do {
                let info = try await PairingInviteService.generate()

                let image: NSImage? = if let url = info.inviteURL {
                    QRCodeImageGenerator.makeImage(from: url)
                } else {
                    nil
                }

                await MainActor.run {
                    inviteURL = info.inviteURL
                    serverURL = info.serverURL
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
}

enum QRCodeImageGenerator {
    static func makeImage(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
