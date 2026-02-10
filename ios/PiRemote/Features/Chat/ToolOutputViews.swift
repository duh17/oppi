import SwiftUI

// MARK: - Async Tool Output

/// Renders tool output with async image extraction and ANSI parsing.
///
/// All expensive work (regex scanning, ANSI parsing, image decoding) runs
/// off the main thread via `.task(id:)`. The body only shows cached results.
struct AsyncToolOutput: View {
    let output: String
    let isError: Bool
    var filePath: String? = nil
    var startLine: Int = 1

    @State private var parsed: ParsedToolOutput?

    var body: some View {
        Group {
            if let parsed {
                if parsed.isReadWithMedia {
                    ToolOutputMedia(
                        images: parsed.images,
                        audio: parsed.audio,
                        strippedText: parsed.strippedText,
                        isError: isError
                    )
                } else if parsed.isReadFile, let filePath {
                    FileContentView(content: output, filePath: filePath, startLine: startLine)
                } else {
                    ToolOutputMedia(
                        images: parsed.images,
                        audio: parsed.audio,
                        strippedText: parsed.strippedText,
                        isError: isError
                    )
                }
            } else {
                Text(String(output.prefix(200)))
                    .font(.caption.monospaced())
                    .foregroundStyle(isError ? .tokyoRed : .tokyoFgDim)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: output.count) {
            parsed = await Task.detached(priority: .userInitiated) {
                ParsedToolOutput.parse(output, isReadFile: filePath != nil)
            }.value
        }
    }
}

// MARK: - Parsed Output

/// Pre-parsed tool output — all expensive work done off main thread.
private struct ParsedToolOutput: Sendable {
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
    let strippedText: String
    let isReadFile: Bool
    let isReadWithMedia: Bool

    static func parse(_ output: String, isReadFile: Bool) -> ParsedToolOutput {
        let images = ImageExtractor.extract(from: output)
        let audio = AudioExtractor.extract(from: output)

        let strippedText: String
        if images.isEmpty && audio.isEmpty {
            strippedText = output
        } else {
            var text = output
            let ranges = (images.map(\.range) + audio.map(\.range))
                .sorted { $0.lowerBound > $1.lowerBound }
            for range in ranges {
                text.removeSubrange(range)
            }
            strippedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ParsedToolOutput(
            images: images,
            audio: audio,
            strippedText: strippedText,
            isReadFile: isReadFile,
            isReadWithMedia: isReadFile && (!images.isEmpty || !audio.isEmpty)
        )
    }
}

// MARK: - Tool Output Media

/// Renders pre-extracted media blocks + ANSI-parsed text.
private struct ToolOutputMedia: View {
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
    let strippedText: String
    let isError: Bool

    @State private var ansiAttributed: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !strippedText.isEmpty {
                let displayText = String(strippedText.prefix(2000))
                if isError {
                    Text(displayText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoRed)
                        .textSelection(.enabled)
                } else if let ansiAttributed {
                    Text(ansiAttributed)
                        .textSelection(.enabled)
                } else {
                    Text(displayText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoFg)
                        .textSelection(.enabled)
                }
            }

            ForEach(images) { image in
                AsyncImageBlob(base64: image.base64, mimeType: image.mimeType)
            }

            ForEach(Array(audio.enumerated()), id: \.offset) { index, clip in
                AsyncAudioBlob(
                    id: "audio-\(index)-\(clip.base64.prefix(24))",
                    base64: clip.base64,
                    mimeType: clip.mimeType
                )
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokyoBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: strippedText.count) {
            guard !isError, !strippedText.isEmpty else { return }
            let text = String(strippedText.prefix(2000))
            ansiAttributed = await Task.detached(priority: .userInitiated) {
                ANSIParser.attributedString(from: text)
            }.value
        }
        .contextMenu {
            if !strippedText.isEmpty {
                Button("Copy Output", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = strippedText
                }
            }
        }
    }
}

// MARK: - Async Image Blob

/// Async image decoder — decodes base64 off main thread.
struct AsyncImageBlob: View {
    let base64: String
    let mimeType: String?

    @State private var decoded: UIImage?
    @State private var decodeFailed = false
    @State private var showFullScreen = false

    var body: some View {
        Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { showFullScreen = true }
                    .contextMenu {
                        Button("Copy Image", systemImage: "doc.on.doc") {
                            UIPasteboard.general.image = decoded
                        }
                    }
                    .fullScreenCover(isPresented: $showFullScreen) {
                        ZoomableImageView(image: decoded)
                    }
            } else if decodeFailed {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.tokyoBgHighlight)
                    .frame(height: 100)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.tokyoComment)
                            Text("Image preview unavailable")
                                .font(.caption2)
                                .foregroundStyle(.tokyoComment)
                            if let mimeType {
                                Text(mimeType)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tokyoComment.opacity(0.7))
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.tokyoBgHighlight)
                    .frame(height: 100)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .task(id: base64.prefix(32)) {
            decodeFailed = false
            decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                    return nil as UIImage?
                }
                return UIImage(data: data)
            }.value
            if decoded == nil {
                decodeFailed = true
            }
        }
    }
}

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
                .foregroundStyle(.tokyoPurple)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.tokyoFg)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tokyoComment)
            }

            Spacer()

            if decodeFailed {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.tokyoRed)
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
                                .tint(.tokyoPurple)
                        } else if isPlaying {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                                .foregroundStyle(.tokyoPurple)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.tokyoComment)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.tokyoBgHighlight)
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

// MARK: - Async Diff View

/// Computes LCS diff off main thread, then renders.
struct AsyncDiffView: View {
    let oldText: String
    let newText: String
    let filePath: String?
    var showHeader: Bool = true

    @State private var ready = false

    var body: some View {
        if ready {
            DiffContentView(
                oldText: oldText,
                newText: newText,
                filePath: filePath,
                showHeader: showHeader
            )
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Computing diff…")
                    .font(.caption)
                    .foregroundStyle(.tokyoComment)
            }
            .padding(8)
            .task {
                try? await Task.sleep(for: .milliseconds(16))
                ready = true
            }
        }
    }
}
