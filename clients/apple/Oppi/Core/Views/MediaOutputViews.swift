import SwiftUI

// MARK: - ImageOutputView

/// Renders image content via ImageExtractor.
///
/// Runs regex extraction off main thread to avoid blocking on large
/// base64 blobs during scroll.
struct ImageOutputView: View {
    let content: String

    @State private var images: [ImageExtractor.ExtractedImage]?

    var body: some View {
        if let images {
            if images.isEmpty {
                Text("Image file (binary content not displayable)")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .italic()
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    ForEach(images) { image in
                        ImageBlobView(base64: image.base64, mimeType: image.mimeType)
                    }
                }
                .padding(8)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .task {
                    let text = content
                    images = await Task.detached(priority: .userInitiated) {
                        ImageExtractor.extract(from: text)
                    }.value
                }
        }
    }
}

// MARK: - AudioOutputView

/// Renders audio content via AudioExtractor.
struct AudioOutputView: View {
    let content: String

    @State private var clips: [AudioExtractor.ExtractedAudio]?

    var body: some View {
        if let clips {
            if clips.isEmpty {
                Text("Audio file (binary content not displayable)")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .italic()
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                        AsyncAudioBlob(
                            id: "file-audio-\(index)-\(clip.base64.prefix(24))",
                            base64: clip.base64,
                            mimeType: clip.mimeType
                        )
                    }
                }
                .padding(8)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .task {
                    let text = content
                    clips = await Task.detached(priority: .userInitiated) {
                        AudioExtractor.extract(from: text)
                    }.value
                }
        }
    }
}
