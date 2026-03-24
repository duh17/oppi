import UIKit

// MARK: - Native Markdown Content View

/// Native UIKit markdown renderer for assistant messages.
///
/// `AssistantMarkdownContentView` is now a thin coordinator over three layers:
/// - `AssistantMarkdownSegmentSource` builds `FlatSegment` arrays from markdown.
/// - `AssistantMarkdownSegmentApplier` maps those segments onto reusable UIKit views.
/// - `NativeCodeBlockView` / `NativeTableBlockView` render block-level surfaces.
final class AssistantMarkdownContentView: UIView {
    struct Configuration: Equatable {
        /// Default inline fallback. Pass `nil` for dedicated reader/document surfaces.
        static let defaultPlainTextFallbackThreshold = 20_000

        let content: String
        let isStreaming: Bool
        let themeID: ThemeID
        let textSelectionEnabled: Bool
        let plainTextFallbackThreshold: Int?
        let selectedTextPiRouter: SelectedTextPiActionRouter?
        let selectedTextSourceContext: SelectedTextSourceContext?
        /// Workspace context for resolving inline image paths.
        let workspaceID: String?
        let serverBaseURL: URL?

        init(
            content: String,
            isStreaming: Bool,
            themeID: ThemeID,
            textSelectionEnabled: Bool = true,
            plainTextFallbackThreshold: Int? = Self.defaultPlainTextFallbackThreshold,
            selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
            selectedTextSourceContext: SelectedTextSourceContext? = nil,
            workspaceID: String? = nil,
            serverBaseURL: URL? = nil
        ) {
            self.content = content
            self.isStreaming = isStreaming
            self.themeID = themeID
            self.textSelectionEnabled = textSelectionEnabled
            self.plainTextFallbackThreshold = plainTextFallbackThreshold
            self.selectedTextPiRouter = selectedTextPiRouter
            self.selectedTextSourceContext = selectedTextSourceContext
            self.workspaceID = workspaceID
            self.serverBaseURL = serverBaseURL
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.content == rhs.content
                && lhs.isStreaming == rhs.isStreaming
                && lhs.themeID == rhs.themeID
                && lhs.textSelectionEnabled == rhs.textSelectionEnabled
                && lhs.plainTextFallbackThreshold == rhs.plainTextFallbackThreshold
                && lhs.selectedTextPiRouter === rhs.selectedTextPiRouter
                && lhs.selectedTextSourceContext == rhs.selectedTextSourceContext
                && lhs.workspaceID == rhs.workspaceID
                && lhs.serverBaseURL == rhs.serverBaseURL
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

    /// Closure for fetching workspace files (for inline markdown images).
    /// Wraps `APIClient.fetchWorkspaceFile` at the injection site, keeping this
    /// view file decoupled from `APIClient` directly.
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? {
        didSet { segmentApplier.fetchWorkspaceFile = fetchWorkspaceFile }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Remove all rendered content and reset internal state.
    func clearContent() {
        segmentSource.reset()
        segmentApplier.clear()
        currentConfig = nil
    }

    func apply(configuration config: Configuration) {
        guard config != currentConfig else { return }
        currentConfig = config

        let segments = segmentSource.buildSegments(config)
        segmentApplier.apply(segments: segments, config: config)
    }
}

// MARK: - Link Classification

enum LinkAction: Equatable {
    case deepLink(URL)
    case webLink(URL)
    case systemDefault
}

// MARK: - UITextViewDelegate (deep link routing)

extension AssistantMarkdownContentView: UITextViewDelegate {
    /// Classify a URL for tap/long-press behavior. Exposed for testing.
    func classifyLink(_ url: URL) -> LinkAction {
        let normalizedURL = Self.normalizedInteractionURL(url)
        guard let scheme = normalizedURL.scheme?.lowercased() else {
            return .systemDefault
        }
        if scheme == "pi" || scheme == "oppi" {
            return .deepLink(normalizedURL)
        }
        if scheme == "http" || scheme == "https" {
            return .webLink(normalizedURL)
        }
        return .systemDefault
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let config = currentConfig else { return nil }

        return SelectedTextPiEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: config.selectedTextPiRouter,
            sourceContext: config.selectedTextSourceContext
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

        switch classifyLink(url) {
        case .deepLink(let normalizedURL):
            return UIAction { _ in
                NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: normalizedURL)
            }
        case .webLink:
            return nil
        case .systemDefault:
            return defaultAction
        }
    }

    func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        guard case let .link(url) = textItem.content else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        guard case .webLink(let normalizedURL) = classifyLink(url) else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        let copyAction = UIAction(
            title: "Copy Link",
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in
            UIPasteboard.general.string = normalizedURL.absoluteString
        }

        let openAction = UIAction(
            title: "Open in Browser",
            image: UIImage(systemName: "safari")
        ) { _ in
            NotificationCenter.default.post(name: .webLinkTapped, object: normalizedURL)
        }

        let shareAction = UIAction(
            title: "Share...",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak textView] _ in
            guard let textView else { return }
            let activityVC = UIActivityViewController(
                activityItems: [normalizedURL],
                applicationActivities: nil
            )
            activityVC.popoverPresentationController?.sourceView = textView
            textView.window?.rootViewController?
                .presentedViewController?.present(activityVC, animated: true)
                ?? textView.window?.rootViewController?.present(activityVC, animated: true)
        }

        let menu = UIMenu(children: [openAction, copyAction, shareAction])
        return UITextItem.MenuConfiguration(menu: menu)
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
