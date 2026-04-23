import AVFoundation
import AVKit
import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import WebKit

// MARK: - MIME Helpers

enum MediaMimeType {
    static func normalized(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let trimmed = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: ";", maxSplits: 1).first.map(String.init)
    }

    static func imageMimeType(forPathExtension pathExtension: String?) -> String? {
        switch (pathExtension ?? "").lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        default: return nil
        }
    }

    static func videoMimeType(forPathExtension pathExtension: String?) -> String? {
        switch (pathExtension ?? "").lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "ogv": return "video/ogg"
        default: return nil
        }
    }

    static func audioMimeType(forPathExtension pathExtension: String?) -> String? {
        switch (pathExtension ?? "").lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aif", "aiff", "aifc": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "ogg", "oga": return "audio/ogg"
        case "flac": return "audio/flac"
        case "opus": return "audio/opus"
        default: return nil
        }
    }

    static func preferredFileExtension(forVideo mimeType: String?, fallbackPathExtension: String? = nil) -> String {
        if let fallback = sanitizedPathExtension(fallbackPathExtension) {
            return fallback
        }

        switch normalized(mimeType) {
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/x-msvideo": return "avi"
        default: return "mp4"
        }
    }

    static func preferredFileExtension(forAudio mimeType: String?, fallbackPathExtension: String? = nil) -> String {
        if let fallback = sanitizedPathExtension(fallbackPathExtension) {
            return fallback
        }

        switch normalized(mimeType) {
        case "audio/mpeg": return "mp3"
        case "audio/wav": return "wav"
        case "audio/aiff": return "aiff"
        case "audio/x-caf": return "caf"
        case "audio/ogg": return "ogg"
        case "audio/flac": return "flac"
        case "audio/opus": return "opus"
        default: return "m4a"
        }
    }

    private static func sanitizedPathExtension(_ pathExtension: String?) -> String? {
        guard let pathExtension else { return nil }
        let trimmed = pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Temporary Media Files

enum MediaTempFileStore {
    private static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("inline-media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheKey(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(for data: Data, preferredExtension: String) throws -> URL {
        let directory = try cacheDirectory()
        let filename = "media-\(cacheKey(for: data)).\(preferredExtension)"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }
}

// MARK: - Image Inspection

enum ImageMediaInspector {
    struct Info {
        let normalizedMimeType: String?
        let isAnimated: Bool
        let pixelSize: CGSize?

        var aspectRatio: CGFloat? {
            guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
            return pixelSize.width / pixelSize.height
        }

        var prefersWebRenderer: Bool {
            isAnimated || normalizedMimeType == "image/svg+xml"
        }
    }

    static func inspect(data: Data, mimeType: String?) -> Info {
        let normalizedMimeType = MediaMimeType.normalized(mimeType)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return Info(normalizedMimeType: normalizedMimeType, isAnimated: false, pixelSize: nil)
        }

        let frameCount = CGImageSourceGetCount(source)
        let pixelSize: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0,
           height > 0 {
            pixelSize = CGSize(width: width, height: height)
        } else {
            pixelSize = nil
        }

        return Info(
            normalizedMimeType: normalizedMimeType,
            isAnimated: frameCount > 1,
            pixelSize: pixelSize
        )
    }

    static func downsampledImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded())),
        ]

        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }

        return UIImage(data: data)
    }
}

// MARK: - Animated Image Web View

final class AnimatedImageWebContainerView: UIView {
    private let webView: PiWKWebView
    private var loadedSignature: Int?

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        self.webView = PiWKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(dataURLString: String) {
        var hasher = Hasher()
        hasher.combine(dataURLString.count)
        hasher.combine(dataURLString.prefix(128))
        hasher.combine(dataURLString.suffix(128))
        let signature = hasher.finalize()
        guard signature != loadedSignature else { return }
        loadedSignature = signature

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1\">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              overflow: hidden;
              width: 100%;
              height: 100%;
            }
            body {
              display: flex;
              align-items: center;
              justify-content: center;
            }
            img {
              display: block;
              max-width: 100%;
              max-height: 100%;
              width: 100%;
              height: 100%;
              object-fit: contain;
            }
          </style>
        </head>
        <body>
          <img src=\"\(dataURLString)\" />
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
    }

    private func setupViews() {
        backgroundColor = .clear
        clipsToBounds = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

struct AnimatedImageWebView: UIViewRepresentable {
    let dataURLString: String

    func makeUIView(context: Context) -> AnimatedImageWebContainerView {
        AnimatedImageWebContainerView()
    }

    func updateUIView(_ uiView: AnimatedImageWebContainerView, context: Context) {
        uiView.apply(dataURLString: dataURLString)
    }
}

// MARK: - SwiftUI Image Preview

struct DataImagePreviewView: View {
    private enum Phase {
        case loading
        case staticImage(UIImage, CGFloat?)
        case animated(String, CGFloat?)
        case failure
    }

    let data: Data
    let mimeType: String?
    var maxPixelSize: CGFloat = 1_600
    var maxHeight: CGFloat? = 300
    var allowsFullscreenStaticImage = true

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
                        }
                    }
            case .staticImage(let image, let aspectRatio):
                renderedImage(
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .onTapGesture {
                            guard allowsFullscreenStaticImage else { return }
                            FullScreenImageViewController.present(image: image)
                        },
                    aspectRatio: aspectRatio
                )
            case .animated(let dataURLString, let aspectRatio):
                renderedImage(
                    AnimatedImageWebView(dataURLString: dataURLString),
                    aspectRatio: aspectRatio
                )
            }
        }
        .task(id: cacheKey) {
            phase = await Task.detached(priority: .userInitiated) {
                let info = ImageMediaInspector.inspect(data: data, mimeType: mimeType)
                let aspectRatio = info.aspectRatio
                if info.prefersWebRenderer {
                    let normalizedMimeType = info.normalizedMimeType ?? "image/gif"
                    let dataURLString = "data:\(normalizedMimeType);base64,\(data.base64EncodedString())"
                    return Phase.animated(dataURLString, aspectRatio)
                }

                if let image = ImageMediaInspector.downsampledImage(data: data, maxPixelSize: maxPixelSize) {
                    return Phase.staticImage(image, aspectRatio)
                }

                if let normalizedMimeType = info.normalizedMimeType,
                   normalizedMimeType.hasPrefix("image/") {
                    let dataURLString = "data:\(normalizedMimeType);base64,\(data.base64EncodedString())"
                    return Phase.animated(dataURLString, aspectRatio)
                }

                return .failure
            }.value
        }
    }

    private var cacheKey: String {
        let mime = MediaMimeType.normalized(mimeType) ?? "image/unknown"
        return "\(mime)-\(data.count)-\(data.prefix(32))-\(data.suffix(32))-\(maxPixelSize)"
    }

    @ViewBuilder
    private func renderedImage<Content: View>(_ content: Content, aspectRatio: CGFloat?) -> some View {
        let base = content
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)

        if let aspectRatio {
            if let maxHeight {
                base
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxHeight: maxHeight)
            } else {
                base.aspectRatio(aspectRatio, contentMode: .fit)
            }
        } else if let maxHeight {
            base.frame(maxHeight: maxHeight)
        } else {
            base.frame(minHeight: 160)
        }
    }
}

// MARK: - Video Extraction + Playback

struct VideoExtractor {
    struct ExtractedVideo: Identifiable, Sendable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedVideo] {
        var videos: [ExtractedVideo] = []
        let dataUriPattern = /data:video\/([a-zA-Z0-9+.-]+);base64,((?:[A-Za-z0-9+\/=]|[\r\n](?!data:))+)/
        for match in text.matches(of: dataUriPattern) {
            let mimeType = "video/" + String(match.output.1)
            let base64 = String(match.output.2)
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            videos.append(ExtractedVideo(base64: base64, mimeType: mimeType, range: match.range))
        }
        return videos
    }
}

struct Base64VideoBlobView: View {
    let base64: String
    let mimeType: String?
    var height: CGFloat = 220

    @State private var decodedData: Data?
    @State private var decodeFailed = false

    var body: some View {
        Group {
            if let decodedData {
                DataVideoPlayerView(data: decodedData, mimeType: mimeType, height: height)
            } else if decodeFailed {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: height)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "video.slash")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                            Text("Video preview unavailable")
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: height)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
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

private enum LocalMediaKind {
    case video
    case audio

    var unavailableSymbol: String {
        switch self {
        case .video: "video.slash"
        case .audio: "speaker.slash"
        }
    }

    var unavailableLabel: String {
        switch self {
        case .video: "Video preview unavailable"
        case .audio: "Audio preview unavailable"
        }
    }
}

@MainActor
private final class LocalMediaPlaybackModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentPlayerItem: AVPlayerItem?
    private var preparedKey: String?
    private var cleanupFileURL: URL?

    func prepare(
        data: Data,
        preferredExtension: String,
        cacheKey: String,
        autoplay: Bool,
        loops: Bool,
        muteByDefault: Bool
    ) async {
        guard preparedKey != cacheKey else { return }

        teardown(resetPreparedKey: false)
        preparedKey = cacheKey
        isLoading = true
        errorMessage = nil

        do {
            let fileURL = try await Task.detached(priority: .userInitiated) {
                try MediaTempFileStore.fileURL(for: data, preferredExtension: preferredExtension)
            }.value
            configurePlayer(
                fileURL: fileURL,
                autoplay: autoplay,
                loops: loops,
                muteByDefault: muteByDefault,
                cleanupOnTeardown: false
            )
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            player = nil
        }
    }

    func prepare(
        fileURL: URL,
        cacheKey: String,
        autoplay: Bool,
        loops: Bool,
        muteByDefault: Bool,
        cleanupOnTeardown: Bool
    ) {
        guard preparedKey != cacheKey else { return }

        teardown(resetPreparedKey: false)
        preparedKey = cacheKey
        isLoading = true
        errorMessage = nil

        configurePlayer(
            fileURL: fileURL,
            autoplay: autoplay,
            loops: loops,
            muteByDefault: muteByDefault,
            cleanupOnTeardown: cleanupOnTeardown
        )
    }

    private func configurePlayer(
        fileURL: URL,
        autoplay: Bool,
        loops: Bool,
        muteByDefault: Bool,
        cleanupOnTeardown: Bool
    ) {
        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: [
                "playable",
                "tracks",
                "duration",
                "hasProtectedContent",
            ]
        )
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = muteByDefault

        currentPlayerItem = item
        cleanupFileURL = cleanupOnTeardown ? fileURL : nil
        self.player = player

        if loops {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                if autoplay {
                    player.play()
                }
            }
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.errorMessage = nil
                    if autoplay {
                        player.play()
                    }
                case .failed:
                    self.isLoading = false
                    self.errorMessage = item.error?.localizedDescription ?? "Media failed to load"
                    player.pause()
                    self.player = nil
                case .unknown:
                    self.isLoading = true
                @unknown default:
                    self.isLoading = false
                    self.errorMessage = "Unsupported media state"
                    self.player = nil
                }
            }
        }
    }

    func teardown(resetPreparedKey: Bool = true) {
        statusObservation?.invalidate()
        statusObservation = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        player?.pause()
        player = nil
        currentPlayerItem = nil
        isLoading = false

        if let cleanupFileURL {
            try? FileManager.default.removeItem(at: cleanupFileURL)
            self.cleanupFileURL = nil
        }

        if resetPreparedKey {
            preparedKey = nil
        }
    }

}

private struct AVPlayerViewControllerContainer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.player = player
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        uiViewController.showsPlaybackControls = true
    }
}

private enum LocalMediaSource {
    case data(Data, preferredExtension: String)
    case fileURL(URL, cleanupOnTeardown: Bool)
}

private struct LocalMediaPlayerView: View {
    let source: LocalMediaSource
    let kind: LocalMediaKind
    var height: CGFloat
    var autoplay: Bool
    var loops: Bool
    var muteByDefault: Bool

    @StateObject private var model = LocalMediaPlaybackModel()

    var body: some View {
        Group {
            if let player = model.player {
                AVPlayerViewControllerContainer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let errorMessage = model.errorMessage {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: height)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: kind.unavailableSymbol)
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                            Text(kind.unavailableLabel)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundStyle(.themeComment.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 12)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.themeBgHighlight)
                    .frame(height: height)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .task(id: cacheKey) {
            switch source {
            case .data(let data, let preferredExtension):
                await model.prepare(
                    data: data,
                    preferredExtension: preferredExtension,
                    cacheKey: cacheKey,
                    autoplay: autoplay,
                    loops: loops,
                    muteByDefault: muteByDefault
                )
            case .fileURL(let fileURL, let cleanupOnTeardown):
                model.prepare(
                    fileURL: fileURL,
                    cacheKey: cacheKey,
                    autoplay: autoplay,
                    loops: loops,
                    muteByDefault: muteByDefault,
                    cleanupOnTeardown: cleanupOnTeardown
                )
            }
        }
        .onDisappear {
            model.teardown()
        }
    }

    private var cacheKey: String {
        switch source {
        case .data(let data, let preferredExtension):
            let ext = preferredExtension.lowercased()
            return "\(kind)-data-\(ext)-\(data.count)-\(data.prefix(32))-\(data.suffix(32))"
        case .fileURL(let fileURL, _):
            return "\(kind)-url-\(fileURL.path)"
        }
    }
}

struct DataVideoPlayerView: View {
    let data: Data
    let mimeType: String?
    var sourceFileExtension: String? = nil
    var height: CGFloat = 220
    var autoplay = true
    var loops = true

    var body: some View {
        LocalMediaPlayerView(
            source: .data(
                data,
                preferredExtension: MediaMimeType.preferredFileExtension(
                    forVideo: mimeType,
                    fallbackPathExtension: sourceFileExtension
                )
            ),
            kind: .video,
            height: height,
            autoplay: autoplay,
            loops: loops,
            muteByDefault: false
        )
    }
}

struct FileURLVideoPlayerView: View {
    let fileURL: URL
    var height: CGFloat = 220
    var autoplay = true
    var loops = true
    var cleanupOnDisappear = false

    var body: some View {
        LocalMediaPlayerView(
            source: .fileURL(fileURL, cleanupOnTeardown: cleanupOnDisappear),
            kind: .video,
            height: height,
            autoplay: autoplay,
            loops: loops,
            muteByDefault: false
        )
    }
}

struct DataAudioPlayerView: View {
    let data: Data
    let mimeType: String?
    var sourceFileExtension: String? = nil
    var height: CGFloat = 140
    var autoplay = false

    var body: some View {
        LocalMediaPlayerView(
            source: .data(
                data,
                preferredExtension: MediaMimeType.preferredFileExtension(
                    forAudio: mimeType,
                    fallbackPathExtension: sourceFileExtension
                )
            ),
            kind: .audio,
            height: height,
            autoplay: autoplay,
            loops: false,
            muteByDefault: false
        )
    }
}

struct FileURLAudioPlayerView: View {
    let fileURL: URL
    var height: CGFloat = 140
    var autoplay = false
    var cleanupOnDisappear = false

    var body: some View {
        LocalMediaPlayerView(
            source: .fileURL(fileURL, cleanupOnTeardown: cleanupOnDisappear),
            kind: .audio,
            height: height,
            autoplay: autoplay,
            loops: false,
            muteByDefault: false
        )
    }
}
