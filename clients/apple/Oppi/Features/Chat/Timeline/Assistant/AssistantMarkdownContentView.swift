import UIKit

// MARK: - Rendering Mode

/// Controls how async content (mermaid diagrams, syntax highlighting, images)
/// is rendered in the markdown pipeline.
///
/// The same `AssistantMarkdownContentView` is used for both live chat display
/// and static export (image/PDF). Live mode dispatches expensive work to
/// background threads for scroll performance. Export mode renders everything
/// synchronously so the view is complete before snapshotting.
enum ContentRenderingMode: Equatable, Sendable {
    /// Async rendering for live display. Mermaid renders on background thread,
    /// syntax highlighting is scheduled, images load via URLSession.
    case live

    /// Static full-screen reader documents. Height-changing blocks (LaTeX,
    /// Mermaid) render synchronously so self-sizing cells measure their final
    /// height on the first pass — a later async resize would invalidate the
    /// reader's collection layout without a viewport anchor and visibly shift
    /// the scroll position. Images still load asynchronously like `.live`.
    case staticReader

    /// Synchronous rendering for export/snapshot. All content renders on the
    /// current thread so `view.layer.render(in:)` captures complete output.
    case export

    /// Whether block renderers that change their own height (LaTeX formulas,
    /// Mermaid diagrams) must finish synchronously before cell self-sizing.
    var rendersHeightChangingBlocksSynchronously: Bool {
        self == .staticReader || self == .export
    }
}

// MARK: - Native Markdown Content View

/// Native UIKit markdown renderer for assistant messages.
///
/// `AssistantMarkdownContentView` is now a thin coordinator over three layers:
/// - `AssistantMarkdownSegmentSource` builds `FlatSegment` arrays from markdown.
/// - `AssistantMarkdownSegmentApplier` maps those segments onto reusable UIKit views.
/// - `NativeCodeBlockView` / `NativeTableBlockView` render block-level surfaces.
final class AssistantMarkdownContentView: UIView {
    struct Configuration: Equatable {
        let content: String
        let isStreaming: Bool
        let themeID: ThemeID
        let textSelectionEnabled: Bool
        let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
        let reviewCommentSourceContext: ReviewCommentSourceContext?
        /// Stable server scope for resolving resource references at tap time.
        let serverID: String?
        /// Workspace context for resolving inline image paths and file candidates.
        let workspaceID: String?
        /// Session context retained for review and full-screen presentation.
        let sessionID: String?
        let serverBaseURL: URL?
        /// Path of the source markdown file in the workspace (e.g. "docs/readme.md").
        /// Used to resolve relative image paths against the file's directory.
        let sourceFilePath: String?
        /// Optional source line focus used by full-screen anchored file readers.
        let lineAnchor: SourceLineAnchor?

        /// Directory containing the source file, derived from `sourceFilePath`.
        /// e.g. "docs/readme.md" → "docs", "readme.md" → nil
        var sourceDirectory: String? {
            guard let sourceFilePath else { return nil }
            let dir = (sourceFilePath as NSString).deletingLastPathComponent
            return dir.isEmpty || dir == "." ? nil : dir
        }
        /// Surface tag for streaming markdown perf instrumentation.
        let perfSurface: MarkdownStreamingPerf.Surface?
        /// Optional full-screen reader styling. Inline/timeline markdown leaves
        /// this nil so chat rendering keeps its compact default metrics.
        let readerPreferences: FullScreenReaderPreferences?
        /// Controls whether async work (mermaid rendering, syntax highlighting,
        /// image loading) runs on background threads or the current thread.
        ///
        /// - `.live`: async rendering for scroll performance (default)
        /// - `.export`: synchronous rendering so snapshots capture all content
        let renderingMode: ContentRenderingMode

        private init(
            content: String,
            isStreaming: Bool,
            themeID: ThemeID,
            textSelectionEnabled: Bool = true,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
            reviewCommentSourceContext: ReviewCommentSourceContext? = nil,
            serverID: String? = nil,
            workspaceID: String? = nil,
            sessionID: String? = nil,
            serverBaseURL: URL? = nil,
            sourceFilePath: String? = nil,
            lineAnchor: SourceLineAnchor? = nil,
            readerPreferences: FullScreenReaderPreferences? = nil,
            perfSurface: MarkdownStreamingPerf.Surface? = nil,
            renderingMode: ContentRenderingMode = .live
        ) {
            self.content = content
            self.isStreaming = isStreaming
            self.themeID = themeID
            self.textSelectionEnabled = textSelectionEnabled
            self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
            self.reviewCommentSourceContext = reviewCommentSourceContext
            self.serverID = serverID
            self.workspaceID = workspaceID
            self.sessionID = sessionID
            self.serverBaseURL = serverBaseURL
            self.sourceFilePath = sourceFilePath
            self.lineAnchor = lineAnchor
            self.readerPreferences = readerPreferences
            self.perfSurface = perfSurface
            self.renderingMode = renderingMode
        }

        static func make(
            content: String,
            isStreaming: Bool,
            themeID: ThemeID,
            textSelectionEnabled: Bool = true,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
            reviewCommentSourceContext: ReviewCommentSourceContext? = nil,
            serverID: String? = nil,
            workspaceID: String? = nil,
            sessionID: String? = nil,
            serverBaseURL: URL? = nil,
            sourceFilePath: String? = nil,
            lineAnchor: SourceLineAnchor? = nil,
            readerPreferences: FullScreenReaderPreferences? = nil,
            perfSurface: MarkdownStreamingPerf.Surface? = nil,
            renderingMode: ContentRenderingMode = .live
        ) -> Self {
            Self(
                content: content,
                isStreaming: isStreaming,
                themeID: themeID,
                textSelectionEnabled: textSelectionEnabled,
                reviewCommentSelectionRouter: reviewCommentSelectionRouter,
                reviewCommentSourceContext: reviewCommentSourceContext,
                serverID: serverID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                serverBaseURL: serverBaseURL,
                sourceFilePath: sourceFilePath,
                lineAnchor: lineAnchor,
                readerPreferences: readerPreferences,
                perfSurface: perfSurface,
                renderingMode: renderingMode
            )
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.content == rhs.content
                && lhs.isStreaming == rhs.isStreaming
                && lhs.themeID == rhs.themeID
                && lhs.textSelectionEnabled == rhs.textSelectionEnabled
                && lhs.reviewCommentSelectionRouter === rhs.reviewCommentSelectionRouter
                && lhs.reviewCommentSourceContext == rhs.reviewCommentSourceContext
                && lhs.serverID == rhs.serverID
                && lhs.workspaceID == rhs.workspaceID
                && lhs.sessionID == rhs.sessionID
                && lhs.serverBaseURL == rhs.serverBaseURL
                && lhs.sourceFilePath == rhs.sourceFilePath
                && lhs.lineAnchor == rhs.lineAnchor
                && lhs.readerPreferences == rhs.readerPreferences
                && lhs.perfSurface == rhs.perfSurface
                && lhs.renderingMode == rhs.renderingMode
        }
    }

    private let stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    private let segmentSource = AssistantMarkdownSegmentSource()
    private lazy var segmentApplier = AssistantMarkdownSegmentApplier(
        stackView: stackView,
        textViewDelegate: self
    )

    private var currentConfig: Configuration?

    /// Width at which Auto Layout last captured `intrinsicContentSize`.
    /// The intrinsic height is width-dependent (320pt fallback while bounds is
    /// zero), and the AL engine caches it until invalidated. Without width-
    /// change invalidation, the first self-sizing pass (bounds.width == 0)
    /// freezes the 320pt measurement and long markdown keeps a blank tail once
    /// the real width arrives.
    private var intrinsicCapturedWidth: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(intrinsicCapturedWidth - bounds.width) > 0.5 else { return }
        intrinsicCapturedWidth = bounds.width
        invalidateIntrinsicContentSize()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    /// Leading hang used by assistant timeline rows: first text lines clear the
    /// avatar, then content uses the full markdown width under that column.
    /// Zero means no hang (full-screen readers, exports, non-chat surfaces).
    var leadingHangClearance: CGFloat = 0 {
        didSet {
            guard oldValue != leadingHangClearance else { return }
            segmentApplier.applyLeadingHang(
                clearance: leadingHangClearance,
                height: leadingHangHeight
            )
        }
    }

    var leadingHangHeight: CGFloat = 0 {
        didSet {
            guard oldValue != leadingHangHeight else { return }
            segmentApplier.applyLeadingHang(
                clearance: leadingHangClearance,
                height: leadingHangHeight
            )
        }
    }

    /// Closure for fetching workspace files (for inline markdown images).
    /// Wraps `APIClient.fetchWorkspaceFile` at the injection site, keeping this
    /// view file decoupled from `APIClient` directly.
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? {
        didSet { segmentApplier.fetchWorkspaceFile = fetchWorkspaceFile }
    }

    /// Optional session-file fetcher retained for internal session-file URLs.
    var fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? {
        didSet { segmentApplier.fetchSessionFile = fetchSessionFile }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        stackView.setContentHuggingPriority(.required, for: .vertical)
        stackView.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    /// Remove all rendered content and reset internal state.
    func clearContent() {
        segmentSource.reset()
        segmentApplier.clear()
        currentConfig = nil
        stackView.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func apply(configuration config: Configuration) {
        guard config != currentConfig else { return }
        currentConfig = config
        stackView.spacing = config.readerPreferences?.spacing.markdownStackSpacing ?? 8

        let cycleStart = MarkdownStreamingPerf.timestampNs()
        let shouldResolveFileLines = !config.isStreaming && config.reviewCommentSourceContext?.filePath != nil
        let build: FlatSegment.BuildResult
        if shouldResolveFileLines {
            build = segmentSource.buildSegmentsWithSourceLineRanges(config)
        } else {
            build = FlatSegment.BuildResult(
                segments: segmentSource.buildSegments(config),
                sourceLineRanges: []
            )
        }
        segmentApplier.apply(
            segments: build.segments,
            config: config,
            sourceLineRanges: build.sourceLineRanges
        )
        segmentApplier.applyLeadingHang(
            clearance: leadingHangClearance,
            height: leadingHangHeight
        )

        stackView.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()

        if let surface = config.perfSurface {
            let elapsed = MarkdownStreamingPerf.timestampNs() - cycleStart
            MarkdownStreamingPerf.recordFullCycle(
                totalNs: elapsed,
                segmentCount: build.segments.count,
                isStreaming: config.isStreaming,
                surface: surface
            )
        }
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : 320
        let size = stackView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: max(1, size.height))
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width.isFinite && targetSize.width > 0
            ? targetSize.width
            : max(1, bounds.width)
        let size = stackView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: verticalFittingPriority
        )
        return CGSize(width: width, height: max(1, size.height))
    }
}

// MARK: - Link Classification

struct FileLinkPayload: Equatable {
    let workspaceID: String
    let filePath: String
    let originalURL: URL
}

enum LinkAction: Equatable {
    case deepLink(URL)
    case inAppSessionLink(InAppDeepLinkIntent)
    case webLink(URL)
    case resourceReference(ResourceReference)
    case fileLink(FileLinkPayload)
    case systemDefault
}

@MainActor
enum MarkdownLinkInteractionSupport {
    static func classify(
        _ url: URL,
        serverID: String? = nil,
        workspaceID: String?
    ) -> LinkAction {
        let normalizedURL = AssistantMarkdownContentView.normalizedInteractionURL(url)
        guard let scheme = normalizedURL.scheme?.lowercased() else {
            return .systemDefault
        }
        if scheme == "oppi" {
            if InAppSessionLink.parse(normalizedURL) != nil {
                return .inAppSessionLink(InAppDeepLinkIntent(
                    url: normalizedURL,
                    sourceServerID: serverID
                ))
            }
            return .deepLink(normalizedURL)
        }
        if scheme == "http" || scheme == "https" {
            return .webLink(normalizedURL)
        }
        if scheme == ResourceReferenceURL.scheme,
           let reference = ResourceReferenceURL.parse(normalizedURL),
           reference.workspaceID == workspaceID,
           reference.sourceServerID == nil || reference.sourceServerID == serverID {
            return .resourceReference(reference)
        }
        if scheme == "file",
           normalizedURL.isFileURL,
           let workspaceID,
           !workspaceID.isEmpty {
            let filePath = normalizedURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filePath.isEmpty else { return .systemDefault }
            return .fileLink(FileLinkPayload(
                workspaceID: workspaceID,
                filePath: filePath,
                originalURL: normalizedURL
            ))
        }
        return .systemDefault
    }

    static func primaryAction(for action: LinkAction, defaultAction: UIAction) -> UIAction? {
        switch action {
        case .deepLink(let normalizedURL):
            return UIAction { _ in
                NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: normalizedURL)
            }
        case .inAppSessionLink(let intent):
            return UIAction { _ in
                let post = { @MainActor in
                    NotificationCenter.default.post(
                        name: .inAppDeepLinkTapped,
                        object: intent.url,
                        userInfo: intent.sourceServerID.map {
                            [Notification.Name.inAppDeepLinkSourceServerIDKey: $0]
                        }
                    )
                }
                if Thread.isMainThread {
                    post()
                } else {
                    DispatchQueue.main.async(execute: post)
                }
            }
        case .webLink(let normalizedURL):
            return UIAction { _ in
                NotificationCenter.default.post(name: .webLinkTapped, object: normalizedURL)
            }
        case .resourceReference(let reference):
            return UIAction { _ in
                NotificationCenter.default.post(name: .resourceReferenceTapped, object: reference)
            }
        case .fileLink(let payload):
            return UIAction { _ in
                NotificationCenter.default.post(name: .fileLinkTapped, object: payload)
            }
        case .systemDefault:
            return defaultAction
        }
    }

    static func menuConfiguration(
        for action: LinkAction,
        defaultMenu: UIMenu,
        textView: UITextView,
        shareWebLink: @escaping (_ url: URL, _ sourceView: UITextView?) -> Void
    ) -> UITextItem.MenuConfiguration? {
        guard case .webLink(let normalizedURL) = action else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        let copyAction = UIAction(
            title: "Copy Link",
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in
            UIPasteboard.general.string = normalizedURL.absoluteString
        }

        let openAction = UIAction(
            title: AppPreferences.Browser.linkOpeningMode.openActionTitle,
            image: UIImage(systemName: "safari")
        ) { _ in
            NotificationCenter.default.post(name: .webLinkTapped, object: normalizedURL)
        }

        let shareAction = UIAction(
            title: "Share...",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak textView] _ in
            shareWebLink(normalizedURL, textView)
        }

        return UITextItem.MenuConfiguration(
            menu: UIMenu(children: [openAction, copyAction, shareAction])
        )
    }
}

// MARK: - UITextViewDelegate (deep link routing)

extension AssistantMarkdownContentView: UITextViewDelegate {
    /// Classify a URL for tap/long-press behavior. Exposed for testing.
    func classifyLink(_ url: URL) -> LinkAction {
        MarkdownLinkInteractionSupport.classify(
            url,
            serverID: currentConfig?.serverID,
            workspaceID: currentConfig?.workspaceID
        )
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let config = currentConfig else { return nil }

        return ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: config.reviewCommentSelectionRouter,
            sourceContext: config.reviewCommentSourceContext
        )
    }

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content else {
            return defaultAction
        }

        return MarkdownLinkInteractionSupport.primaryAction(
            for: classifyLink(url),
            defaultAction: defaultAction
        )
    }

    func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        guard case let .link(url) = textItem.content else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        return MarkdownLinkInteractionSupport.menuConfiguration(
            for: classifyLink(url),
            defaultMenu: defaultMenu,
            textView: textView
        ) { normalizedURL, sourceView in
            // This shares a URL from a text interaction menu, not file content.
            guard let sourceView else { return }
            let activityVC = UIActivityViewController(
                activityItems: [normalizedURL],
                applicationActivities: nil
            )
            activityVC.popoverPresentationController?.sourceView = sourceView
            sourceView.window?.rootViewController?
                .presentedViewController?.present(activityVC, animated: true)
                ?? sourceView.window?.rootViewController?.present(activityVC, animated: true)
        }
    }

    private static let trailingLinkDelimiters: Set<Character> = ["`", "'", "\"", "\u{2018}", "\u{201C}"]
    private static let trailingEncodedLinkDelimiters = ["%60", "%27", "%22"]

    static func normalizedInteractionURL(_ url: URL) -> URL {
        let normalized = normalizedURLString(url.absoluteString)
        return URL(string: normalized) ?? url
    }

    private static func normalizedURLString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        while !value.isEmpty {
            if let suffix = trailingEncodedLinkDelimiters.first(where: { value.lowercased().hasSuffix($0) }) {
                value = String(value.dropLast(suffix.count))
                continue
            }
            guard let last = value.last, trailingLinkDelimiters.contains(last) else { break }
            value.removeLast()
        }

        return value
    }
}

#if DEBUG
extension AssistantMarkdownContentView {
    var debugMaxRenderedSegmentOverlapPoints: CGFloat {
        let frames = stackView.arrangedSubviews
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .map { $0.convert($0.bounds, to: self) }
            .sorted { $0.minY < $1.minY }

        guard frames.count >= 2 else { return 0 }

        var maxOverlap: CGFloat = 0
        for index in 0..<(frames.count - 1) {
            maxOverlap = max(maxOverlap, frames[index].maxY - frames[index + 1].minY)
        }

        return max(0, maxOverlap)
    }

    var debugRenderedContentOverflowPoints: CGFloat {
        let maxRenderedY = stackView.arrangedSubviews
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .map { $0.convert($0.bounds, to: self).maxY }
            .max() ?? 0

        return max(0, maxRenderedY - bounds.maxY)
    }
}
#endif
