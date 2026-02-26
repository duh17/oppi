import Speech
import SwiftUI

/// Minimal settings for on-device voice input.
///
/// Most users never need this — voice input Just Works when you tap the mic.
/// This page exists for troubleshooting (permissions denied, model not
/// downloaded) and transparency (on-device, no cloud).
struct VoiceInputSettingsView: View {
    @State private var modelStatus: ModelStatus = .checking
    @State private var isDownloading = false

    private var micGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    private var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private var allPermissionsGranted: Bool { micGranted && speechGranted }

    var body: some View {
        List {
            readySection
            if !allPermissionsGranted {
                permissionsSection
            }
            aboutSection
        }
        .navigationTitle("Voice Input")
        .navigationBarTitleDisplayMode(.inline)
        .task { await checkModel() }
    }

    // MARK: - Sections

    private var readySection: some View {
        Section {
            switch modelStatus {
            case .checking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Checking model...")
                        .foregroundStyle(.themeComment)
                }

            case .installed:
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.themeGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready")
                            .font(.body.weight(.medium))
                        Text("On-device model installed")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }

            case .needsDownload:
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.themeBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model not downloaded")
                            .font(.body.weight(.medium))
                        Text("~50 MB, downloads automatically on first use")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }

                Button {
                    Task { await downloadModel() }
                } label: {
                    HStack {
                        if isDownloading {
                            ProgressView().controlSize(.small)
                            Text("Downloading...")
                        } else {
                            Text("Download Now")
                        }
                    }
                }
                .disabled(isDownloading)

            case .error(let message):
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.themeOrange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Error")
                            .font(.body.weight(.medium))
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            if !micGranted {
                HStack(spacing: 12) {
                    Image(systemName: "mic.slash")
                        .foregroundStyle(.themeRed)
                    Text("Microphone access required")
                }
            }
            if !speechGranted {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.themeRed)
                    Text("Speech recognition access required")
                }
            }

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Tap the mic button to be prompted, or grant access in system Settings.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Processing", value: "On-device only")
            LabeledContent("Languages", value: "Multilingual")
        } footer: {
            Text("Audio never leaves your device. The speech model handles mixed languages automatically.")
        }
    }

    // MARK: - Model Management

    private enum ModelStatus {
        case checking, installed, needsDownload, error(String)
    }

    private func checkModel() async {
        let installed = await VoiceInputManager.isModelInstalled(for: .current)
        modelStatus = installed ? .installed : .needsDownload
    }

    private func downloadModel() async {
        isDownloading = true
        do {
            let transcriber = SpeechTranscriber(
                locale: .current,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )

            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }

            modelStatus = .installed
        } catch {
            modelStatus = .error(error.localizedDescription)
        }
        isDownloading = false
    }
}
