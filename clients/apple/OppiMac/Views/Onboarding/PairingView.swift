import SwiftUI

/// Step 4: Generate a QR code for iPhone pairing via `oppi pair --json`.
struct PairingView: View {

    let onDone: () -> Void

    @State private var nearbyPairing = NearbyPairingAdvertiser()
    @State private var pairingInfo: PairingInvite?
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

                Text("Open Oppi on your iPhone and scan this QR code, or use nearby pairing if the phone is close to this Mac.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            VStack(spacing: 6) {
                Text(nearbyPairing.state.statusText)
                    .font(.caption)
                    .foregroundStyle({
                        if case .failed = nearbyPairing.state {
                            return AnyShapeStyle(.red)
                        }
                        return AnyShapeStyle(.secondary)
                    }())

                Text("Nearby pairing stays active while this step is visible.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

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

    // MARK: - Generate

    private func generatePairing() {
        isLoading = true
        error = nil
        pairingInfo = nil
        qrImage = nil

        Task.detached {
            do {
                let info = try await PairingInviteService.generate()

                let image: NSImage? = if let inviteURL = info.inviteURL {
                    QRCodeImageGenerator.makeImage(from: inviteURL)
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
}
