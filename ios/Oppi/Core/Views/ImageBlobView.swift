import SwiftUI

/// Renders a base64-encoded image with async decoding.
///
/// Decodes the image off the main thread to prevent base64 decode + UIImage
/// init (~5-30ms for typical images) from blocking scrolling.
struct ImageBlobView: View {
    let base64: String
    let mimeType: String?

    @State private var decoded: UIImage?
    @State private var decodeFailed = false

    var body: some View {
        Group {
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { FullScreenImageViewController.present(image: decoded) }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.image = decoded
                        }
                        Button("Save to Photos", systemImage: "square.and.arrow.down") {
                            PhotoLibrarySaver.save(decoded)
                        }
                        ShareLink(item: Image(uiImage: decoded), preview: SharePreview("Image"))
                    }
            } else if decodeFailed {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: 100)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                            Text("Image preview unavailable")
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                            if let mimeType {
                                Text(mimeType)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.themeComment.opacity(0.7))
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: 100)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .task(id: ImageDecodeCache.decodeKey(for: base64, maxPixelSize: 1600)) {
            decodeFailed = false
            decoded = await Task.detached(priority: .userInitiated) {
                ImageDecodeCache.decode(base64: base64, maxPixelSize: 1600)
            }.value
            if decoded == nil {
                decodeFailed = true
            }
        }
    }
}

// MARK: - Image Detection in Tool Output

/// Extract base64 image data from tool output text.
///
/// Detects `data:image/<type>;base64,<data>` data URIs.
struct ImageExtractor {
    struct ExtractedImage: Identifiable, Sendable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedImage] {
        var images: [ExtractedImage] = []

        let dataUriPattern = /data:image\/([a-zA-Z0-9+.-]+);base64,([A-Za-z0-9+\/=\n\r]+)/
        for match in text.matches(of: dataUriPattern) {
            let mimeType = "image/" + String(match.output.1)
            let base64 = String(match.output.2)
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            images.append(ExtractedImage(
                base64: base64,
                mimeType: mimeType,
                range: match.range
            ))
        }

        return images
    }
}

/// Extract base64 audio data from tool output text.
///
/// Detects `data:audio/<type>;base64,<data>` data URIs.
struct AudioExtractor {
    struct ExtractedAudio: Identifiable, Sendable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedAudio] {
        var audio: [ExtractedAudio] = []

        let dataUriPattern = /data:audio\/([a-zA-Z0-9+.-]+);base64,([A-Za-z0-9+\/=\n\r]+)/
        for match in text.matches(of: dataUriPattern) {
            let mimeType = "audio/" + String(match.output.1)
            let base64 = String(match.output.2)
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            audio.append(ExtractedAudio(
                base64: base64,
                mimeType: mimeType,
                range: match.range
            ))
        }

        return audio
    }
}
