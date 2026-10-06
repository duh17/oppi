import SwiftUI
import UIKit

struct FullScreenViewerNavigationAction {
    let id: String
    let title: String?
    let systemImage: String?
    let accessibilityLabel: String
    let accessibilityValue: String?
    let isEnabled: Bool
    let handler: @MainActor @Sendable () -> Void

    init(
        id: String,
        title: String? = nil,
        systemImage: String? = nil,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        isEnabled: Bool = true,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.isEnabled = isEnabled
        self.handler = handler
    }

    var presentation: Presentation {
        Presentation(
            id: id,
            title: title,
            systemImage: systemImage,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            isEnabled: isEnabled
        )
    }

    struct Presentation: Equatable {
        let id: String
        let title: String?
        let systemImage: String?
        let accessibilityLabel: String
        let accessibilityValue: String?
        let isEnabled: Bool
    }
}

@MainActor
final class ThinkingTraceStream {
    struct Snapshot: Equatable {
        let text: String
        let isDone: Bool
    }

    private var snapshotStorage: Snapshot
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    init(text: String, isDone: Bool) {
        snapshotStorage = Snapshot(text: text, isDone: isDone)
    }

    var snapshot: Snapshot {
        snapshotStorage
    }

    func update(text: String, isDone: Bool) {
        let next = Snapshot(text: text, isDone: isDone)
        guard next != snapshotStorage else { return }
        // `DeltaCoalescer` is the only live clock. Deliver every distinct
        // snapshot immediately so fullscreen thinking does not invent a
        // second cadence.
        snapshotStorage = next
        deliver(next)
    }

    private func deliver(_ snapshot: Snapshot) {
        for observer in observers.values {
            observer(snapshot)
        }
    }

    @discardableResult
    func addObserver(deliverImmediately: Bool = true, _ observer: @escaping (Snapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        if deliverImmediately {
            observer(snapshotStorage)
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

}

@MainActor
final class TerminalTraceStream {
    /// Finished-call sidecar. A reader opened after completion loads this when
    /// the content did not already pass a sidecar source. The snapshot is the
    /// JSON text preview.
    var completionSidecarSource: ToolOutputSidecarWindowSource?

    struct Snapshot: Equatable {
        let output: String
        let command: String?
        let isDone: Bool
    }

    private var snapshotStorage: Snapshot
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    init(output: String, command: String?, isDone: Bool) {
        snapshotStorage = Snapshot(output: output, command: command, isDone: isDone)
    }

    var snapshot: Snapshot { snapshotStorage }

    func update(output: String, command: String?, isDone: Bool) {
        let next = Snapshot(output: output, command: command, isDone: isDone)
        guard next != snapshotStorage else { return }

        snapshotStorage = next
        for observer in observers.values {
            observer(next)
        }
    }

    @discardableResult
    func addObserver(deliverImmediately: Bool = true, _ observer: @escaping (Snapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        if deliverImmediately {
            observer(snapshotStorage)
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

@MainActor
final class SourceTraceStream {
    struct Snapshot {
        let text: String
        let filePath: String?
        let isDone: Bool
        let finalContent: FullScreenCodeContent?
    }

    private var snapshotStorage: Snapshot
    private var observers: [UUID: (Snapshot) -> Void] = [:]

    init(text: String, filePath: String?, isDone: Bool, finalContent: FullScreenCodeContent?) {
        snapshotStorage = Snapshot(
            text: text,
            filePath: filePath,
            isDone: isDone,
            finalContent: finalContent
        )
    }

    // periphery:ignore
    var snapshot: Snapshot {
        snapshotStorage
    }

    func update(text: String, filePath: String?, isDone: Bool, finalContent: FullScreenCodeContent?) {
        let next = Snapshot(
            text: text,
            filePath: filePath,
            isDone: isDone,
            finalContent: finalContent
        )
        guard shouldNotify(for: next) else { return }

        snapshotStorage = next
        for observer in observers.values {
            observer(next)
        }
    }

    @discardableResult
    func addObserver(deliverImmediately: Bool = true, _ observer: @escaping (Snapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        if deliverImmediately {
            observer(snapshotStorage)
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func shouldNotify(for next: Snapshot) -> Bool {
        next.text != snapshotStorage.text
            || next.filePath != snapshotStorage.filePath
            || next.isDone != snapshotStorage.isDone
            || finalContentKind(next.finalContent) != finalContentKind(snapshotStorage.finalContent)
    }

    private func finalContentKind(_ content: FullScreenCodeContent?) -> String? {
        switch content {
        case .code:
            return "code"
        case .plainText:
            return "plainText"
        case .diff:
            return "diff"
        case .markdown:
            return "markdown"
        case .html:
            return "html"
        case .thinking:
            return "thinking"
        case .terminal:
            return "terminal"
        case .liveSource:
            return "liveSource"
        case .latex:
            return "latex"
        case .orgMode:
            return "orgMode"
        case .mermaid:
            return "mermaid"
        case .graphviz:
            return "graphviz"
        case .document(let family):
            return family.kindName
        case .notebook:
            return "notebook"
        case nil:
            return nil
        }
    }
}

/// Lines-first payload for a completed full-screen tool diff.
///
/// `lines` are the only diff authority. `copyText` is clipboard, share, and
/// initial selectable text (often a unified patch). HTML render and line-anchor
/// notices use `reconstructedNewSideText`, never `copyText`.
struct ToolDiffDocument: Sendable {
    let lines: [DiffLine]
    let filePath: String?
    let copyText: String

    var reconstructedNewSideText: String {
        lines
            .filter { $0.kind != .removed }
            .map { $0.text }
            .joined(separator: "\n")
    }
}

/// Full-screen content viewer for tool output.
///
/// Supports three modes:
/// - `.code`: syntax-highlighted source with line numbers
/// - `.diff`: lines-first tool diff with add/remove coloring
/// - `.markdown`: full markdown note/reader rendering
indirect enum FullScreenCodeContent {
    case code(content: String, language: String?, filePath: String?, startLine: Int)
    case plainText(content: String, filePath: String?)
    case diff(ToolDiffDocument)
    case markdown(content: String, filePath: String?, resourceAccess: MarkdownResourceAccess = .empty, rawText: String? = nil, sidecarSource: ToolOutputSidecarWindowSource? = nil)
    case html(content: String, filePath: String?)
    case thinking(content: String, stream: ThinkingTraceStream? = nil)
    case terminal(
        content: String,
        command: String?,
        stream: TerminalTraceStream? = nil,
        sidecarSource: ToolOutputSidecarWindowSource? = nil
    )
    case liveSource(snapshot: SourceTraceStream.Snapshot, stream: SourceTraceStream)

    // Document renderers
    case latex(content: String, filePath: String?)
    case orgMode(content: String, filePath: String?)
    case mermaid(content: String, filePath: String?)
    case graphviz(content: String, filePath: String?)
    /// CSV/TSV table or GeoJSON/TopoJSON map; `DocumentFamily` owns the per-kind behavior.
    case document(DocumentFamily)
    /// Notebook cell. The reader wraps the same view.
    case notebook(NotebookCellPlan)

    /// Build content from raw text and a file path by detecting the file type.
    static func fromText(_ text: String, filePath: String?) -> FullScreenCodeContent {
        let fileType = FileType.detect(from: filePath, content: text)
        if let document = DocumentFamily(fileType: fileType, text: text, filePath: filePath) {
            return .document(document)
        }
        switch fileType {
        case .markdown: return .markdown(content: text, filePath: filePath)
        case .html: return .html(content: text, filePath: filePath)
        case .latex: return .latex(content: text, filePath: filePath)
        case .orgMode: return .orgMode(content: text, filePath: filePath)
        case .mermaid: return .mermaid(content: text, filePath: filePath)
        case .graphviz: return .graphviz(content: text, filePath: filePath)
        case .json:
            return .code(content: text, language: "json", filePath: filePath, startLine: 1)
        case .code(let lang):
            return .code(content: text, language: lang.displayName, filePath: filePath, startLine: 1)
        case .plain:
            return .plainText(content: text, filePath: filePath)
        default:
            return .plainText(content: text, filePath: filePath)
        }
    }

    /// Build content from raw text with resource access for markdown image and media resolution.
    /// The access is only used for `.markdown` — other file types ignore it.
    static func fromText(
        _ text: String,
        filePath: String?,
        resourceAccess: MarkdownResourceAccess
    ) -> FullScreenCodeContent {
        let base = fromText(text, filePath: filePath)
        if case .markdown(let content, let path, _, let rawText, let sidecarSource) = base {
            return .markdown(content: content, filePath: path, resourceAccess: resourceAccess, rawText: rawText, sidecarSource: sidecarSource)
        }
        return base
    }
}

/// SwiftUI wrapper around ``FullScreenCodeViewController``.
///
/// Used by the `.fullScreenViewer` modifier and by SwiftUI hosts that embed
/// the viewer directly. All rendering is UIKit.
// MARK: - Full-Screen Sheet Modifier

extension View {
    /// Attach a full-screen code viewer sheet to any view.
    ///
    /// Centralizes the sheet presentation config (detents, grabber) that was
    /// previously copy-pasted across every file view. Callers keep their own
    /// `@State var showFullScreen` because they trigger it from different
    /// places (expand button, context menu, etc.).
    ///
    /// Usage:
    /// ```swift
    /// myView
    ///     .fullScreenViewer(
    ///         isPresented: $showFullScreen,
    ///         content: .markdown(content: text, filePath: path)
    ///     )
    /// ```
    func fullScreenViewer(
        isPresented: Binding<Bool>,
        content: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
        sessionId: String? = nil,
        sourceLabel: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        lineAnchorNotice: (@MainActor @Sendable (String) -> Void)? = nil
    ) -> some View {
        modifier(
            FullScreenViewerPresentationModifier(
                isPresented: isPresented,
                viewerContent: content,
                reviewCommentSelectionContext: reviewCommentSelectionContext,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                sessionId: sessionId,
                sourceLabel: sourceLabel,
                lineAnchor: lineAnchor,
                lineAnchorNotice: lineAnchorNotice
            )
        )
    }
}

private struct FullScreenViewerPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let viewerContent: FullScreenCodeContent
    let reviewCommentSelectionContext: ReviewCommentSelectionContext?
    let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    let sessionId: String?
    let sourceLabel: String?
    let lineAnchor: SourceLineAnchor?
    let lineAnchorNotice: (@MainActor @Sendable (String) -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openChatReader) private var openChatReader

    private var prefersFullScreenCover: Bool {
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let openChatReader {
            content.onChange(of: isPresented) { _, presented in
                guard presented else { return }
                isPresented = false
                openChatReader(
                    .document(
                        content: viewerContent,
                        reviewCommentSelectionContext: reviewCommentSelectionContext
                            ?? ReviewCommentSelectionContext(
                                router: reviewCommentSelectionRouter,
                                sessionId: sessionId,
                                sourceLabel: sourceLabel
                            )
                    )
                )
            }
        } else if prefersFullScreenCover {
            content.fullScreenCover(isPresented: $isPresented) {
                fullScreenCodeView
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                fullScreenCodeView
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var fullScreenCodeView: some View {
        FullScreenCodeView(
            content: viewerContent,
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSessionId: sessionId,
            reviewCommentSourceLabel: sourceLabel,
            lineAnchor: lineAnchor,
            lineAnchorNotice: lineAnchorNotice
        )
    }
}

// MARK: - FullScreenCodeView

struct FullScreenCodeView: UIViewControllerRepresentable {
    let content: FullScreenCodeContent
    var reviewCommentSelectionContext: ReviewCommentSelectionContext?
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    let reviewCommentSessionId: String?
    let reviewCommentSourceLabel: String?
    let lineAnchor: SourceLineAnchor?
    let lineAnchorNotice: (@MainActor @Sendable (String) -> Void)?
    var navigationActions: [FullScreenViewerNavigationAction]

    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @Environment(\.themeID) private var themeID

    /// Effective action context for this fullscreen presentation.
    private var effectiveReviewCommentSelectionContext: ReviewCommentSelectionContext? {
        reviewCommentSelectionContext
            ?? reviewCommentSelectionRouter.map { ReviewCommentSelectionContext(router: $0, sessionId: reviewCommentSessionId, sourceLabel: reviewCommentSourceLabel) }
            ?? reviewCommentSelectionScope?.makeContext(
                sessionId: reviewCommentSessionId,
                sourceLabel: reviewCommentSourceLabel
            )
    }

    init(
        content: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
        reviewCommentSessionId: String? = nil,
        reviewCommentSourceLabel: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        lineAnchorNotice: (@MainActor @Sendable (String) -> Void)? = nil,
        navigationActions: [FullScreenViewerNavigationAction] = []
    ) {
        self.content = content
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSessionId = reviewCommentSessionId
        self.reviewCommentSourceLabel = reviewCommentSourceLabel
        self.lineAnchor = lineAnchor
        self.lineAnchorNotice = lineAnchorNotice
        self.navigationActions = navigationActions
    }

    func makeUIViewController(context: Context) -> FullScreenCodeViewController {
        FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            lineAnchorNotice: lineAnchorNotice,
            navigationActions: navigationActions
        )
    }

    func updateUIViewController(_ uiViewController: FullScreenCodeViewController, context: Context) {
        // Content is immutable, but the UIKit body and chrome persist across
        // SwiftUI updates and must explicitly follow live environment changes.
        uiViewController.setNavigationActions(navigationActions)
        uiViewController.applyThemeIfNeeded(themeID)
    }
}
