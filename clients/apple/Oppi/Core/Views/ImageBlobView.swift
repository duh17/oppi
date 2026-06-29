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
    @State private var staticImageWidth: CGFloat = 0

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
                renderedStaticImage(image)
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

    @ViewBuilder
    private func renderedStaticImage(_ image: UIImage) -> some View {
        let maxHeight = ImageViewportSizing.maxHeight(for: .primaryMedia, screenHeight: UIScreen.main.bounds.height)
        let targetHeight = staticImageTargetHeight(for: image, maxHeight: maxHeight)

        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: targetHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: StaticImageWidthPreferenceKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(StaticImageWidthPreferenceKey.self) { width in
                guard width.isFinite, width > 1, abs(width - staticImageWidth) > 0.5 else { return }
                staticImageWidth = width
            }
    }

    private func staticImageTargetHeight(for image: UIImage, maxHeight: CGFloat?) -> CGFloat? {
        guard image.size.width > 0, image.size.height > 0, staticImageWidth > 1 else { return nil }
        let naturalHeight = staticImageWidth * image.size.height / image.size.width
        return min(maxHeight ?? naturalHeight, naturalHeight)
    }
}

private struct StaticImageWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 1 {
            value = next
        }
    }
}
