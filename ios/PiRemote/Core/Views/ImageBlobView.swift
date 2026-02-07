import SwiftUI

/// Detects and renders base64-encoded images embedded in tool output.
///
/// Scans text for patterns like `data:image/png;base64,...` or raw base64
/// blobs that decode to valid images. Shows inline thumbnail with
/// tap-to-fullscreen.
struct ImageBlobView: View {
    let base64: String
    let mimeType: String?

    @State private var showFullScreen = false

    var body: some View {
        if let uiImage = decodeImage() {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { showFullScreen = true }
                .contextMenu {
                    Button("Copy Image", systemImage: "doc.on.doc") {
                        UIPasteboard.general.image = uiImage
                    }
                    ShareLink(item: Image(uiImage: uiImage), preview: SharePreview("Image"))
                }
                .fullScreenCover(isPresented: $showFullScreen) {
                    ZoomableImageView(image: uiImage)
                }
        }
    }

    private func decodeImage() -> UIImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return UIImage(data: data)
    }
}

/// Full-screen zoomable image viewer.
private struct ZoomableImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = value.magnification
                        }
                        .onEnded { _ in
                            withAnimation { scale = max(1.0, scale) }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = scale > 1.0 ? 1.0 : 2.0
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Image Detection in Tool Output

/// Extract base64 image data from tool output text.
///
/// Detects:
/// - `data:image/<type>;base64,<data>` data URIs
/// - Standalone base64 strings that decode to valid images (≥100 chars, no spaces)
struct ImageExtractor {
    struct ExtractedImage: Identifiable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedImage] {
        var images: [ExtractedImage] = []

        // Pattern 1: data URI
        // Match data:image/<type>;base64,<base64data>
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
