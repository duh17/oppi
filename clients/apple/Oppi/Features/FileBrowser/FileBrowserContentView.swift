import Network
import PDFKit
import SwiftUI

enum FileBrowserContentChromeMode {
    case pushed
    case treePane
}

enum FileBrowserTextRenderer: Equatable {
    case embeddedFileViewer
}

enum FileBrowserContentRenderingPolicy {
    static func textRenderer(for chromeMode: FileBrowserContentChromeMode) -> FileBrowserTextRenderer {
        switch chromeMode {
        case .pushed, .treePane:
            return .embeddedFileViewer
        }
    }

    static func showsNavigationChrome(for chromeMode: FileBrowserContentChromeMode) -> Bool {
        chromeMode == .pushed
    }
}

/// Displays the content of a workspace file in browse mode.
///
/// Delegates to `FileContentView` for type-aware rendering:
/// - Markdown: rendered prose via the chat markdown renderer
/// - Code: syntax-highlighted source with line numbers
/// - JSON: pretty-printed with colored tokens
/// - Images: inline preview
/// - Audio: native AVPlayer with playback controls
/// - Video: system video player with playback controls
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
    var chromeMode: FileBrowserContentChromeMode = .pushed

    @Environment(\.apiClient) private var apiClient
    @State private var content: FileContentPhase = .loading
    @State private var isExpensiveNetwork = false

    /// Captured API client reference from when the file was loaded.
    ///
    /// `@Environment(\.apiClient)` can be nil when SwiftUI re-evaluates `body`
    /// after an async state change — the environment value isn't guaranteed to
    /// survive across the `@State` update boundary. We capture it in `loadContent()`
    /// when we know it's non-nil (since we just used it to load the file).
    @State private var loadedApiClient: APIClient?

    private var fileExtension: String {
        fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
    }

    /// Determine preview behavior using Oppi's canonical file-type detector.
    /// This avoids `.ts` being misclassified as MPEG transport stream video.
    private var mediaCategory: FilePreviewCategory {
        FileType.detect(from: filePath).previewCategory
    }

    /// Whether the UIKit file viewer is active (text content loaded).
    /// When true, the SwiftUI navigation bar is hidden and the UIKit
    /// viewer's internal nav bar provides all chrome.
    private var isUsingFileViewer: Bool {
        if case .text = content { return true }
        return false
    }

    private var shouldUseEmbeddedFileViewer: Bool {
        FileBrowserContentRenderingPolicy.textRenderer(for: chromeMode) == .embeddedFileViewer
    }

    private var shouldShowEmbeddedNavigationChrome: Bool {
        FileBrowserContentRenderingPolicy.showsNavigationChrome(for: chromeMode)
    }

    private var shouldHideHostNavigationBar: Bool {
        shouldShowEmbeddedNavigationChrome && isUsingFileViewer
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
                if shouldUseEmbeddedFileViewer {
                    EmbeddedFileViewerView(
                        content: fullScreenContent(text: text),
                        showsNavigationChrome: shouldShowEmbeddedNavigationChrome
                    )
                    .ignoresSafeArea(edges: shouldShowEmbeddedNavigationChrome ? .top : [])
                } else {
                    inlineTextView(text)
                }
            case .image(let data):
                imageView(data)
            case .video(let source):
                videoView(source)
            case .audio(let source):
                audioView(source)
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
        .navigationTitle(shouldHideHostNavigationBar ? "" : fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(shouldHideHostNavigationBar ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if chromeMode == .pushed, !isUsingFileViewer {
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

    @ViewBuilder
    private func inlineTextView(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.themeFg)
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.themeBg)
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
        ScrollView {
            DataImagePreviewView(
                data: data,
                mimeType: MediaMimeType.imageMimeType(forPathExtension: fileExtension),
                maxPixelSize: 2_400,
                heightMode: .unrestricted
            )
            .padding()
        }
    }

    // MARK: - Video View

    @ViewBuilder
    private func videoView(_ source: AuthenticatedMediaSource) -> some View {
        AuthenticatedMediaPlayerView(
            source: source,
            height: min(max(UIScreen.main.bounds.height * 0.34, 220), 420),
            unavailableTitle: "Video preview unavailable",
            unavailableSystemImage: "film.slash"
        )
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
    }

    @ViewBuilder
    private func audioView(_ source: AuthenticatedMediaSource) -> some View {
        AuthenticatedMediaPlayerView(
            source: source,
            height: 220,
            unavailableTitle: "Audio preview unavailable",
            unavailableSystemImage: "speaker.slash"
        )
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.themeBg)
    }

    // MARK: - Loading

    private func loadContent(force: Bool = false) async {
        guard let api = apiClient else {
            content = .error("Not connected")
            return
        }

        // Capture the API client while we know it's non-nil.
        // See loadedApiClient comment for why this is needed.
        loadedApiClient = api

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
                let source = try await api.makeWorkspaceMediaSource(
                    workspaceId: workspaceId,
                    path: filePath,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: fileExtension),
                    sourceFileExtension: fileExtension
                )
                content = .video(source)
            case .audio:
                let source = try await api.makeWorkspaceMediaSource(
                    workspaceId: workspaceId,
                    path: filePath,
                    contentTypeHint: MediaMimeType.audioMimeType(forPathExtension: fileExtension),
                    sourceFileExtension: fileExtension
                )
                content = .audio(source)
            case .image, .pdf, .text, .binary:
                let data = try await api.browseWorkspaceFile(workspaceId: workspaceId, path: filePath)
                switch category {
                case .image: content = .image(data)
                case .pdf: content = .pdf(data)
                case .binary: content = .binary
                case .text:
                    if let text = String(data: data, encoding: .utf8) {
                        content = .text(text)
                    } else {
                        content = .binary
                    }
                default:
                    content = .binary
                }
            }
        } catch {
            content = .error(error.localizedDescription)
        }
    }

    // MARK: - Full-screen content

    /// Build full-screen content with workspace context for relative image resolution.
    ///
    /// Uses `loadedApiClient` (captured during `loadContent()`) instead of the current
    /// `@Environment(\.apiClient)` because environment values can be nil when SwiftUI
    /// re-evaluates `body` after an async state change. The captured reference is
    /// guaranteed non-nil since we used it to successfully load the file.
    private func fullScreenContent(text: String) -> FullScreenCodeContent {
        guard let api = loadedApiClient ?? apiClient else {
            return .fromText(text, filePath: filePath)
        }
        return .fromText(
            text,
            filePath: filePath,
            workspaceContext: .init(
                workspaceID: workspaceId,
                serverBaseURL: api.baseURL,
                fetchWorkspaceFile: { [workspaceId] wsID, filePath in
                    try await api.browseWorkspaceFile(
                        workspaceId: wsID.isEmpty ? workspaceId : wsID,
                        path: filePath
                    )
                }
            )
        )
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

// MARK: - Phase

private enum FileContentPhase: Equatable {
    case loading
    case sizeWarning(Int)
    case error(String)
    case text(String)
    case image(Data)
    case video(AuthenticatedMediaSource)
    case audio(AuthenticatedMediaSource)
    case pdf(Data)
    case binary

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): true
        case (.sizeWarning(let a), .sizeWarning(let b)): a == b
        case (.error(let a), .error(let b)): a == b
        case (.text(let a), .text(let b)): a == b
        case (.image(let a), .image(let b)): a == b
        case (.video(let a), .video(let b)): a.identity == b.identity
        case (.audio(let a), .audio(let b)): a.identity == b.identity
        case (.pdf(let a), .pdf(let b)): a == b
        case (.binary, .binary): true
        default: false
        }
    }
}
