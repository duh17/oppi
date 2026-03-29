import AVKit
import Network
import PDFKit
import SwiftUI

/// Displays the content of a workspace file in browse mode.
///
/// Delegates to `FileContentView` for type-aware rendering:
/// - Markdown: rendered prose via the chat markdown renderer
/// - Code: syntax-highlighted source with line numbers
/// - JSON: pretty-printed with colored tokens
/// - Images: inline preview
/// - Video/Audio: native AVPlayer with playback controls
/// - PDF: PDFKit with scroll, zoom, and text selection
/// - Plain text: monospaced with line numbers
///
/// Large text files (>1MB) show a size warning before loading.
/// On cellular networks, an additional data warning is displayed.
struct FileBrowserContentView: View {
    let workspaceId: String
    let filePath: String
    let fileName: String
    /// Known file size from directory listing. Nil when opened from search results.
    var fileSize: Int?

    @Environment(\.apiClient) private var apiClient
    @State private var content: FileContentPhase = .loading
    @State private var isExpensiveNetwork = false

    private var fileExtension: String {
        fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
    }

    /// Determine the media category for this file extension.
    private var mediaCategory: MediaCategory {
        switch fileExtension {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff":
            return .image
        case "mp4", "mov", "m4v", "avi", "webm":
            return .video
        case "mp3", "m4a", "wav", "aac", "ogg", "flac", "opus":
            return .audio
        case "pdf":
            return .pdf
        default:
            return .text
        }
    }

    /// Whether the UIKit file viewer is active (text content loaded).
    /// When true, the SwiftUI navigation bar is hidden and the UIKit
    /// viewer's internal nav bar provides all chrome.
    private var isUsingFileViewer: Bool {
        if case .text = content { return true }
        return false
    }

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .sizeWarning(let bytes):
                fileSizeWarningView(bytes: bytes)
            case .error(let message):
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .text(let text):
                EmbeddedFileViewerView(
                    content: .fromText(text, filePath: filePath)
                )
                .ignoresSafeArea(edges: .top)
            case .image(let data):
                imageView(data)
            case .video(let url):
                VideoBrowserView(url: url)
            case .audio(let url):
                AudioBrowserView(url: url, fileName: fileName)
            case .pdf(let data):
                PDFBrowserView(data: data)
            case .binary:
                ContentUnavailableView(
                    "Binary File",
                    systemImage: "doc.fill",
                    description: Text("This file type cannot be displayed as text.")
                )
            }
        }
        .background(Color.themeBg)
        .navigationTitle(isUsingFileViewer ? "" : fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(isUsingFileViewer ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if !isUsingFileViewer {
                ToolbarItem(placement: .topBarTrailing) {
                    if let shareable = shareableContent() {
                        FileShareButton(content: shareable, style: .icon)
                    }
                }
            }
        }
        .task { await loadContent() }
        .task { await checkNetworkCost() }
    }

    // MARK: - Size Warning

    /// Threshold for showing a file size warning (1 MB).
    private static let sizeWarningThreshold = 1_024 * 1_024

    @ViewBuilder
    private func fileSizeWarningView(bytes: Int) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.themeComment)

            Text(fileName)
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text(SessionFormatting.byteCount(bytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.themeComment)

            VStack(spacing: 8) {
                Label("Large file — loading may be slow", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.themeYellow)

                if isExpensiveNetwork {
                    Label("You're on a cellular connection", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.callout)
                        .foregroundStyle(.themeOrange)
                }
            }
            .padding(.top, 4)

            Button {
                Task { await loadContent(force: true) }
            } label: {
                Text("Load File")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.themeSyntaxKeyword)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Image View

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        if let uiImage = UIImage(data: data) {
            ScrollView {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
        } else {
            ContentUnavailableView(
                "Invalid Image",
                systemImage: "photo.badge.exclamationmark",
                description: Text("Could not decode image data.")
            )
        }
    }

    // MARK: - Loading

    private func loadContent(force: Bool = false) async {
        guard let api = apiClient else {
            content = .error("Not connected")
            return
        }

        // For text files with known size above threshold, show a warning first.
        if !force, mediaCategory == .text,
           let size = fileSize, size > Self.sizeWarningThreshold
        {
            content = .sizeWarning(size)
            return
        }

        content = .loading

        do {
            let category = mediaCategory

            switch category {
            case .video:
                let url = try await api.browseFileStreamURL(workspaceId: workspaceId, path: filePath)
                content = .video(url)
            case .audio:
                let url = try await api.browseFileStreamURL(workspaceId: workspaceId, path: filePath)
                content = .audio(url)
            case .image, .pdf, .text:
                let data = try await api.browseWorkspaceFile(workspaceId: workspaceId, path: filePath)
                switch category {
                case .image: content = .image(data)
                case .pdf: content = .pdf(data)
                default:
                    if let text = String(data: data, encoding: .utf8) {
                        content = .text(text)
                    } else {
                        content = .binary
                    }
                }
            }
        } catch {
            content = .error(error.localizedDescription)
        }
    }

    // MARK: - Share

    /// Build shareable content from the current loaded phase.
    private func shareableContent() -> FileShareService.ShareableContent? {
        switch content {
        case .text(let text):
            return .fromText(text, filePath: filePath)
        case .image(let data):
            return .imageData(data, filename: fileName)
        case .pdf(let data):
            return .pdfData(data, filename: fileName)
        default:
            return nil
        }
    }

    // MARK: - Network

    /// One-shot check for expensive network (cellular, hotspot).
    private func checkNetworkCost() async {
        let expensive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.isExpensive)
            }
            monitor.start(queue: DispatchQueue(label: "com.oppi.file-browser-net-check"))
        }
        isExpensiveNetwork = expensive
    }
}

// MARK: - Video View

/// Full-featured video player with native AVKit controls.
/// Streams directly from the server URL — no download or temp files.
private struct VideoBrowserView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                player = AVPlayer(url: url)
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

// MARK: - Audio View

/// Audio player with playback controls, centered in the view.
private struct AudioBrowserView: View {
    let url: URL
    let fileName: String
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Album art placeholder
            Image(systemName: "waveform")
                .font(.system(size: 60))
                .foregroundStyle(.themeComment)

            Text(fileName)
                .font(.headline)
                .foregroundStyle(.themeFg)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Progress bar
            VStack(spacing: 4) {
                ProgressView(value: duration > 0 ? currentTime / duration : 0)
                    .tint(.themeSyntaxKeyword)

                HStack {
                    Text(formatTime(currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.themeComment)
                    Spacer()
                    Text(formatTime(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.themeComment)
                }
            }
            .padding(.horizontal, 40)

            // Play/pause button
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.themeSyntaxKeyword)
            }

            Spacer()
        }
        .padding()
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
    }

    private func setupPlayer() {
        let avPlayer = AVPlayer(url: url)
        player = avPlayer

        // Observe playback time at 10Hz
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds
            if let item = avPlayer.currentItem {
                let dur = item.duration.seconds
                if dur.isFinite { duration = dur }
            }
        }

        // Observe when playback ends
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
        }
    }

    private func teardownPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player?.pause()
        player = nil
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            // If at end, seek to start
            if currentTime >= duration - 0.1, duration > 0 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

// MARK: - PDF View

/// Wraps `PDFKit.PDFView` for inline PDF rendering with scroll, zoom, and text selection.
private struct PDFBrowserView: View {
    let data: Data

    var body: some View {
        if PDFDocument(data: data) != nil {
            PDFKitView(data: data)
                .ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView(
                "Invalid PDF",
                systemImage: "doc.badge.exclamationmark",
                description: Text("Could not decode PDF data.")
            )
        }
    }
}

/// UIKit wrapper for `PDFKit.PDFView`.
private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

// MARK: - Media Category

private enum MediaCategory {
    case image, video, audio, pdf, text
}

// MARK: - Phase

private enum FileContentPhase: Equatable {
    case loading
    case sizeWarning(Int)
    case error(String)
    case text(String)
    case image(Data)
    case video(URL)
    case audio(URL)
    case pdf(Data)
    case binary

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): true
        case (.sizeWarning(let a), .sizeWarning(let b)): a == b
        case (.error(let a), .error(let b)): a == b
        case (.text(let a), .text(let b)): a == b
        case (.image(let a), .image(let b)): a == b
        case (.video(let a), .video(let b)): a == b
        case (.audio(let a), .audio(let b)): a == b
        case (.pdf(let a), .pdf(let b)): a == b
        case (.binary, .binary): true
        default: false
        }
    }
}
