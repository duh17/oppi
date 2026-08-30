import Foundation
import SwiftUI

// MARK: - Async Audio Blob

/// Async audio decoder + inline playback row for data URI audio blocks.
struct AsyncAudioBlob: View {
    let id: String
    let base64: String
    let mimeType: String?

    @Environment(AudioPlayerService.self) private var audioPlayer

    @State private var decodedData: Data?
    @State private var decodeFailed = false

    private var isLoading: Bool {
        audioPlayer.loadingItemID == id
    }

    private var isPlaying: Bool {
        audioPlayer.playingItemID == id
    }

    private var title: String {
        mimeType ?? "audio"
    }

    private var subtitle: String {
        guard let decodedData else { return "Preparing audio…" }
        return ToolCallFormatting.formatBytes(decodedData.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.themePurple)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.themeFg)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }

            Spacer()

            if decodeFailed {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
            } else if decodedData == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    guard let decodedData else { return }
                    audioPlayer.toggleDataPlayback(data: decodedData, itemID: id)
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.themePurple)
                        } else if isPlaying {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                                .foregroundStyle(.themePurple)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.themeBgHighlight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: base64.prefix(32)) {
            decodeFailed = false
            decodedData = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
            }.value
            if decodedData == nil {
                decodeFailed = true
            }
        }
    }
}

// MARK: - ToolPresentationBuilder helpers that remain iOS-specific

extension ToolPresentationBuilder {
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remaining = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remaining)
        }
        return String(format: "0:%02d", remaining)
    }
}
