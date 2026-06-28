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
    var navigationContext: FileBrowserNavigationContext?
    var onNavigationSelectionChange: ((FileBrowserSelection) -> Void)?
    var onBackNavigation: (() -> Void)?

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @State private var activeSelection: FileBrowserSelection?
    @State private var fileTransitionDirection: FileBrowserNavigationDirection = .next
    @State private var content: FileContentPhase = .loading
    @State private var isExpensiveNetwork = false

    /// Captured API client reference from when the file was loaded.
    ///
    /// `@Environment(\.apiClient)` can be nil when SwiftUI re-evaluates `body`
    /// after an async state change — the environment value isn't guaranteed to
    /// survive across the `@State` update boundary. We capture it in `loadContent()`
    /// when we know it's non-nil (since we just used it to load the file).
    @State private var loadedApiClient: APIClient?

    private var currentSelection: FileBrowserSelection {
        activeSelection ?? FileBrowserSelection(path: filePath, name: fileName, size: fileSize)
    }

    private var currentFilePath: String { currentSelection.path }
    private var currentFileName: String { currentSelection.name }

    private var fileExtension: String {
        (currentFilePath as NSString).pathExtension.lowercased()
    }

    /// Determine preview behavior using Oppi's canonical file-type detector.
    /// This avoids `.ts` being misclassified as MPEG transport stream video.
    private var mediaCategory: FilePreviewCategory {
        FileType.detect(from: currentFilePath).previewCategory
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

    private var parentOwnsBackSwipe: Bool {
        switch content {
        case .text:
            return !shouldUseEmbeddedFileViewer
        case .pdf:
            return false
        case .loading, .sizeWarning, .error, .image, .video, .audio, .binary:
            return true
        }
    }

    var body: some View {
        fileContent
            .filePushTransition(id: currentFilePath, direction: fileTransitionDirection)
            .background(Color.themeBg)
            .horizontalBackSwipeGesture(isEnabled: parentOwnsBackSwipe, navigateBackToFileList)
            .overlay(alignment: .bottom) {
                fileNavigatorControls
                    .padding(.bottom, 22)
            }
        .navigationTitle(shouldHideHostNavigationBar ? "" : currentFileName)
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
        .task(id: currentFilePath) { await loadContent() }
        .task { await checkNetworkCost() }
        .onChange(of: filePath) { _, _ in
            activeSelection = nil
            content = .loading
        }
    }

    @ViewBuilder
    private var fileContent: some View {
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
                    showsNavigationChrome: shouldShowEmbeddedNavigationChrome,
                    backSwipeAction: navigateBackToFileList
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
            PDFBrowserView(data: data, onBackSwipe: navigateBackToFileList)
        case .binary:
            ContentUnavailableView(
                "Binary File",
                systemImage: "doc.fill",
                description: Text("This file type cannot be displayed as text.")
            )
        }
    }

    private var fileNavigatorControls: some View {
        AdjacentFileNavigatorControls(
            canGoPrevious: adjacentSelection(.previous) != nil,
            canGoNext: adjacentSelection(.next) != nil,
            onPrevious: { navigateToAdjacentFile(.previous) },
            onNext: { navigateToAdjacentFile(.next) }
        )
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

            Text(currentFileName)
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

        let requestedSelection = currentSelection
        let requestedPath = requestedSelection.path
        let requestedExtension = (requestedPath as NSString).pathExtension.lowercased()
        let requestedCategory = FileType.detect(from: requestedPath).previewCategory

        // Capture the API client while we know it's non-nil.
        // See loadedApiClient comment for why this is needed.
        loadedApiClient = api

        // For text files with known size above threshold, show a warning first.
        if !force, requestedCategory == .text,
           let size = requestedSelection.size, size > Self.sizeWarningThreshold
        {
            content = .sizeWarning(size)
            return
        }

        content = .loading

        do {
            switch requestedCategory {
            case .video:
                let source = try await api.makeWorkspaceMediaSource(
                    workspaceId: workspaceId,
                    path: requestedPath,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: requestedExtension),
                    sourceFileExtension: requestedExtension
                )
                guard isCurrentFile(requestedPath) else { return }
                content = .video(source)
            case .audio:
                let source = try await api.makeWorkspaceMediaSource(
                    workspaceId: workspaceId,
                    path: requestedPath,
                    contentTypeHint: MediaMimeType.audioMimeType(forPathExtension: requestedExtension),
                    sourceFileExtension: requestedExtension
                )
                guard isCurrentFile(requestedPath) else { return }
                content = .audio(source)
            case .image, .pdf, .text, .binary:
                let data = try await api.browseWorkspaceFile(workspaceId: workspaceId, path: requestedPath)
                guard isCurrentFile(requestedPath) else { return }
                switch requestedCategory {
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
            guard isCurrentFile(requestedPath) else { return }
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
        let sourcePath = currentFilePath
        guard let api = loadedApiClient ?? apiClient else {
            return .fromText(text, filePath: sourcePath)
        }
        return .fromText(
            text,
            filePath: sourcePath,
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
            return .fromText(text, filePath: currentFilePath)
        case .image(let data):
            return .imageData(data, filename: currentFileName)
        case .pdf(let data):
            return .pdfData(data, filename: currentFileName)
        default:
            return nil
        }
    }

    // MARK: - File Navigation

    private func isCurrentFile(_ requestedPath: String) -> Bool {
        !Task.isCancelled && currentFilePath == requestedPath
    }

    private func adjacentSelection(_ direction: FileBrowserNavigationDirection) -> FileBrowserSelection? {
        navigationContext?.selection(adjacentTo: currentFilePath, direction: direction)
    }

    private func navigateToAdjacentFile(_ direction: FileBrowserNavigationDirection) {
        guard let nextSelection = adjacentSelection(direction) else { return }
        fileTransitionDirection = direction
        withAnimation(.easeInOut(duration: 0.22)) {
            activeSelection = nextSelection
            content = .loading
            onNavigationSelectionChange?(nextSelection)
        }
    }

    private func navigateBackToFileList() {
        if let onBackNavigation {
            onBackNavigation()
        } else {
            dismiss()
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

// MARK: - File Navigation Transition

private struct FilePushTransitionModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let direction: FileBrowserNavigationDirection

    func body(content: Content) -> some View {
        let spec = FileBrowserPushTransitionSpec.spec(for: direction)
        ZStack {
            content
                .id(id)
                .transition(.asymmetric(
                    insertion: .move(edge: spec.insertion.edge).combined(with: .opacity),
                    removal: .move(edge: spec.removal.edge).combined(with: .opacity)
                ))
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: id)
    }
}

extension View {
    func filePushTransition<ID: Hashable>(
        id: ID,
        direction: FileBrowserNavigationDirection
    ) -> some View {
        modifier(FilePushTransitionModifier(id: id, direction: direction))
    }
}

// MARK: - File Navigation Controls

/// Explicit file-to-file controls keep horizontal swipes reserved for back.
struct AdjacentFileNavigatorControls: View {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        if canGoPrevious || canGoNext {
            HStack(spacing: 14) {
                navigatorButton(
                    systemImage: "chevron.left",
                    accessibilityLabel: "Previous file",
                    isEnabled: canGoPrevious,
                    action: onPrevious
                )
                navigatorButton(
                    systemImage: "chevron.right",
                    accessibilityLabel: "Next file",
                    isEnabled: canGoNext,
                    action: onNext
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.themeBgDark.opacity(0.64), in: Capsule())
            .glassEffect(.regular, in: Capsule())
            .accessibilityElement(children: .contain)
        }
    }

    private func navigatorButton(
        systemImage: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(isEnabled ? Color.themeFg : Color.themeComment)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - PDF View

/// Wraps `PDFKit.PDFView` for inline PDF rendering with scroll, zoom, and text selection.
private struct PDFBrowserView: View {
    let data: Data
    let onBackSwipe: @MainActor @Sendable () -> Void

    var body: some View {
        if PDFDocument(data: data) != nil {
            PDFKitView(data: data, onBackSwipe: onBackSwipe)
                .ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView(
                "Invalid PDF",
                systemImage: "doc.badge.exclamationmark",
                description: Text("Could not decode PDF data.")
            )
            .horizontalBackSwipeGesture(onBackSwipe)
        }
    }
}

/// UIKit wrapper for `PDFKit.PDFView`.
private struct PDFKitView: UIViewRepresentable {
    let data: Data
    let onBackSwipe: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(data: data)
        context.coordinator.installBackSwipe(action: onBackSwipe, on: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.installBackSwipe(action: onBackSwipe, on: view)
    }

    @MainActor
    final class Coordinator {
        private let backSwipeCoordinator = HorizontalBackSwipeActionCoordinator()

        func installBackSwipe(
            action: @escaping @MainActor @Sendable () -> Void,
            on view: UIView
        ) {
            backSwipeCoordinator.install(action: action, on: view)
        }
    }
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
