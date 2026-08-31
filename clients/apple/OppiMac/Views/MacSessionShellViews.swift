import AppKit
import SwiftUI

enum MacSessionShellColumnLayout: Equatable, Sendable {
    case timelineOnly
    case documentOnly
    case timelineAndDocument
}

enum MacSessionShellLayoutPolicy {
    static let timelineMinimumWidth: CGFloat = 320
    static let splitDividerAllowance: CGFloat = 12
    static var sideBySideMinimumWidth: CGFloat {
        timelineMinimumWidth + MacToolDocumentColumnMetrics.minWidth + splitDividerAllowance
    }

    static func hasDocument(
        workspaceDocumentIsOpen: Bool,
        toolDocumentIsOpen: Bool
    ) -> Bool {
        workspaceDocumentIsOpen || toolDocumentIsOpen
    }

    static func columns(
        availableWidth: CGFloat,
        hasDocument: Bool
    ) -> MacSessionShellColumnLayout {
        guard hasDocument else { return .timelineOnly }
        return availableWidth >= sideBySideMinimumWidth
            ? .timelineAndDocument
            : .documentOnly
    }

    /// The file browser is navigation, not document content. Keep the user's
    /// right-sidebar choice independent from whichever file or tool document
    /// is open in the main surface.
    static func shouldPresentInspector(requested: Bool, hasDocument _: Bool) -> Bool {
        requested
    }
}

/// Compact identity for the principal session toolbar item. Build it from the
/// live session when available, while the selected summary keeps the title and
/// workspace stable during the first history load.
struct MacSessionToolbarPresentation: Equatable, Sendable {
    let title: String
    let statusTitle: String
    let workspaceTitle: String

    var detailText: String {
        "\(statusTitle) · \(workspaceTitle)"
    }

    static func make(
        session: Session,
        selectedTarget: MacSelectedSessionTarget?
    ) -> Self {
        let matchingSummary = selectedTarget?.sessionId == session.id
            ? selectedTarget?.summary
            : nil
        let statusTitle = SessionRowStatusKind.from(
            session: session,
            pendingAskCount: matchingSummary?.pendingAskCount ?? 0
        ).label
        let fallbackWorkspace = selectedTarget?.workspaceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceTitle: String
        if let workspaceContext = SessionRowPresentationBuilder.allSessionsWorkspaceContext(
            for: session
        ) {
            workspaceTitle = workspaceContext
        } else if let fallbackWorkspace, !fallbackWorkspace.isEmpty {
            workspaceTitle = fallbackWorkspace
        } else {
            workspaceTitle = "Local workspace"
        }

        return Self(
            title: session.displayTitle,
            statusTitle: statusTitle,
            workspaceTitle: workspaceTitle
        )
    }
}

enum MacSessionContextRingPaint {
    enum Tone: Equatable, Sendable {
        case neutral
        case normal
        case warning
        case critical
    }

    static func percentage(for usage: ContextUsageSnapshot) -> String {
        usage.progress.map { String(Int(($0 * 100).rounded())) } ?? "0"
    }

    static func tone(progress: Double?) -> Tone {
        guard let progress else { return .neutral }
        if progress > 0.9 { return .critical }
        if progress > 0.7 { return .warning }
        return .normal
    }
}

enum MacSessionFilesInspectorSection: String, CaseIterable, Identifiable, Sendable {
    case browser
    case changes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: "Browser"
        case .changes: "Changes"
        }
    }
}

struct MacSessionToolbarTitle: View {
    let presentation: MacSessionToolbarPresentation

    var body: some View {
        VStack(spacing: 1) {
            Text(presentation.title)
                .font(.headline)
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(presentation.detailText)
                .font(.caption2)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.detailText)
        .accessibilityIdentifier("mac.session.toolbar.title")
    }
}

struct MacSessionContextToolbarLabel: View {
    let usage: ContextUsageSnapshot

    var body: some View {
        MacSessionContextRing(usage: usage)
    }
}

private struct MacSessionContextRing: View {
    let usage: ContextUsageSnapshot

    private var strokeColor: Color {
        switch MacSessionContextRingPaint.tone(progress: usage.progress) {
        case .neutral: .themeComment
        case .normal: .themeGreen
        case .warning: .themeOrange
        case .critical: .themeRed
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.themeComment.opacity(0.35), lineWidth: 2)

            if let progress = usage.progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        strokeColor,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            Text(MacSessionContextRingPaint.percentage(for: usage))
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.themeFg)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

struct SessionTraceShellDetail: View {
    let store: MacSessionTraceStore
    let workspace: Workspace?
    let isStoppingSession: Bool
    let stopSession: () async -> Void
    @State private var isInspectorPresented = MacSessionWindowChrome.inspectorInitiallyPresented
    @State private var selectedFilesSection: MacSessionFilesInspectorSection = .browser
    @State private var isOutlinePresented = false
    @State private var isContextPresented = false
    @State private var composerHeight = MacSessionTimelineOverlap.defaultComposerHeight
    @State private var openPlan: FileViewerPlan?
    @State private var openDescriptor: ToolContentDescriptor?
    @State private var isLoadingDocument = false
    @State private var documentError: String?
    @State private var fontPreferenceRevision = 0
    @FocusState private var sessionFocus: KeybindingFocus?

    var body: some View {
        let _ = fontPreferenceRevision
        GeometryReader { proxy in
            sessionColumns(for: MacSessionShellLayoutPolicy.columns(
                availableWidth: proxy.size.width,
                hasDocument: hasOpenDocument
            ))
        }
            .background {
                Rectangle()
                    .fill(.themeBg)
                    .ignoresSafeArea()
            }
            .environment(\.macOpenFileViewer, MacOpenFileViewerAction { plan in
                openPlan = plan
            })
            .environment(\.macReviewCommentStaging, reviewCommentStaging)
            .navigationTitle(store.session?.displayTitle ?? "Session")
            .toolbar {
                sessionToolbar
            }
            .inspector(isPresented: inspectorPresentation) {
                sessionInspector
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            }
            .task(id: store.selectedTarget?.sessionId) {
                await store.loadSelectedFromLocalConfig()
            }
            .task(id: openPlan) {
                await loadOpenedDocument()
            }
            .onChange(of: store.selectedTarget?.sessionId) { _, _ in
                closeFileDocument()
                selectedFilesSection = .browser
                isOutlinePresented = false
                isContextPresented = false
            }
            .onChange(of: sessionFocus) { _, new in
                store.keybindingFocus = new ?? .composer
            }
            .onChange(of: store.keybindingFocus) { _, new in
                if sessionFocus != new {
                    sessionFocus = new
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: FontPreferenceStore.didChangeNotification
            )) { _ in
                fontPreferenceRevision &+= 1
            }
    }

    private var hasOpenDocument: Bool {
        MacSessionShellLayoutPolicy.hasDocument(
            workspaceDocumentIsOpen: openPlan != nil,
            toolDocumentIsOpen: store.openToolDocumentID != nil
        )
    }

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: {
                MacSessionShellLayoutPolicy.shouldPresentInspector(
                    requested: isInspectorPresented,
                    hasDocument: hasOpenDocument
                )
            },
            set: { requested in
                isInspectorPresented = MacSessionShellLayoutPolicy.shouldPresentInspector(
                    requested: requested,
                    hasDocument: hasOpenDocument
                )
            }
        )
    }

    @ViewBuilder
    private func sessionColumns(for layout: MacSessionShellColumnLayout) -> some View {
        switch layout {
        case .timelineOnly:
            timelineColumn
        case .documentOnly:
            documentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .timelineAndDocument:
            HSplitView {
                timelineColumn
                documentColumn
                    .frame(
                        minWidth: MacToolDocumentColumnMetrics.minWidth,
                        idealWidth: MacToolDocumentColumnMetrics.idealWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }
        }
    }

    private var timelineColumn: some View {
        MacSessionTimelineView(
            isLoading: store.isLoading,
            lastError: store.lastError,
            items: store.items,
            sessionID: store.selectedTarget?.sessionId,
            workspaceID: store.selectedTarget?.workspaceId,
            toolOutputStore: store.toolOutputStore,
            loadFullToolOutput: { itemID in
                await store.loadFullToolOutputIfNeeded(itemID: itemID)
            },
            bottomContentInset: MacSessionTimelineOverlap.bottomContentInset(
                composerHeight: composerHeight
            ),
            isBusy: store.session?.status.isRunning == true,
            store: store,
            sessionFocus: $sessionFocus
        )
        .frame(
            minWidth: MacSessionShellLayoutPolicy.timelineMinimumWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .overlay(alignment: .bottom) {
            MacSessionComposerBar(
                store: store,
                sessionFocus: $sessionFocus
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { composerHeight = $0 }
        }
    }

    @ViewBuilder
    private var documentColumn: some View {
        if let plan = openPlan {
            MacToolDocumentColumn(
                plan: plan,
                descriptor: openDescriptor,
                isLoading: isLoadingDocument,
                error: documentError,
                close: closeFileDocument
            )
        } else if store.openToolDocumentID != nil {
            MacToolDocumentColumn(
                store: store,
                sessionFocus: $sessionFocus
            )
        }
    }

    private var reviewCommentStaging: MacReviewCommentStaging? {
        guard let target = store.selectedTarget else { return nil }
        return MacReviewCommentStaging(
            workspaceID: target.workspaceId,
            sessionID: target.sessionId,
            beginDraft: { store.beginReviewCommentDraft($0) }
        )
    }

    private var toolbarPresentation: MacSessionToolbarPresentation? {
        let selectedTarget = store.selectedTarget
        guard let session = store.session ?? selectedTarget?.summary.session else {
            return nil
        }
        return MacSessionToolbarPresentation.make(
            session: session,
            selectedTarget: selectedTarget
        )
    }

    private func closeFileDocument() {
        openPlan = nil
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = false
    }

    private func loadOpenedDocument() async {
        guard let plan = openPlan else {
            openDescriptor = nil
            documentError = nil
            isLoadingDocument = false
            return
        }
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = true
        if !FileViewerDescriptorBuilder.needsFileBytes(path: plan.path) {
            guard openPlan == plan, !Task.isCancelled else { return }
            isLoadingDocument = false
            openDescriptor = FileViewerDescriptorBuilder.descriptor(path: plan.path, data: Data())
            documentError = nil
            return
        }
        let data = await MacMarkdownWorkspaceFileLoader.data(
            for: plan,
            sessionID: store.selectedTarget?.sessionId
        )
        guard openPlan == plan, !Task.isCancelled else { return }
        isLoadingDocument = false
        guard let data else {
            documentError = "Could not load \(plan.fileName)."
            openDescriptor = nil
            return
        }
        openDescriptor = FileViewerDescriptorBuilder.descriptor(path: plan.path, data: data)
        documentError = nil
    }

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let toolbarPresentation {
                MacSessionToolbarTitle(presentation: toolbarPresentation)
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            MacAssistantAvatarView(avatar: .officialPi, sessionId: store.selectedTarget?.sessionId ?? "session", size: 26)
                .accessibilityLabel("Pi")
                .accessibilityIdentifier("mac.session.toolbar.piIdentity")
                .help("Pi session")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                isInspectorPresented.toggle()
            } label: {
                Label(
                    isInspectorPresented ? "Close Files" : "Files",
                    systemImage: isInspectorPresented ? "folder.fill" : "folder"
                )
                .labelStyle(.iconOnly)
            }
            .help("Session Files")
            .accessibilityLabel(isInspectorPresented ? "Close session files" : "Open session files")
            .accessibilityIdentifier("mac.session.toolbar.files")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                isOutlinePresented.toggle()
            } label: {
                Label("Session Outline", systemImage: "list.bullet")
                    .labelStyle(.iconOnly)
            }
            .help("Session Outline")
            .accessibilityLabel("Open session outline")
            .accessibilityIdentifier("mac.session.toolbar.outline")
            .popover(isPresented: $isOutlinePresented, arrowEdge: .bottom) {
                MacSessionOutlineView(store: store) {
                    isOutlinePresented = false
                }
                .frame(width: 380, height: 480)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if store.session != nil || store.selectedTarget != nil {
                contextToolbarItem
            }
        }
    }

    @ViewBuilder
    private var contextToolbarItem: some View {
        let usage = SessionContextUsagePresentation.snapshot(for: store.session)
        Button {
            isContextPresented.toggle()
        } label: {
            MacSessionContextToolbarLabel(usage: usage)
        }
        .help(SessionContextUsagePresentation.toolbarTitle(usage))
        .accessibilityIdentifier("mac.session.toolbar.context")
        .accessibilityLabel("Open context inspector")
        .accessibilityValue(usage.accessibilityLabel)
        .popover(isPresented: $isContextPresented, arrowEdge: .bottom) {
            MacSessionContextInspectorView(store: store)
                .frame(width: 380, height: 480)
        }
    }

    @ViewBuilder
    private var sessionInspector: some View {
        VStack(spacing: 0) {
            Picker("Files view", selection: $selectedFilesSection) {
                ForEach(MacSessionFilesInspectorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch selectedFilesSection {
            case .browser:
                if let workspace {
                    MacWorkspaceFileBrowserView(
                        workspace: workspace,
                        worktreeId: store.session?.worktreeId ?? WorkspaceWorktree.mainId,
                        openPlan: $openPlan
                    )
                } else {
                    ContentUnavailableView(
                        "No workspace files",
                        systemImage: "folder.badge.questionmark",
                        description: Text("This control session is not attached to a workspace.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .changes:
                sessionChangesInspector
            }
        }
        .themedScrollSurface()
        .navigationTitle("Files")
    }

    private var sessionChangesInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.isLoadingSessionChanges
                    || !store.sessionChangedFiles.isEmpty
                    || store.sessionChangedFileCount > 0
                    || store.sessionChangesError != nil {
                    MacSessionChangedFilesCard(
                        files: store.sessionChangedFiles,
                        changedFileCount: store.sessionChangedFileCount,
                        overflow: store.sessionChangedFilesOverflow,
                        isLoading: store.isLoadingSessionChanges,
                        isLoadingDiff: store.isLoadingSessionDiff,
                        isLoadingPreview: store.isLoadingSessionFilePreview,
                        error: store.sessionChangesError,
                        diffError: store.sessionDiffError,
                        previewError: store.sessionFilePreviewError,
                        refresh: { await store.loadSessionChangesFromLocalConfig() },
                        loadDiff: { path in await store.loadSessionDiffFromLocalConfig(path: path) },
                        loadPreview: { path in await store.loadSessionFilePreviewFromLocalConfig(path: path) }
                    )
                }
                if let preview = store.selectedSessionFilePreview {
                    MacSessionFilePreviewCard(preview: preview, close: { store.clearSessionFilePreview() })
                }
                if let diff = store.selectedSessionDiff {
                    MacSessionDiffPreview(diff: diff, close: { store.clearSessionDiff() })
                }
                if store.sessionChangedFiles.isEmpty,
                   store.selectedSessionFilePreview == nil,
                   store.selectedSessionDiff == nil,
                   !store.isLoadingSessionChanges {
                    ContentUnavailableView(
                        "No file changes",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Changed files and previews for this session appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(16)
        }
    }
}

private struct MacSessionChangedFilesCard: View {
    let files: [SessionChangedFile]
    let changedFileCount: Int
    let overflow: Int
    let isLoading: Bool
    let isLoadingDiff: Bool
    let isLoadingPreview: Bool
    let error: String?
    let diffError: String?
    let previewError: String?
    let refresh: () async -> Void
    let loadDiff: (String) async -> Void
    let loadPreview: (String) async -> Void

    private var displayedCount: Int {
        changedFileCount > 0 ? changedFileCount : files.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Changed files", systemImage: "doc.on.doc")
                    .font(.headline)
                Text("\(displayedCount)")
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
                Spacer()
                if isLoading || isLoadingDiff || isLoadingPreview {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh changed files", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let diffError, !diffError.isEmpty {
                Text(diffError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let previewError, !previewError.isEmpty {
                Text(previewError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if files.isEmpty, error == nil {
                Text(isLoading ? "Loading changed files…" : "No changed files reported for this session yet.")
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
            } else if !files.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8)], alignment: .leading, spacing: 6) {
                    ForEach(files.prefix(8)) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.themeFgDim)
                            Text(MacPathPaint.inspectorLabel(file.path))
                                .font(Font(FontPreferenceStore.macCodeFont()))
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(0)
                                .help(file.path)
                                .accessibilityValue(file.path)
                            Spacer(minLength: 0)
                            Button("Preview") {
                                Task { await loadPreview(file.path) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingPreview)
                            .fixedSize()
                            Button("Diff") {
                                Task { await loadDiff(file.path) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingDiff)
                            .fixedSize()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.path, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy workspace path")
                            .fixedSize()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.themeBgHighlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                if files.count > 8 || overflow > 0 {
                    Text("\(max(files.count - 8, 0) + overflow) more changed files")
                        .font(.caption)
                        .foregroundStyle(.themeFgDim)
                }
            }
        }
        .padding(12)
        .background(.themeBgDark, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.themeComment.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct MacSessionFilePreviewCard: View {
    let preview: MacSessionFilePreview
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(preview.path, systemImage: preview.kind.systemImage)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(preview.displayDetail)
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(.borderless)
            }

            switch preview.kind {
            case .text:
                MacTextFileSourcePreview(preview: preview)
            case .image:
                if let imageData = preview.imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.themeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text("Image preview is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.themeFgDim)
                }
            case .binary:
                Text("Binary preview is unavailable. Use Copy path and inspect the file from the workspace when needed.")
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
            }
        }
        .padding(12)
        .background(.themeBgDark, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.themeComment.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct MacTextFileSourcePreview: View {
    let preview: MacSessionFilePreview

    var body: some View {
        if case .orgMode = preview.fileType, let text = preview.text {
            MacOrgDocumentPreview(content: text)
        } else if let language = preview.sourceLanguageLabel, let text = preview.text {
            MacCodeOutputPreview(
                model: MacCodeOutputModel(language: language, text: text),
                source: MacReviewCommentSource.fileDocument(path: preview.path)
            )
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(preview.text?.isEmpty == false ? preview.text ?? "" : " ")
                    .font(Font(FontPreferenceStore.macCodeFont()))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.themeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct MacSessionDiffPreview: View {
    let diff: WorkspaceReviewDiffResponse
    let close: () -> Void

    private var plan: WorkspaceReviewDiffPreviewPlan {
        WorkspaceReviewDiffPreviewPlan(diff: diff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(diff.path, systemImage: "plus.forwardslash.minus")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("+\(diff.addedLines) −\(diff.removedLines)")
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
                if let revisionCount = diff.revisionCount {
                    Text("\(revisionCount) edits")
                        .font(.caption)
                        .foregroundStyle(.themeFgDim)
                }
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(.borderless)
            }

            if diff.hunks.isEmpty {
                Text("No textual changes")
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
            } else {
                if let truncationMessage = plan.truncationMessage {
                    Label(truncationMessage, systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.themeFgDim)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.hunks) { visibleHunk in
                            Text(visibleHunk.headerText)
                                .font(Font(FontPreferenceStore.macCodeFont()))
                                .foregroundStyle(.purple)
                            ForEach(visibleHunk.lines) { line in
                                HStack(spacing: 8) {
                                    Text(line.kind.prefix)
                                        .frame(width: 12, alignment: .center)
                                    Text(line.text.isEmpty ? " " : line.text)
                                }
                                .font(Font(FontPreferenceStore.macCodeFont()))
                                .foregroundStyle(color(for: line.kind))
                            }
                            if visibleHunk.hiddenLineCount > 0 {
                                Text("… \(visibleHunk.hiddenLineCount) more lines in this hunk")
                                    .font(Font(FontPreferenceStore.macCodeFont()))
                                    .foregroundStyle(.themeFgDim)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.themeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(12)
        .background(.themeBgDark, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.themeComment.opacity(0.25), lineWidth: 1)
        )
    }

    private func color(for kind: WorkspaceReviewDiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .context: .primary
        }
    }
}

struct SessionShellDetail: View {
    let session: StatsActiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(session.workspaceName ?? "Local workspace")
                    .foregroundStyle(.themeFgDim)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Status").foregroundStyle(.themeFgDim)
                    Text(session.status.capitalized)
                }
                if let model = session.model {
                    GridRow {
                        Text("Model").foregroundStyle(.themeFgDim)
                        Text(model)
                    }
                }
                GridRow {
                    Text("Cost").foregroundStyle(.themeFgDim)
                    Text(SessionFormatting.costString(session.cost))
                }
                if let contextTokens = session.contextTokens, let contextWindow = session.contextWindow {
                    GridRow {
                        Text("Context").foregroundStyle(.themeFgDim)
                        Text("\(contextTokens) / \(contextWindow)")
                    }
                }
            }
            .font(.callout)

            MacShellEmptyDetail(
                title: "Open from a workspace for chat",
                message: "This runtime row came from local server stats. Choose the same session under Workspaces or Recent sessions to load trace history and enable the composer.",
                systemImage: "arrow.turn.down.right"
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()
        }
    }
}
