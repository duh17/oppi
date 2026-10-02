import Network
import PDFKit
import SwiftUI

enum FileBrowserContentChromeMode {
    case pushed
    case treePane
}

enum FileBrowserContentSource: Equatable {
    case workspaceFile
    case sessionFile(sessionId: String)
    case hostFile

    var routesFileReferencesThroughSession: Bool {
        if case .sessionFile = self { return true }
        return false
    }
}

enum FileBrowserContentRenderingPolicy {
    static func showsNavigationChrome(
        for chromeMode: FileBrowserContentChromeMode,
        source: FileBrowserContentSource = .workspaceFile
    ) -> Bool {
        chromeMode == .pushed && source != .hostFile
    }

    static func navigationTitle(
        source: FileBrowserContentSource,
        path: String,
        fileName: String
    ) -> String {
        source == .hostFile ? path : fileName
    }

    /// The file browser already owns the filename in navigation chrome.
    static let audioPlayerTitlePresentation: AudioLyricsPlayerTitlePresentation = .hostOwnsTitle

    enum EditPlacement: Equatable {
        /// The embedded UIKit reader shows its own navigation bar; Edit is one of its actions.
        case readerNavigationAction
        /// The UIKit reader bar is hidden (tree pane); Edit is a SwiftUI toolbar item.
        case toolbar
    }

    static func editPlacement(
        for chromeMode: FileBrowserContentChromeMode,
        source: FileBrowserContentSource
    ) -> EditPlacement {
        showsNavigationChrome(for: chromeMode, source: source) ? .readerNavigationAction : .toolbar
    }

    /// Which checkout an edit writes to. A worktree is always named; main is
    /// named only when the owning chat session runs on a worktree, so the
    /// difference is visible before typing.
    static func checkoutSubtitle(
        source: FileBrowserContentSource,
        worktreeId: String?,
        sessionWorktreeId: String?
    ) -> String? {
        guard source == .workspaceFile else { return nil }
        if let worktreeId, !worktreeId.isEmpty {
            return String(localized: "Worktree \(worktreeId)")
        }
        if let sessionWorktreeId, !sessionWorktreeId.isEmpty {
            return String(localized: "Main checkout")
        }
        return nil
    }
}

enum FileBrowserMediaLoadPolicy {
    enum Existing: Equatable {
        case none
        case video(path: String)
        case audio(path: String)
    }

    static func shouldReload(
        existing: Existing,
        requestedPath: String,
        force: Bool
    ) -> Bool {
        if force { return true }
        switch existing {
        case .video(let path), .audio(let path):
            return path != requestedPath
        case .none:
            return true
        }
    }
}

/// Displays the content of a workspace file in browse mode.
///
/// Text renders through `EmbeddedFileViewerView` (UIKit `FullScreenCodeViewController`),
/// which picks the reader for the detected file type. Other types use dedicated previews:
/// - Images: inline preview
/// - Audio: lyrics-first full-screen player
/// - Video: system video player with playback controls
/// - PDF: PDFKit with scroll, zoom, and text selection
///
/// Large text files (>1MB) show a size warning before loading.
/// On cellular networks, an additional data warning is displayed.
struct FileBrowserContentView: View {
    static func shouldInstallHorizontalBackSwipe(
        allowsHorizontalBackSwipe: Bool,
        parentOwnsBackSwipe: Bool
    ) -> Bool {
        allowsHorizontalBackSwipe && parentOwnsBackSwipe
    }

    let workspaceId: String
    var worktreeId: String? = nil
    var serverId: String? = nil
    let filePath: String
    let fileName: String
    var source: FileBrowserContentSource = .workspaceFile
    var sessionId: String? = nil
    var controlSessionId: String? = nil
    var workspaceRuntime: WorkspaceRuntime? = nil
    /// Known file size from directory listing. Nil when opened from search results.
    var fileSize: Int?
    var chromeMode: FileBrowserContentChromeMode = .pushed
    var allowsHorizontalBackSwipe = true
    var navigationContext: FileBrowserNavigationContext?
    var onNavigationSelectionChange: ((FileBrowserSelection) -> Void)?
    var onBackNavigation: (() -> Void)?
    var lineAnchor: SourceLineAnchor?
    var onLineAnchorNotice: (@MainActor @Sendable (String) -> Void)?
    var markdownViewportRestore: Binding<FullScreenMarkdownViewportRestoreState>? = nil
    var addToChatDestination: ComposerCanvasDestination? = nil
    /// Parent review hosts keep one stash overlay. Nested file content must not
    /// draw a second pill on top of previous-file.
    var showsSwiftUIReviewCommentStashOverlay = true
    /// Parent hosts hide their own file navigation while the text editor is open.
    var onEditingChange: ((Bool) -> Void)? = nil

#if DEBUG
    var debugHasMarkdownViewportRestoreForTesting: Bool {
        markdownViewportRestore != nil
    }

    var debugMarkdownViewportRestoreForTesting: Binding<FullScreenMarkdownViewportRestoreState>? {
        markdownViewportRestore
    }

    var debugSourceForTesting: FileBrowserContentSource { source }
    var debugSessionIdForTesting: String? { sessionId }
    var debugControlSessionIdForTesting: String? { controlSessionId }
    var debugServerIdForTesting: String? { serverId }
    var debugWorkspaceIdForTesting: String { workspaceId }
    var debugWorktreeIdForTesting: String? { worktreeId }
    var debugChromeModeForTesting: FileBrowserContentChromeMode { chromeMode }

    func debugFullScreenContentForTesting(text: String, api: APIClient) -> FullScreenCodeContent {
        fullScreenContent(text: text, api: api)
    }
#endif

    @Environment(\.apiClient) private var apiClient
    @Environment(AudioPlayerService.self) private var audioPlayer: AudioPlayerService?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @State private var activeSelection: FileBrowserSelection?
    @State private var fileTransitionDirection: FileBrowserNavigationDirection = .next
    @State private var content: FileContentPhase = .loading
    @State private var loadedMediaPath: String?
    /// Path whose text `content` holds, so a re-shown view revalidates instead of rebuilding.
    @State private var loadedTextPath: String?
    @State private var loadedHostFilePath: String?
    @State private var isExpensiveNetwork = false

    /// Captured API client reference from when the file was loaded.
    ///
    /// `@Environment(\.apiClient)` can be nil when SwiftUI re-evaluates `body`
    /// after an async state change — the environment value isn't guaranteed to
    /// survive across the `@State` update boundary. We capture it in `loadContent()`
    /// when we know it's non-nil (since we just used it to load the file).
    @State private var loadedApiClient: APIClient?
    @State private var timedText = TimedText.LoadResult.empty
    @State private var timedTextLoadFinished = false
    /// Tagged read of the displayed bytes. Nil when the server did not offer
    /// this file for editing; missing capability or other origins stay read-only.
    @State private var editBase: WorkspaceFileDiskSnapshot?
    @State private var editMaxBytes: Int?
    @State private var editSession: WorkspaceFileEditSession?
    @State private var isEditing = false
    @State private var isShowingEditPreview = false
    @State private var editorReplacement: WorkspaceFileEditorReplacement?
    @State private var isReviewingEdit = false
    @State private var isConfirmingUseDisk = false
    @State private var editNotice: String?

    private var currentSelection: FileBrowserSelection {
        activeSelection ?? FileBrowserSelection(path: filePath, name: fileName, size: fileSize)
    }

    private var currentFilePath: String { currentSelection.path }
    private var currentFileName: String { currentSelection.name }
    private var viewerTitle: String {
        FileBrowserContentRenderingPolicy.navigationTitle(
            source: source,
            path: currentFilePath,
            fileName: currentFileName
        )
    }

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
        if case .text = content { return !isEditing }
        return false
    }

    private var usesUIKitReviewCommentStash: Bool {
        if case .text = content { return true }
        return false
    }

    private var shouldShowEmbeddedNavigationChrome: Bool {
        FileBrowserContentRenderingPolicy.showsNavigationChrome(for: chromeMode, source: source)
    }

    private var shouldHideHostNavigationBar: Bool {
        shouldShowEmbeddedNavigationChrome && isUsingFileViewer
    }

    private var isEditingText: Bool {
        if case .text = content { return isEditing && editSession != nil }
        return false
    }

    private var parentOwnsBackSwipe: Bool {
        switch content {
        case .text, .pdf, .usdz:
            return false
        case .loading, .sizeWarning, .error, .image, .video, .audio, .binary:
            return true
        }
    }

#if DEBUG
    @ViewBuilder
    private var fileMotionDebugMarker: some View {
        if ProcessInfo.processInfo.environment["OPPI_FILE_MOTION_MARKER"] == "1" {
            Text(currentFilePath)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .foregroundStyle(.themeOnBlue)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(fileMotionDebugMarkerColor)
                .accessibilityIdentifier("file.motion.page")
                .accessibilityValue(currentFilePath)
        }
    }

    private var fileMotionDebugMarkerColor: Color {
        if currentFilePath.contains("alpha") { return .red }
        if currentFilePath.contains("gamma") { return .green }
        return .blue
    }
#endif

    var body: some View {
        fileContent
            .overlay(alignment: .top) {
#if DEBUG
                fileMotionDebugMarker
#endif
            }
            .filePushTransition(id: currentFilePath, direction: fileTransitionDirection)
            .background(.themeBg)
            .horizontalBackSwipeGesture(
                isEnabled: Self.shouldInstallHorizontalBackSwipe(
                    allowsHorizontalBackSwipe: allowsHorizontalBackSwipe,
                    parentOwnsBackSwipe: parentOwnsBackSwipe
                ),
                navigateBackToFileList
            )
            .modifier(AdjacentFileNavigatorControls(
                canGoPrevious: !isEditingText && adjacentSelection(.previous) != nil,
                canGoNext: !isEditingText && adjacentSelection(.next) != nil,
                onPrevious: { navigateToAdjacentFile(.previous) },
                onNext: { navigateToAdjacentFile(.next) }
            ))
            .fullScreenReviewCommentStashOverlay(
                isEnabled: showsSwiftUIReviewCommentStashOverlay && !usesUIKitReviewCommentStash,
                leadingAccessoryCount: adjacentFileNavigatorLeadingAccessoryCount,
                scope: reviewCommentSelectionScope
            )
            .environment(\.reviewCommentSelectionScope, reviewCommentSelectionScope)
        .navigationTitle(shouldHideHostNavigationBar ? "" : viewerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(shouldHideHostNavigationBar ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if isEditingText, let editSession {
                editingToolbar(session: editSession)
            } else if isUsingFileViewer, canBeginEditing,
                      FileBrowserContentRenderingPolicy.editPlacement(for: chromeMode, source: source) == .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Edit")) { beginEditing() }
                        .accessibilityLabel(String(localized: "Edit File"))
                        .accessibilityIdentifier("workspace-file-editor.edit")
                }
            } else if chromeMode == .pushed, !isUsingFileViewer {
                ToolbarItem(placement: .topBarTrailing) {
                    if let shareable = shareableContent() {
                        FileShareButton(content: shareable, style: .icon)
                    } else if case .audio(let source) = content {
                        AsyncFileShareButton(filename: currentFileName) {
                            try await source.loadFileData()
                        }
                        .accessibilityIdentifier("fileBrowser.audio.share")
                    }
                }
            }
        }
        .sheet(isPresented: $isReviewingEdit) {
            if let editSession {
                WorkspaceFileConflictReviewView(
                    session: editSession,
                    filePath: currentFilePath,
                    onUseDisk: {
                        isReviewingEdit = false
                        useDiskVersion()
                    },
                    onReplace: {
                        editSession.replaceDiskVersion()
                        isReviewingEdit = false
                    },
                    onClose: { isReviewingEdit = false }
                )
            }
        }
        .alert(
            String(localized: "Use Disk Version?"),
            isPresented: $isConfirmingUseDisk
        ) {
            Button(String(localized: "Discard My Edits"), role: .destructive) { useDiskVersion() }
                .accessibilityIdentifier("workspace-file-editor.use-disk.confirm")
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Your unsaved edits to this file will be discarded."))
        }
        .onChange(of: isEditingText) { _, editing in onEditingChange?(editing) }
        .task(id: currentFilePath) { await loadContent() }
        .task { await checkNetworkCost() }
        .onChange(of: filePath) { _, _ in
            activeSelection = nil
            beginUSDZSafeLoading()
        }
        .onDisappear {
            releaseLoadedUSDZHandle()
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
            if isEditing, let editSession {
                editorView(session: editSession)
            } else {
                readerView(text: text)
            }
        case .image(let data):
            imageView(data)
        case .video(let source):
            videoView(source)
        case .audio(let source):
            audioView(source)
        case .pdf(let data):
            PDFBrowserView(
                data: data,
                allowsHorizontalBackSwipe: allowsHorizontalBackSwipe,
                onBackSwipe: navigateBackToFileList
            )
        case .usdz(let handle):
            FileBrowserUSDZPreview(
                fileURL: handle.url,
                accessibilityName: currentFileName
            )
            .background(.themeBg)
        case .binary:
            ContentUnavailableView(
                "Binary File",
                systemImage: "doc.fill",
                description: Text("This file type cannot be displayed as text.")
            )
        }
    }

    // MARK: - Text Reader and Editor

    @ViewBuilder
    private func readerView(text: String) -> some View {
        EmbeddedFileViewerView(
            content: fullScreenContent(text: text),
            reviewCommentSessionId: sessionId,
            lineAnchor: activeSelection == nil ? lineAnchor : nil,
            lineAnchorNotice: onLineAnchorNotice,
            showsNavigationChrome: shouldShowEmbeddedNavigationChrome,
            backSwipeAction: navigateBackToFileList,
            navigationActions: editNavigationActions,
            markdownViewportIntent: markdownViewportRestore?.intent(for: currentFilePath),
            addToChatDestination: addToChatDestination,
            leadingFloatingAccessoryCount: adjacentFileNavigatorLeadingAccessoryCount,
            trailingFloatingAccessoryCount: adjacentFileNavigatorTrailingAccessoryCount
        )
        .ignoresSafeArea(edges: shouldShowEmbeddedNavigationChrome ? .top : [])
    }

    @ViewBuilder
    private func editorView(session: WorkspaceFileEditSession) -> some View {
        WorkspaceFileEditorView(
            session: session,
            isShowingPreview: isShowingEditPreview,
            replacementText: editorReplacement,
            makePreview: { text in
                UIHostingController(rootView: EmbeddedFileViewerView(
                    content: fullScreenContent(text: text),
                    showsNavigationChrome: false
                ))
            }
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let checkoutSubtitle {
                    Text(checkoutSubtitle)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("workspace-file-editor.checkout")
                }
                WorkspaceFileEditBanner(
                    session: session,
                    onReview: { isReviewingEdit = true },
                    onUseDisk: { isConfirmingUseDisk = true }
                )
                if let editNotice {
                    Text(editNotice)
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func editingToolbar(session: WorkspaceFileEditSession) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            WorkspaceFileEditStatusIndicator(status: session.status)
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button(isShowingEditPreview ? String(localized: "Source") : String(localized: "Preview")) {
                isShowingEditPreview.toggle()
            }
            .accessibilityIdentifier("workspace-file-editor.preview-toggle")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done")) { endEditing() }
                .fontWeight(.semibold)
                .accessibilityIdentifier("workspace-file-editor.done")
        }
    }

    /// The server offered these displayed bytes for editing, or a session exists.
    private var canBeginEditing: Bool {
        editIdentity(for: currentFilePath) != nil
            && editMaxBytes != nil
            && (editBase != nil || editSession != nil)
    }

    private var checkoutSubtitle: String? {
        FileBrowserContentRenderingPolicy.checkoutSubtitle(
            source: source,
            worktreeId: worktreeId,
            sessionWorktreeId: sessionId.flatMap { sessionStore?.session(id: $0) }
                .flatMap { $0.workspaceId == workspaceId ? $0.worktreeId : nil }
        )
    }

    private var editNavigationActions: [FullScreenViewerNavigationAction] {
        guard canBeginEditing,
              FileBrowserContentRenderingPolicy.editPlacement(for: chromeMode, source: source)
                == .readerNavigationAction else { return [] }
        return [
            FullScreenViewerNavigationAction(
                id: "workspace-file-edit",
                title: String(localized: "Edit"),
                accessibilityLabel: String(localized: "Edit File"),
                handler: { beginEditing() }
            ),
        ]
    }

    /// Server + workspace + worktree + path. Only workspace-origin files on a
    /// known server are editable; host and session origins stay read-only.
    private func editIdentity(for path: String) -> WorkspaceFileEditIdentity? {
        guard source == .workspaceFile,
              let serverId, !serverId.isEmpty,
              !workspaceId.isEmpty else { return nil }
        return WorkspaceFileEditIdentity(
            serverId: serverId,
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            path: path
        )
    }

    private func resetEditState() {
        editBase = nil
        editMaxBytes = nil
        editSession = nil
        isEditing = false
        isShowingEditPreview = false
        editorReplacement = nil
        isReviewingEdit = false
        editNotice = nil
    }

    /// Record the tagged read and adopt a live session or recover a stored
    /// draft. Returns the text the reader should show when it differs from disk.
    private func prepareEditing(
        identity: WorkspaceFileEditIdentity,
        snapshot: WorkspaceFileDiskSnapshot,
        maxBytes: Int,
        api: APIClient
    ) -> String? {
        editMaxBytes = maxBytes
        editBase = snapshot.etag == nil ? nil : snapshot
        let registry = WorkspaceFileEditSessionRegistry.shared
        if let live = registry.session(for: identity) {
            editSession = live
            if live.hasUnsavedChanges, live.status.stopsAutosave || live.recoveredDraft {
                isEditing = true
            }
            return live.hasUnsavedChanges ? live.currentText : nil
        }
        guard snapshot.etag != nil,
              WorkspaceFileDraftStore.shared.loadResult(identity) != .none,
              let recovered = WorkspaceFileEditSession(
                  identity: identity,
                  disk: snapshot,
                  maxBytes: maxBytes,
                  transport: .api(api)
              ) else { return nil }
        // A recovered draft, or a notice that an unreadable one was moved aside.
        guard recovered.recoveredDraft || recovered.draftNotice != nil else { return nil }
        registry.register(recovered)
        editSession = recovered
        isEditing = true
        return recovered.currentText
    }

    private static func isHTTPError(_ error: Error, statusCodes: Set<Int>) -> Bool {
        switch error {
        case APIError.server(let status, _), APIError.codedServer(let status, _, _):
            return statusCodes.contains(status)
        default:
            return false
        }
    }

    private func beginEditing() {
        guard let identity = editIdentity(for: currentFilePath),
              let maxBytes = editMaxBytes,
              let api = loadedApiClient ?? apiClient else { return }
        let registry = WorkspaceFileEditSessionRegistry.shared
        let session: WorkspaceFileEditSession
        if let live = registry.session(for: identity) {
            session = live
        } else if let existing = editSession, existing.identity == identity {
            // Keeps the newest acknowledged tag after an earlier edit settled.
            session = existing
            registry.register(existing)
        } else if let editBase, let created = WorkspaceFileEditSession(
            identity: identity,
            disk: editBase,
            maxBytes: maxBytes,
            transport: .api(api)
        ) {
            session = created
            registry.register(created)
        } else {
            return
        }
        editSession = session
        editNotice = nil
        isShowingEditPreview = false
        isEditing = true
    }

    /// Done: show the current draft in the reader. The editor teardown
    /// checkpoints and starts the save; the network is not awaited.
    private func endEditing() {
        guard let editSession else {
            isEditing = false
            return
        }
        let text = editSession.currentText
        isShowingEditPreview = false
        isEditing = false
        content = .text(text)
    }

    private func useDiskVersion() {
        guard let editSession else { return }
        Task {
            switch await editSession.useDiskVersion() {
            case .replaced(let text):
                editNotice = nil
                editorReplacement = WorkspaceFileEditorReplacement(text: text)
                content = .text(text)
            case .missing, .notEditable:
                resetEditState()
                await loadContent(force: true)
            case .unavailable:
                editNotice = String(localized: "Couldn't read the disk version. Your edits were not changed.")
            }
        }
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
        // `loadedMediaPath` changes with `content`, so the loader always names
        // the file behind `source`. The player host runs it once per source and
        // attaches captions to the overlay itself, even during fullscreen.
        let timedTextLoader = loadedMediaPath.flatMap { makeTimedTextLoader(path: $0, kind: .video) }
        GeometryReader { geometry in
            AuthenticatedMediaPlayerView(
                source: source,
                height: min(max(geometry.size.height * 0.34, 220), 420),
                unavailableTitle: "Video preview unavailable",
                unavailableSystemImage: "film.slash",
                timedTextLoader: timedTextLoader
            )
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.themeBgDark)
        }
    }

    @ViewBuilder
    private func audioView(_ source: AuthenticatedMediaSource) -> some View {
        let itemID = AudioPlaybackItemID.fileBrowser(
            path: currentFilePath,
            workspaceID: workspaceId,
            sessionID: sessionId,
            worktreeID: worktreeId
        )
        let nowPlayingTimedText = audioPlayer?.nowPlayingTimedText
        let playbackTimedText =
            (audioPlayer?.playingItemID == itemID || audioPlayer?.loadingItemID == itemID)
            && !(nowPlayingTimedText?.tracks.isEmpty ?? true)
            ? (nowPlayingTimedText ?? timedText)
            : timedText
        let playbackTimedTextLoader = timedTextLoadFinished
            ? nil
            : makeTimedTextLoader(path: currentFilePath, kind: .audio)
        AudioLyricsPlayerView(
            title: currentFileName,
            lyrics: nil,
            itemID: itemID,
            audioPlayer: audioPlayer,
            play: { selectedTimedText in
                audioPlayer?.toggleMediaPlayback(
                    source: source,
                    itemID: itemID,
                    timedText: selectedTimedText ?? playbackTimedText,
                    timedTextLoader: playbackTimedTextLoader
                )
            },
            openFile: nil,
            autoplayOnAppear: false,
            showsCloseButton: false,
            titlePresentation: FileBrowserContentRenderingPolicy.audioPlayerTitlePresentation,
            timedText: playbackTimedText
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.themeBg)
    }

    // MARK: - Loading

    private func loadContent(force: Bool = false) async {
        guard let api = apiClient else {
            content = .error("Not connected")
            return
        }
        // Reappearing over an open editor must not reload over the buffer.
        if isEditing, let editSession,
           editSession.identity == editIdentity(for: currentSelection.path) {
            return
        }

        let requestedSelection = currentSelection
        let requestedPath = requestedSelection.path
        let requestedExtension = (requestedPath as NSString).pathExtension.lowercased()
        let requestedCategory = FileType.detect(from: requestedPath).previewCategory
        let existingMedia: FileBrowserMediaLoadPolicy.Existing = {
            guard let loadedMediaPath else { return .none }
            switch content {
            case .video: return .video(path: loadedMediaPath)
            case .audio: return .audio(path: loadedMediaPath)
            default: return .none
            }
        }()
        if !FileBrowserMediaLoadPolicy.shouldReload(
            existing: existingMedia,
            requestedPath: requestedPath,
            force: force
        ) {
            return
        }

        // Capture the API client while we know it's non-nil.
        // See loadedApiClient comment for why this is needed.
        loadedApiClient = api

        // `.task(id:)` reruns whenever SwiftUI re-shows this view: after AVKit
        // fullscreen from an inline Markdown video, or a pop back from a pushed
        // wiki link. Rebuilding the reader there recreates every inline player,
        // so re-read first and rebuild only when the shown text changed. Transient
        // failures keep its inline players; missing or denied files must not show stale text.
        if !force, loadedTextPath == requestedPath, case .text(let shownText) = content {
            do {
                guard let read = try await readReaderBytes(
                    api: api, path: requestedPath, category: requestedCategory
                ) else { return }
                if case .bytes(let data, let editedText, _) = read,
                   readerPhase(data: data, editedText: editedText, path: requestedPath, category: requestedCategory)
                    == .text(shownText) {
                    return
                }
            } catch {
                guard isCurrentFile(requestedPath),
                      Self.isHTTPError(error, statusCodes: [401, 403, 404]) else { return }
                loadedTextPath = nil
                loadedHostFilePath = nil
                resetEditState()
                content = .error(error.localizedDescription)
                return
            }
        }

        // For text files with known size above threshold, show a warning first.
        if !force, requestedCategory == .text,
           let size = requestedSelection.size, size > Self.sizeWarningThreshold
        {
            content = .sizeWarning(size)
            return
        }

        loadedMediaPath = nil
        loadedTextPath = nil
        loadedHostFilePath = nil
        resetEditState()
        timedText = .empty
        timedTextLoadFinished = false
        beginUSDZSafeLoading()

        do {
            switch requestedCategory {
            case .video:
                let source = try await mediaSource(
                    api: api,
                    path: requestedPath,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: requestedExtension),
                    sourceFileExtension: requestedExtension
                )
                guard isCurrentFile(requestedPath) else { return }
                loadedMediaPath = requestedPath
                content = .video(source)
            case .audio:
                let source = try await mediaSource(
                    api: api,
                    path: requestedPath,
                    contentTypeHint: MediaMimeType.audioMimeType(forPathExtension: requestedExtension),
                    sourceFileExtension: requestedExtension
                )
                guard isCurrentFile(requestedPath) else { return }
                loadedMediaPath = requestedPath
                content = .audio(source)
                await loadTimedText(api: api, path: requestedPath, kind: .audio)
            case .usdz:
                let data: Data
                if source == .hostFile {
                    let file = try await api.browseHostFileContent(
                        path: requestedPath, controlSessionId: controlSessionId
                    )
                    guard isCurrentFile(requestedPath) else { return }
                    data = file.data
                    loadedHostFilePath = file.resolvedPath
                } else {
                    data = try await browseFile(api: api, path: requestedPath)
                }
                guard isCurrentFile(requestedPath) else { return }
                let key = USDZLocalFileStore.cacheKey(
                    kind: source == .hostFile ? .hostFile : .workspaceFile,
                    workspaceID: workspaceId,
                    sessionID: sessionId,
                    worktreeID: worktreeId,
                    path: requestedPath
                )
                let handle = try await USDZLocalFileStore.shared.store(key: key, data: data)
                guard isCurrentFile(requestedPath) else {
                    await USDZLocalFileStore.shared.release(handle)
                    return
                }
                loadedMediaPath = requestedPath
                content = .usdz(handle)
            case .image, .pdf, .text, .binary:
                guard let read = try await readReaderBytes(
                    api: api, path: requestedPath, category: requestedCategory
                ) else { return }
                switch read {
                case .missingWithDraft(let session, let maxBytes):
                    // Gone on the server: a kept draft reopens in the
                    // non-writing deleted state instead of an error page.
                    editMaxBytes = maxBytes
                    editSession = session
                    isEditing = true
                    content = .text(session.currentText)
                    return
                case .bytes(let data, let editedText, let resolvedHostPath):
                    if let resolvedHostPath {
                        loadedHostFilePath = resolvedHostPath
                    }
                    content = readerPhase(
                        data: data, editedText: editedText, path: requestedPath, category: requestedCategory
                    )
                }
            }
            if case .text = content {
                loadedTextPath = requestedPath
            }
        } catch {
            guard isCurrentFile(requestedPath) else { return }
            content = .error(error.localizedDescription)
        }
    }

    private enum ReaderRead {
        case bytes(Data, editedText: String?, resolvedHostPath: String?)
        case missingWithDraft(WorkspaceFileEditSession, maxBytes: Int)
    }

    /// One read of a document file. Editable text uses the tagged read and
    /// `prepareEditing`, so a live or recovered draft wins over disk. Nil when
    /// the person moved to another file meanwhile.
    private func readReaderBytes(
        api: APIClient,
        path: String,
        category: FilePreviewCategory
    ) async throws -> ReaderRead? {
        if category == .text,
           let identity = editIdentity(for: path),
           let capability = await api.workspaceFileEditingCapability() {
            // One tagged read: the edit base is exactly the displayed bytes.
            let snapshot: WorkspaceFileDiskSnapshot
            do {
                snapshot = try await api.readWorkspaceFileForEditing(
                    workspaceId: workspaceId,
                    path: path,
                    worktreeId: worktreeId
                )
            } catch let error where Self.isHTTPError(error, statusCodes: [404]) {
                guard isCurrentFile(path) else { return nil }
                guard let session = WorkspaceFileEditRecovery.sessionForMissingFile(
                    identity: identity,
                    maxBytes: capability.maxBytes,
                    transport: .api(api)
                ) else { throw error }
                return .missingWithDraft(session, maxBytes: capability.maxBytes)
            }
            guard isCurrentFile(path) else { return nil }
            let editedText = prepareEditing(
                identity: identity,
                snapshot: snapshot,
                maxBytes: capability.maxBytes,
                api: api
            )
            return .bytes(snapshot.bytes, editedText: editedText, resolvedHostPath: nil)
        }
        if source == .hostFile {
            let file = try await api.browseHostFileContent(
                path: path, controlSessionId: controlSessionId
            )
            guard isCurrentFile(path) else { return nil }
            return .bytes(file.data, editedText: nil, resolvedHostPath: file.resolvedPath)
        }
        let data = try await browseFile(api: api, path: path)
        guard isCurrentFile(path) else { return nil }
        return .bytes(data, editedText: nil, resolvedHostPath: nil)
    }

    private func readerPhase(
        data: Data,
        editedText: String?,
        path: String,
        category: FilePreviewCategory
    ) -> FileContentPhase {
        if source == .hostFile, HostFilePreviewPolicy.usesStringFetchViewer(for: path) {
            if FileType.detect(from: path) == .html,
               let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .image(data)
        }
        switch category {
        case .image: return .image(data)
        case .pdf: return .pdf(data)
        case .text:
            if let editedText { return .text(editedText) }
            if let text = String(data: data, encoding: .utf8) { return .text(text) }
            return .binary
        default:
            return .binary
        }
    }

    // MARK: - Full-screen content

    /// Build full-screen content with workspace context for relative image resolution.
    ///
    /// Uses `loadedApiClient` (captured during `loadContent()`) instead of the current
    /// `@Environment(\.apiClient)` because environment values can be nil when SwiftUI
    /// re-evaluates `body` after an async state change. The captured reference is
    /// guaranteed non-nil since we used it to successfully load the file.
    private func fullScreenContent(text: String, api: APIClient? = nil) -> FullScreenCodeContent {
        let sourcePath = loadedHostFilePath ?? currentFilePath
        guard let api = api ?? loadedApiClient ?? apiClient else {
            return .fromText(text, filePath: sourcePath)
        }
        return .fromText(
            text,
            filePath: sourcePath,
            resourceAccess: MarkdownResourceAccess(
                identity: MarkdownResourceAccess.Identity(
                    serverID: serverId,
                    workspaceID: workspaceId,
                    worktreeId: worktreeId,
                    sessionID: sessionId,
                    workspaceRuntime: workspaceRuntime,
                    serverBaseURL: api.baseURL,
                    routesFileReferencesThroughSession: source.routesFileReferencesThroughSession
                ),
                fetchWorkspaceFile: { [workspaceId, worktreeId, source, controlSessionId] wsID, filePath in
                    switch source {
                    case .hostFile:
                        return try await api.browseHostFile(
                            path: filePath,
                            controlSessionId: controlSessionId
                        )
                    case .sessionFile(let sourceSessionId):
                        return try await api.getSessionFileData(
                            workspaceId: wsID.isEmpty ? workspaceId : wsID,
                            sessionId: sourceSessionId,
                            path: filePath
                        )
                    case .workspaceFile:
                        return try await api.browseWorkspaceFile(
                            workspaceId: wsID.isEmpty ? workspaceId : wsID,
                            path: filePath,
                            worktreeId: worktreeId
                        )
                    }
                },
                fetchSessionFile: { workspaceID, sourceSessionID, path in
                    try await api.getSessionFileData(
                        workspaceId: workspaceID,
                        sessionId: sourceSessionID,
                        path: path
                    )
                },
                fetchHostFile: { [workspaceId, worktreeId, sessionId, controlSessionId, workspaceRuntime] path in
                    if case .sessionFile = source {
                        return try await browseFile(api: api, path: path)
                    }
                    let route = MarkdownVideoMediaSourceRoute.resolve(
                        filePath: path,
                        kind: .hostFile,
                        referenceWorkspaceID: workspaceId,
                        workspaceID: workspaceId,
                        sessionID: sessionId,
                        worktreeID: worktreeId,
                        workspaceRuntime: workspaceRuntime
                    )
                    switch route {
                    case .host(let hostPath):
                        return try await api.browseHostFile(
                            path: hostPath,
                            controlSessionId: controlSessionId
                        )
                    case .session(let workspaceID, let sessionID, let sessionPath):
                        return try await api.getSessionFileData(
                            workspaceId: workspaceID,
                            sessionId: sessionID,
                            path: sessionPath
                        )
                    case .workspace(let workspaceID, let workspacePath, let worktreeID):
                        return try await api.fetchWorkspaceFile(
                            workspaceID: workspaceID,
                            path: workspacePath,
                            worktreeId: worktreeID
                        )
                    case nil:
                        throw CocoaError(.fileNoSuchFile)
                    }
                },
                makeMarkdownVideoSource: { embed in
                    try await markdownMediaSource(
                        api: api, path: embed.filePath, reference: embed.reference,
                        mimeType: MediaMimeType.videoMimeType(forPathExtension:)
                    )
                },
                makeMarkdownAudioSource: { embed in
                    try await markdownMediaSource(
                        api: api, path: embed.filePath, reference: embed.reference,
                        mimeType: MediaMimeType.audioMimeType(forPathExtension:)
                    )
                },
                makeMarkdownUSDZFile: { embed in
                    try await markdownUSDZFile(api: api, embed: embed)
                },
                makeTimedTextSidecar: { [workspaceId, worktreeId, sessionId, controlSessionId, workspaceRuntime] mediaPath, kind, reference in
                    if case .sessionFile = source {
                        return await Self.loadTimedTextResult(
                            api: api, path: mediaPath, kind: kind, source: source,
                            workspaceId: workspaceId, worktreeId: worktreeId,
                            controlSessionId: controlSessionId
                        )
                    }
                    return await TimedText.load(
                        mediaPath: mediaPath,
                        kind: kind,
                        fileKind: reference.kind,
                        workspaceID: reference.workspaceID ?? workspaceId,
                        sessionID: sessionId,
                        worktreeID: worktreeId,
                        workspaceRuntime: workspaceRuntime,
                        api: api
                    )
                },
                audioPlayer: audioPlayer
            )
        )
    }

    private func markdownUSDZFile(
        api: APIClient,
        embed: MarkdownUSDZEmbed
    ) async throws -> USDZLocalFileStore.Handle {
        let path = embed.filePath
        let data: Data
        if case .sessionFile = source {
            data = try await browseFile(api: api, path: path)
        } else {
            guard let route = MarkdownVideoMediaSourceRoute.resolve(
                embed: embed,
                workspaceID: workspaceId,
                sessionID: sessionId,
                worktreeID: worktreeId,
                workspaceRuntime: workspaceRuntime
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            switch route {
            case .host(let hostPath):
                data = try await api.browseHostFile(
                    path: hostPath,
                    controlSessionId: controlSessionId
                )
            case .session(let workspaceID, let sessionID, let sessionPath):
                data = try await api.getSessionFileData(
                    workspaceId: workspaceID,
                    sessionId: sessionID,
                    path: sessionPath
                )
            case .workspace(let workspaceID, let workspacePath, let worktreeID):
                data = try await api.fetchWorkspaceFile(
                    workspaceID: workspaceID,
                    path: workspacePath,
                    worktreeId: worktreeID
                )
            }
        }
        let key = USDZLocalFileStore.cacheKey(
            kind: embed.reference.kind,
            workspaceID: embed.reference.workspaceID ?? workspaceId,
            sessionID: embed.reference.sourceSessionID ?? sessionId,
            worktreeID: worktreeId,
            path: path
        )
        return try await USDZLocalFileStore.shared.store(key: key, data: data)
    }

    private func markdownMediaSource(
        api: APIClient,
        path: String,
        reference: ResourceReference,
        mimeType: (String?) -> String?
    ) async throws -> AuthenticatedMediaSource {
        // Exact session readers keep their captured origin even without runtime metadata.
        if case .sessionFile = source {
            let pathExtension = (path as NSString).pathExtension
            return try await mediaSource(
                api: api, path: path,
                contentTypeHint: mimeType(pathExtension),
                sourceFileExtension: pathExtension
            )
        }
        guard let route = MarkdownVideoMediaSourceRoute.resolve(
            filePath: path,
            kind: reference.kind,
            referenceWorkspaceID: reference.workspaceID,
            workspaceID: workspaceId,
            sessionID: sessionId,
            worktreeID: worktreeId,
            workspaceRuntime: workspaceRuntime
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let pathExtension = (route.path as NSString).pathExtension
        let contentType = mimeType(pathExtension)
        switch route {
        case .host(let path):
            return try await api.makeHostFileMediaSource(
                path: path,
                controlSessionId: controlSessionId,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        case .session(let workspaceID, let sessionID, let path):
            return try await api.makeSessionFileMediaSource(
                workspaceId: workspaceID,
                sessionId: sessionID,
                path: path,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        case .workspace(let workspaceID, let path, let worktreeID):
            return try await api.makeWorkspaceMediaSource(
                workspaceId: workspaceID,
                path: path,
                worktreeId: worktreeID,
                contentTypeHint: contentType,
                sourceFileExtension: pathExtension
            )
        }
    }

    private func loadTimedText(
        api: APIClient,
        path: String,
        kind: TimedText.MediaKind
    ) async {
        let result = await Self.loadTimedTextResult(
            api: api,
            path: path,
            kind: kind,
            source: source,
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            controlSessionId: controlSessionId
        )
        guard isCurrentFile(path) else { return }
        timedText = result
        timedTextLoadFinished = true
    }

    private func makeTimedTextLoader(
        path: String,
        kind: TimedText.MediaKind
    ) -> (() async -> TimedText.LoadResult)? {
        guard let api = loadedApiClient ?? apiClient else { return nil }
        let source = source
        let workspaceId = workspaceId
        let worktreeId = worktreeId
        let controlSessionId = controlSessionId
        return {
            await Self.loadTimedTextResult(
                api: api,
                path: path,
                kind: kind,
                source: source,
                workspaceId: workspaceId,
                worktreeId: worktreeId,
                controlSessionId: controlSessionId
            )
        }
    }

    private static func loadTimedTextResult(
        api: APIClient,
        path: String,
        kind: TimedText.MediaKind,
        source: FileBrowserContentSource,
        workspaceId: String,
        worktreeId: String?,
        controlSessionId: String?
    ) async -> TimedText.LoadResult {
        let route: MarkdownVideoMediaSourceRoute = switch source {
        case .hostFile:
            .host(path: path)
        case .sessionFile(let sessionId):
            .session(workspaceID: workspaceId, sessionID: sessionId, path: path)
        case .workspaceFile:
            .workspace(workspaceID: workspaceId, path: path, worktreeID: worktreeId)
        }
        return await TimedText.load(
            mediaPath: path,
            kind: kind,
            locale: .current,
            access: TimedText.access(for: route, api: api, controlSessionId: controlSessionId)
        )
    }

    private func browseFile(api: APIClient, path: String) async throws -> Data {
        switch source {
        case .hostFile:
            return try await api.browseHostFile(
                path: path,
                controlSessionId: controlSessionId
            )
        case .sessionFile(let sessionId):
            return try await api.getSessionFileData(
                workspaceId: workspaceId,
                sessionId: sessionId,
                path: path
            )
        case .workspaceFile:
            return try await api.browseWorkspaceFile(
                workspaceId: workspaceId,
                path: path,
                worktreeId: worktreeId
            )
        }
    }

    private func mediaSource(
        api: APIClient,
        path: String,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) async throws -> AuthenticatedMediaSource {
        switch source {
        case .hostFile:
            return try await api.makeHostFileMediaSource(
                path: path,
                controlSessionId: controlSessionId,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: sourceFileExtension
            )
        case .sessionFile(let sessionId):
            return try await api.makeSessionFileMediaSource(
                workspaceId: workspaceId,
                sessionId: sessionId,
                path: path,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: sourceFileExtension
            )
        case .workspaceFile:
            return try await api.makeWorkspaceMediaSource(
                workspaceId: workspaceId,
                path: path,
                worktreeId: worktreeId,
                contentTypeHint: contentTypeHint,
                sourceFileExtension: sourceFileExtension
            )
        }
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

    private var adjacentFileNavigatorLeadingAccessoryCount: Int {
        AdjacentFileNavigatorLayout.leadingAccessoryCount(
            canGoPrevious: adjacentSelection(.previous) != nil,
            canGoNext: adjacentSelection(.next) != nil
        )
    }

    private var adjacentFileNavigatorTrailingAccessoryCount: Int {
        AdjacentFileNavigatorLayout.trailingAccessoryCount(
            canGoPrevious: adjacentSelection(.previous) != nil,
            canGoNext: adjacentSelection(.next) != nil
        )
    }

    private func navigateToAdjacentFile(_ direction: FileBrowserNavigationDirection) {
        guard let nextSelection = adjacentSelection(direction) else { return }
        fileTransitionDirection = direction
        withAnimation(FileBrowserPushTransitionPolicy.animation(reduceMotion: reduceMotion)) {
            activeSelection = nextSelection
            beginUSDZSafeLoading()
            onNavigationSelectionChange?(nextSelection)
        }
    }

    private func beginUSDZSafeLoading() {
        releaseLoadedUSDZHandle()
        content = .loading
    }

    private func releaseLoadedUSDZHandle() {
        guard case .usdz(let handle) = content else { return }
        content = .loading
        Task { await USDZLocalFileStore.shared.release(handle) }
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

/// Shared previous/next file transition. Directional travel and the 220 ms
/// ease-in-out are the same policy for the modifier `.animation(value:)` and
/// each caller `withAnimation`. Reduce Motion must win at both owners.
enum FileBrowserPushTransitionPolicy {
    static let duration: Double = 0.22

    static func directionalSpec(
        for direction: FileBrowserNavigationDirection,
        reduceMotion: Bool
    ) -> FileBrowserPushTransitionSpec? {
        reduceMotion ? nil : FileBrowserPushTransitionSpec.spec(for: direction)
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        ThemeMotion.easeInOut(duration: duration, reduceMotion: reduceMotion)
    }

    static func transition(
        for direction: FileBrowserNavigationDirection,
        reduceMotion: Bool
    ) -> AnyTransition {
        guard let spec = directionalSpec(for: direction, reduceMotion: reduceMotion) else {
            return .opacity
        }
        return .asymmetric(
            insertion: ThemeMotion.move(edge: spec.insertion.edge, reduceMotion: false),
            removal: ThemeMotion.move(edge: spec.removal.edge, reduceMotion: false)
        )
    }
}

private struct FilePushTransitionModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let direction: FileBrowserNavigationDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
                .id(id)
                .transition(
                    FileBrowserPushTransitionPolicy.transition(
                        for: direction,
                        reduceMotion: reduceMotion
                    )
                )
        }
        .clipped()
        .animation(FileBrowserPushTransitionPolicy.animation(reduceMotion: reduceMotion), value: id)
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

/// Previous file stays in the leading bottom corner; next file stays trailing.
/// When Viewing Options / Reader is also present, it stacks above next.
/// A missing direction omits that button instead of recentering the other one.
enum AdjacentFileNavigatorLayout {
    enum Corner: Equatable {
        case leading
        case trailing
    }

    struct Slot: Equatable {
        var corner: Corner
        var systemImage: String
        var accessibilityLabel: String
    }

    static func slots(canGoPrevious: Bool, canGoNext: Bool) -> [Slot] {
        var slots: [Slot] = []
        if canGoPrevious {
            slots.append(Slot(
                corner: .leading,
                systemImage: "chevron.left",
                accessibilityLabel: "Previous file"
            ))
        }
        if canGoNext {
            slots.append(Slot(
                corner: .trailing,
                systemImage: "chevron.right",
                accessibilityLabel: "Next file"
            ))
        }
        return slots
    }

    static func leadingAccessoryCount(canGoPrevious: Bool, canGoNext: Bool) -> Int {
        canGoPrevious ? 1 : 0
    }

    static func trailingAccessoryCount(canGoPrevious: Bool, canGoNext: Bool) -> Int {
        canGoNext ? 1 : 0
    }
}

/// Explicit file-to-file controls keep horizontal swipes reserved for back.
struct AdjacentFileNavigatorControls: ViewModifier {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                slotButton(corner: .leading, action: onPrevious)
            }
            .overlay(alignment: .bottomTrailing) {
                slotButton(corner: .trailing, action: onNext)
            }
    }

    @ViewBuilder
    private func slotButton(
        corner: AdjacentFileNavigatorLayout.Corner,
        action: @escaping () -> Void
    ) -> some View {
        if let slot = AdjacentFileNavigatorLayout.slots(
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext
        ).first(where: { $0.corner == corner }) {
            Button(action: action) {
                Image(systemName: slot.systemImage)
                    .font(.system(size: FullScreenFloatingControlChrome.symbolPointSize, weight: .semibold))
                    .foregroundStyle(.themeFg)
                    .frame(
                        width: FullScreenFloatingControlChrome.controlSize,
                        height: FullScreenFloatingControlChrome.controlSize
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .fullScreenFloatingControlGlass(in: Capsule())
            .accessibilityLabel(slot.accessibilityLabel)
            .padding(.leading, corner == .leading ? FullScreenFloatingControlChrome.leadingPadding : 0)
            .padding(.trailing, corner == .trailing ? FullScreenFloatingControlChrome.trailingPadding : 0)
            .padding(.bottom, FullScreenFloatingControlChrome.bottomPadding)
        }
    }
}

// MARK: - PDF View

/// Wraps `PDFKit.PDFView` for inline PDF rendering with scroll, zoom, and text selection.
private struct PDFBrowserView: View {
    let data: Data
    let allowsHorizontalBackSwipe: Bool
    let onBackSwipe: @MainActor @Sendable () -> Void

    var body: some View {
        if PDFDocument(data: data) != nil {
            PDFKitView(
                data: data,
                allowsHorizontalBackSwipe: allowsHorizontalBackSwipe,
                onBackSwipe: onBackSwipe
            )
            .ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView(
                "Invalid PDF",
                systemImage: "doc.badge.exclamationmark",
                description: Text("Could not decode PDF data.")
            )
            .horizontalBackSwipeGesture(isEnabled: allowsHorizontalBackSwipe, onBackSwipe)
        }
    }
}

/// UIKit wrapper for `PDFKit.PDFView`.
private struct PDFKitView: UIViewRepresentable {
    let data: Data
    let allowsHorizontalBackSwipe: Bool
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
        if allowsHorizontalBackSwipe {
            context.coordinator.installBackSwipe(action: onBackSwipe, on: view)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if allowsHorizontalBackSwipe {
            context.coordinator.installBackSwipe(action: onBackSwipe, on: view)
        }
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
    case usdz(USDZLocalFileStore.Handle)
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
        case (.usdz(let a), .usdz(let b)): a == b
        case (.binary, .binary): true
        default: false
        }
    }
}
