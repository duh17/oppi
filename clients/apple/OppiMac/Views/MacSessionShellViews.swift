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
        let statusTitle = SessionStatusKind.resolve(
            session: session,
            pendingAskCount: matchingSummary?.pendingAskCount ?? 0,
            seenAt: nil
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
    var composerState: MacSessionComposerState? = nil
    var presentation: MacSessionPanePresentationState = MacSessionPanePresentationState()
    var isActivePane = true
    var activatePane: (() -> Void)? = nil
    var loadsSessionOnMount = true
    var chromePlacement: MacSessionChromePlacement = .windowToolbar
    var closePane: (() -> Void)? = nil
    @State private var ownedComposerState = MacSessionComposerState()
    @State private var openDescriptor: ToolContentDescriptor?
    @State private var isLoadingDocument = false
    @State private var documentError: String?
    @Environment(\.macTypographyRevision) private var typographyRevision
    @FocusState private var sessionFocus: KeybindingFocus?

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { presentation.isInspectorPresented },
            set: { presentation.isInspectorPresented = $0 }
        )
    }

    private var filesSection: Binding<MacSessionFilesInspectorSection> {
        Binding(
            get: { presentation.selectedFilesSection },
            set: { presentation.selectedFilesSection = $0 }
        )
    }

    private var outlinePresented: Binding<Bool> {
        Binding(
            get: { presentation.isOutlinePresented },
            set: { presentation.isOutlinePresented = $0 }
        )
    }

    private var contextPresented: Binding<Bool> {
        Binding(
            get: { presentation.isContextPresented },
            set: { presentation.isContextPresented = $0 }
        )
    }

    private var openPlanBinding: Binding<FileViewerPlan?> {
        Binding(
            get: { presentation.openPlan },
            set: { presentation.openPlan = $0 }
        )
    }

    var body: some View {
        let _ = typographyRevision
        Group {
            if chromePlacement == .pane {
                VStack(spacing: 0) {
                    paneSessionChrome
                    sessionCanvas
                }
            } else {
                sessionCanvas
                    .navigationTitle(store.session?.displayTitle ?? "Session")
                    .toolbar {
                        sessionToolbar
                    }
                    .inspector(isPresented: inspectorPresentation) {
                        sessionInspector
                            .navigationTitle("Files")
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                    }
            }
        }
            .background {
                Rectangle()
                    .fill(.themeBg)
                    .ignoresSafeArea()
            }
            .environment(\.macOpenFileViewer, MacOpenFileViewerAction { plan in
                presentation.openPlan = plan
            })
            .environment(\.macReviewCommentStaging, reviewCommentStaging)
            .task(id: store.selectedTarget?.sessionId) {
                guard loadsSessionOnMount else { return }
                await store.mountSelectedFromLocalConfig()
            }
            .task(id: presentation.openPlan) {
                await loadOpenedDocument()
            }
            .onChange(of: store.selectedTarget?.sessionId) { _, _ in
                closeFileDocument()
            }
            .onChange(of: sessionFocus) { _, new in
                store.keybindingFocus = new ?? .composer
            }
            .onChange(of: store.keybindingFocus) { _, new in
                guard isActivePane else { return }
                if sessionFocus != new {
                    sessionFocus = new
                }
            }
            .onChange(of: isActivePane) { _, active in
                if !active {
                    sessionFocus = nil
                }
            }
            .focusedSceneValue(\.macSessionFilesCommand, filesCommandItem)
            .focusedSceneValue(\.macSessionOutlineCommand, outlineCommandItem)
            .focusedSceneValue(\.macSessionContextCommand, contextCommandItem)
    }

    private var hasOpenDocument: Bool {
        MacSessionShellLayoutPolicy.hasDocument(
            workspaceDocumentIsOpen: presentation.openPlan != nil,
            toolDocumentIsOpen: store.openToolDocumentID != nil
        )
    }

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: {
                MacSessionShellLayoutPolicy.shouldPresentInspector(
                    requested: presentation.isInspectorPresented,
                    hasDocument: hasOpenDocument
                )
            },
            set: { requested in
                presentation.isInspectorPresented = MacSessionShellLayoutPolicy.shouldPresentInspector(
                    requested: requested,
                    hasDocument: hasOpenDocument
                )
            }
        )
    }

    private var filesCommandItem: MacSessionCommandItem? {
        panelCommandItem(action: toggleFiles)
    }

    private var outlineCommandItem: MacSessionCommandItem? {
        panelCommandItem(action: toggleOutline)
    }

    private var contextCommandItem: MacSessionCommandItem? {
        panelCommandItem(action: toggleContext)
    }

    private func panelCommandItem(action: @escaping () -> Void) -> MacSessionCommandItem? {
        guard store.selectedTarget?.sessionId != nil else { return nil }
        return MacSessionCommandItem(enabled: true, action: action)
    }

    private func toggleFiles() {
        presentation.isInspectorPresented.toggle()
    }

    private func toggleOutline() {
        presentation.isOutlinePresented.toggle()
    }

    private func toggleContext() {
        presentation.isContextPresented.toggle()
    }

    private var hasLiveAsk: Bool {
        store.currentExtensionRequest != nil
            || (store.selectedTarget?.summary.pendingAskCount ?? 0) > 0
    }

    private var paneTitle: String {
        store.session?.displayTitle
            ?? store.selectedTarget?.summary.session.displayTitle
            ?? "Session"
    }

    private var showsPaneFiles: Bool {
        chromePlacement == .pane && presentation.isInspectorPresented
    }

    private var sessionCanvas: some View {
        GeometryReader { proxy in
            laidOutSession(width: proxy.size.width)
        }
    }

    @ViewBuilder
    private func laidOutSession(width: CGFloat) -> some View {
        let filesBesideTimeline = showsPaneFiles
            && MacSessionWindowChrome.presentsFilesBesideTimeline(availableWidth: width)
        let timelineWidth = filesBesideTimeline
            ? width - MacSessionWindowChrome.filesColumnWidth(availableWidth: width)
            : width
        let columns = sessionColumns(for: MacSessionShellLayoutPolicy.columns(
            availableWidth: timelineWidth,
            hasDocument: hasOpenDocument
        ))
        if showsPaneFiles {
            if filesBesideTimeline {
                HStack(spacing: 0) {
                    columns
                    Divider()
                    sessionInspector
                        .frame(width: MacSessionWindowChrome.filesColumnWidth(availableWidth: width))
                }
            } else {
                sessionInspector
            }
        } else {
            columns
        }
    }

    private var paneSessionChrome: some View {
        HStack(spacing: 6) {
            Text(paneTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .truncationMode(.tail)
            if hasLiveAsk {
                Image(systemName: "questionmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeOrange)
                    .accessibilityLabel("Needs input")
                    .accessibilityIdentifier("mac.session.pane.ask")
                    .help("Needs input")
            }
            Spacer(minLength: 8)
            filesButton
            outlineButton
            if store.session != nil || store.selectedTarget != nil {
                contextButton
            }
            if let closePane {
                MacPaneCloseControl(sessionTitle: paneTitle, action: closePane)
                    .frame(width: 16, height: 16)
                    .help("Close Pane")
                    .accessibilityLabel("Close \(paneTitle) pane")
                    .accessibilityIdentifier("mac.session.pane.close")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.session.pane.header")
    }

    private var filesButton: some View {
        Button(action: toggleFiles) {
            Label(
                presentation.isInspectorPresented ? "Close Files" : "Files",
                systemImage: presentation.isInspectorPresented ? "folder.fill" : "folder"
            )
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Session Files")
        .accessibilityLabel(presentation.isInspectorPresented ? "Close session files" : "Open session files")
        .accessibilityIdentifier("mac.session.toolbar.files")
    }

    private var outlineButton: some View {
        Button(action: toggleOutline) {
            Label("Session Outline", systemImage: "list.bullet")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Session Outline")
        .accessibilityLabel("Open session outline")
        .accessibilityIdentifier("mac.session.toolbar.outline")
        .popover(isPresented: outlinePresented, arrowEdge: .bottom) {
            MacSessionOutlineView(store: store) {
                presentation.isOutlinePresented = false
            }
            .frame(width: 380, height: 480)
        }
    }

    private var contextButton: some View {
        let usage = SessionContextUsagePresentation.snapshot(for: store.session)
        return Button(action: toggleContext) {
            MacSessionContextToolbarLabel(usage: usage)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(SessionContextUsagePresentation.toolbarTitle(usage))
        .accessibilityIdentifier("mac.session.toolbar.context")
        .accessibilityLabel("Open context inspector")
        .accessibilityValue(usage.accessibilityLabel)
        .popover(isPresented: contextPresented, arrowEdge: .bottom) {
            MacSessionContextInspectorView(store: store)
                .frame(width: 380, height: 480)
        }
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
                composerHeight: presentation.composerHeight
            ),
            isBusy: store.session?.status.isRunning == true,
            store: store,
            sessionFocus: $sessionFocus,
            presentation: presentation
        )
        .frame(
            minWidth: MacSessionShellLayoutPolicy.timelineMinimumWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                guard !isActivePane else { return }
                activatePane?()
            }
        )
        .overlay(alignment: .bottom) {
            MacSessionComposerBar(
                store: store,
                sessionFocus: $sessionFocus,
                composerState: composerState ?? ownedComposerState,
                ownsDictationLifecycle: composerState == nil,
                isActivePane: isActivePane,
                activatePane: { activatePane?() }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { presentation.composerHeight = $0 }
        }
    }

    @ViewBuilder
    private var documentColumn: some View {
        if let plan = presentation.openPlan {
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
        presentation.openPlan = nil
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = false
    }

    private func loadOpenedDocument() async {
        guard let plan = presentation.openPlan else {
            openDescriptor = nil
            documentError = nil
            isLoadingDocument = false
            return
        }
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = true
        if !FileViewerDescriptorBuilder.needsFileBytes(path: plan.path) {
            guard presentation.openPlan == plan, !Task.isCancelled else { return }
            isLoadingDocument = false
            openDescriptor = FileViewerDescriptorBuilder.descriptor(path: plan.path, data: Data())
            documentError = nil
            return
        }
        let data = await MacMarkdownWorkspaceFileLoader.data(
            for: plan,
            sessionID: store.selectedTarget?.sessionId
        )
        guard presentation.openPlan == plan, !Task.isCancelled else { return }
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
            MacAssistantAvatarView(size: 26)
                .accessibilityLabel("Pi")
                .accessibilityIdentifier("mac.session.toolbar.piIdentity")
                .help("Pi session")
        }

        if hasLiveAsk {
            ToolbarItem(placement: .primaryAction) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.themeOrange)
                    .accessibilityLabel("Needs input")
                    .accessibilityIdentifier("mac.session.pane.ask")
                    .help("Needs input")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            filesButton
        }

        ToolbarItem(placement: .primaryAction) {
            outlineButton
        }

        ToolbarItem(placement: .primaryAction) {
            if store.session != nil || store.selectedTarget != nil {
                contextButton
            }
        }
    }

    @ViewBuilder
    private var sessionInspector: some View {
        VStack(spacing: 0) {
            Picker("Files view", selection: filesSection) {
                ForEach(MacSessionFilesInspectorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch presentation.selectedFilesSection {
            case .browser:
                if let workspace {
                    MacWorkspaceFileBrowserView(
                        workspace: workspace,
                        worktreeId: store.session?.worktreeId ?? WorkspaceWorktree.mainId,
                        openPlan: openPlanBinding
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

/// Split-pane close stays one AppKit button. SwiftUI icon buttons beside it
/// do not expose identifiers in an offscreen host, so an empty-title check
/// would count every icon as Close.
private struct MacPaneCloseControl: NSViewRepresentable {
    var sessionTitle: String
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.identifier = NSUserInterfaceItemIdentifier("mac.session.pane.close")
        button.toolTip = "Close Pane"
        button.setAccessibilityLabel("Close \(sessionTitle) pane")
        button.target = context.coordinator
        button.action = #selector(Coordinator.closePane)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.setAccessibilityLabel("Close \(sessionTitle) pane")
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func closePane() {
            action()
        }
    }
}

private struct MacSessionChangedFilesCard: View {
    @Environment(\.macTypographyRevision) private var typographyRevision
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
        let _ = typographyRevision
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
    @Environment(\.macTypographyRevision) private var typographyRevision
    let preview: MacSessionFilePreview

    var body: some View {
        let _ = typographyRevision
        if case .orgMode = preview.fileType, let text = preview.text {
            MacOrgDocumentPreview(content: text)
        } else if let language = preview.sourceLanguageLabel, let text = preview.text {
            MacCodeOutputPreview(
                model: MacCodeOutputModel(language: language, text: text),
                source: MacReviewCommentSource.fileDocument(path: preview.path)
            )
        } else {
            ScrollView(.horizontal) {
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
    @Environment(\.macTypographyRevision) private var typographyRevision
    let diff: WorkspaceReviewDiffResponse
    let close: () -> Void

    private var plan: WorkspaceReviewDiffPreviewPlan {
        WorkspaceReviewDiffPreviewPlan(diff: diff)
    }

    var body: some View {
        let _ = typographyRevision
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
                ScrollView(.horizontal) {
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
