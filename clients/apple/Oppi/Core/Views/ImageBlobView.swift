import SwiftUI

/// Renders a base64-encoded image with async decoding.
///
/// Decodes the image off the main thread to prevent base64 decode + UIImage
/// init (~5-30ms for typical images) from blocking scrolling.
struct ImageBlobView: View {
    private enum Phase {
        case loading
        case staticImage(UIImage)
        case animated(Data, String?)
        case failure
    }

    let base64: String
    let mimeType: String?

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: 100)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            case .staticImage(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: ImageViewportSizing.maxHeight(for: .singleScreenFit, screenHeight: UIScreen.main.bounds.height)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { FullScreenImageViewController.present(image: image) }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.image = image
                        }
                        Button("Save to Photos", systemImage: "square.and.arrow.down") {
                            PhotoLibrarySaver.save(image)
                        }
                        // ShareLink for simple Transferable image share; FileSharePresenter is for file export flows.
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Image"))
                    }
            case .animated(let data, let mimeType):
                DataImagePreviewView(
                    data: data,
                    mimeType: mimeType,
                    maxPixelSize: 1_600,
                    heightMode: .singleScreenFit,
                    allowsFullscreenStaticImage: false
                )
            case .failure:
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
            }
        }
        .task(id: ImageDecodeCache.decodeKey(for: base64, maxPixelSize: 1600)) {
            phase = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                    return .failure
                }

                let info = ImageMediaInspector.inspect(data: data, mimeType: mimeType)
                if info.prefersWebRenderer {
                    return .animated(data, mimeType)
                }

                if let image = ImageDecodeCache.decode(base64: base64, maxPixelSize: 1600) {
                    return .staticImage(image)
                }

                if MediaMimeType.isSupportedImageMimeType(info.normalizedMimeType) {
                    return .animated(data, MediaMimeType.safeImageMimeType(info.normalizedMimeType))
                }

                return .failure
            }.value
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

        // Use alternation so newlines within base64 are captured but a newline
        // followed by `data:` (start of the next URI) stops the match. Without
        // this, the greedy `[\n\r]` eats into the next data URI when trace text
        // joins multiple images with `\n`.
        let dataUriPattern = /data:image\/([a-zA-Z0-9+.-]+);base64,((?:[A-Za-z0-9+\/=]|[\r\n](?!data:))+)/
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

        // Same boundary-safe alternation as ImageExtractor — prevent greedy
        // over-matching across newline-separated data URIs.
        let dataUriPattern = /data:audio\/([a-zA-Z0-9+.-]+);base64,((?:[A-Za-z0-9+\/=]|[\r\n](?!data:))+)/
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
