import SwiftUI
import UIKit

// MARK: - RenderableDocumentView

/// All-UIKit chrome for renderable document types (markdown, LaTeX, mermaid, org, HTML).
///
/// Owns the header bar, source/rendered toggle, expand button, copy button,
/// context menu, code block chrome, and floating capsule. The rendered content
/// is provided as a UIView by the caller.
///
/// Two modes controlled by ``FileContentPresentation``:
/// - **Inline**: header bar + content area + max height + rounded corners + context menu
/// - **Document**: full-height content + floating source toggle capsule
///
/// This replaces the duplicated inline/document body code that was copy-pasted
/// across MarkdownFileView, LaTeXFileView, MermaidFileView, OrgModeFileView,
/// and HTMLFileView.
@MainActor
final class RenderableDocumentView: UIView {

    // MARK: - Configuration

    /// Per-content-type metadata. Fully describes the chrome — no subclassing needed.
    struct Config {
        let iconName: String
        let iconColor: @MainActor (ThemePalette) -> UIColor
        let label: String
        let sourceToggleLabels: (rendered: String, source: String)
        let sourceToggleIcon: String
        let sourceLanguage: String?

        // MARK: - Built-in Configs

        static let markdown = Config(
            iconName: "doc.richtext",
            iconColor: { UIColor($0.cyan) },
            label: "Markdown",
            sourceToggleLabels: (rendered: "Reader", source: "Source"),
            sourceToggleIcon: "doc.richtext",
            sourceLanguage: "markdown"
        )

        static let latex = Config(
            iconName: "function",
            iconColor: { UIColor($0.green) },
            label: "LaTeX",
            sourceToggleLabels: (rendered: "Rendered", source: "Source"),
            sourceToggleIcon: "function",
            sourceLanguage: SyntaxLanguage.latex.displayName
        )

        static let mermaid = Config(
            iconName: "chart.dots.scatter",
            iconColor: { UIColor($0.purple) },
            label: "Mermaid",
            sourceToggleLabels: (rendered: "Rendered", source: "Source"),
            sourceToggleIcon: "chart.dots.scatter",
            sourceLanguage: SyntaxLanguage.mermaid.displayName
        )

        static let orgMode = Config(
            iconName: "doc.richtext",
            iconColor: { UIColor($0.cyan) },
            label: "Org Mode",
            sourceToggleLabels: (rendered: "Reader", source: "Source"),
            sourceToggleIcon: "doc.richtext",
            sourceLanguage: SyntaxLanguage.orgMode.displayName
        )

        static let html = Config(
            iconName: "globe",
            iconColor: { UIColor($0.cyan) },
            label: "HTML",
            sourceToggleLabels: (rendered: "Preview", source: "Source"),
            sourceToggleIcon: "globe",
            sourceLanguage: "html"
        )
    }

    // MARK: - Properties

    private let config: Config
    private let content: String
    private let filePath: String?
    private let isInline: Bool
    private let maxContentHeight: CGFloat?
    private let showExpand: Bool
    private let reviewCommentSelectionContext: ReviewCommentSelectionContext?
    private var palette: ThemePalette
    private var showingSource = false
    private var renderIdentity: AnyHashable?

    // Views
    private var renderedContentView: UIView
    private var sourceView: NativeFullScreenCodeBody?
    private let contentContainer = UIView()

    // Header (inline mode)
    private var headerContainer: UIView?

    // Floating capsule (document mode)
    private var floatingCapsule: UIButton?

    // Copy state
    private var copyButton: UIButton?
    private var copyResetTask: Task<Void, Never>?

    // Callbacks
    var onExpandFullScreen: (() -> Void)?

    // MARK: - Init

    init(
        config: Config,
        content: String,
        filePath: String?,
        presentation: FileContentPresentation,
        renderedContentView: UIView,
        allowsFullScreenExpansion: Bool,
        reviewCommentSelectionContext: ReviewCommentSelectionContext?,
        renderIdentity: AnyHashable? = nil,
        renderPalette: ThemePalette? = nil
    ) {
        self.config = config
        self.content = content
        self.filePath = filePath
        self.isInline = presentation.usesInlineChrome
        self.maxContentHeight = presentation.viewportMaxHeight
        self.showExpand = presentation.allowsExpansionAffordance && allowsFullScreenExpansion
        self.renderedContentView = renderedContentView
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
        self.renderIdentity = renderIdentity
        self.palette = renderPalette ?? ThemeRuntimeState.currentPalette()

        super.init(frame: .zero)

        let palette = self.palette

        if isInline {
            setupInlineMode(palette: palette)
        } else {
            setupDocumentMode(palette: palette)
        }

        if isInline {
            addContextMenuInteraction(palette: palette)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Inline Mode

    private func setupInlineMode(palette: ThemePalette) {
        let outerStack = UIStackView()
        outerStack.axis = .vertical
        outerStack.spacing = 0
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Header
        let header = makeHeaderBar(palette: palette)
        outerStack.addArrangedSubview(header)
        headerContainer = header

        // Content container
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(contentContainer)
        if let maxHeight = maxContentHeight {
            contentContainer.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight).isActive = true
        }

        // Start with rendered view
        installContentView(renderedContentView)

        // Chrome
        backgroundColor = UIColor(palette.bgDark)
        layer.cornerRadius = 8
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.35).cgColor
    }

    // MARK: - Document Mode

    private func setupDocumentMode(palette: ThemePalette) {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        installContentView(renderedContentView)

        // Floating capsule toggle
        let capsule = makeFloatingCapsule(palette: palette)
        addSubview(capsule)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
        floatingCapsule = capsule
    }

    // MARK: - Content Swap

    /// Refresh theme-sensitive content while preserving the mounted graphical
    /// view (and therefore zoom/pan) whenever its renderer supports updates.
    func updateRenderedContentIfNeeded(
        identity: AnyHashable?,
        palette: ThemePalette?,
        updateView: (@MainActor (UIView) -> Bool)?,
        makeView: @MainActor () -> UIView
    ) {
        guard renderIdentity != identity else { return }
        renderIdentity = identity

        if let palette {
            applyTheme(palette)
        }

        if updateView?(renderedContentView) != true {
            renderedContentView = makeView()
            if !showingSource {
                installContentView(renderedContentView)
            }
        }
    }

    private func applyTheme(_ palette: ThemePalette) {
        self.palette = palette

        if isInline {
            backgroundColor = UIColor(palette.bgDark)
            layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.35).cgColor
        }

        headerContainer?.backgroundColor = UIColor(palette.bgHighlight)
        for view in headerContainer?.subviewsRecursive ?? [] {
            switch view.tag {
            case ViewTag.icon:
                (view as? UIImageView)?.tintColor = config.iconColor(palette)
            case ViewTag.label:
                (view as? UILabel)?.textColor = UIColor(palette.fgDim)
            case ViewTag.lineCount:
                (view as? UILabel)?.textColor = UIColor(palette.comment)
            case ViewTag.sourceToggle:
                (view as? UIButton)?.setTitleColor(UIColor(palette.blue), for: .normal)
            case ViewTag.expand:
                (view as? UIButton)?.tintColor = UIColor(palette.fgDim)
            default:
                break
            }
        }

        if let copyButton {
            var copyConfig = copyButton.configuration ?? .plain()
            copyConfig.baseForegroundColor = UIColor(palette.fgDim)
            copyButton.configuration = copyConfig
        }

        if let floatingCapsule {
            var capsuleConfig = floatingCapsule.configuration ?? .glass()
            FullScreenFloatingControlChrome.applyGlassBackground(to: &capsuleConfig, palette: palette)
            floatingCapsule.configuration = capsuleConfig
            updateToggleLabels()
        }

        if let sourceView {
            let sourceState = SourceViewState(sourceView)
            let refreshedSource = makeSourceView(palette: palette)
            self.sourceView = refreshedSource
            if showingSource {
                installContentView(refreshedSource)
                contentContainer.layoutIfNeeded()
            }
            sourceState.restore(to: refreshedSource)
        }
    }

    private func installContentView(_ view: UIView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func toggleSource() {
        showingSource.toggle()

        if showingSource {
            if sourceView == nil {
                sourceView = makeSourceView(palette: palette)
            }
            if let sv = sourceView {
                UIView.transition(with: contentContainer, duration: 0.15, options: .transitionCrossDissolve) {
                    self.installContentView(sv)
                }
            }
        } else {
            UIView.transition(with: contentContainer, duration: 0.15, options: .transitionCrossDissolve) {
                self.installContentView(self.renderedContentView)
            }
        }

        updateToggleLabels()
    }

    private func makeSourceView(palette: ThemePalette) -> NativeFullScreenCodeBody {
        NativeFullScreenCodeBody(
            content: content,
            language: config.sourceLanguage,
            startLine: 1,
            palette: palette,
            alwaysBounceVertical: !isInline,
            reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
            reviewCommentSourceContext: reviewCommentSelectionContext?.sourceContext(
                surface: .fullScreenSource,
                sourceLabel: reviewCommentSelectionContext?.sourceLabel ?? config.label,
                filePath: filePath,
                languageHint: config.sourceLanguage
            )
        )
    }

    private func updateToggleLabels() {
        let labels = showingSource ? config.sourceToggleLabels.rendered : config.sourceToggleLabels.source

        // Inline toggle button
        if let header = headerContainer {
            for case let button as UIButton in header.subviewsRecursive where button.tag == ViewTag.sourceToggle {
                button.setTitle(labels, for: .normal)
            }
        }

        // Floating capsule
        if let capsule = floatingCapsule {
            var capsuleConfig = capsule.configuration ?? .plain()
            capsuleConfig.title = labels
            let iconName = showingSource ? config.sourceToggleIcon : "curlybraces"
            capsuleConfig.image = UIImage(systemName: iconName)
            capsule.configuration = capsuleConfig
        }
    }

    // MARK: - Header Bar (Inline)

    private func makeHeaderBar(palette: ThemePalette) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(palette.bgHighlight)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])

        // Icon
        let icon = UIImageView(image: UIImage(systemName: config.iconName))
        icon.tintColor = config.iconColor(palette)
        icon.tag = ViewTag.icon
        icon.preferredSymbolConfiguration = .init(textStyle: .caption1)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(icon)

        // Label
        let label = UILabel()
        label.text = config.label
        label.font = .preferredFont(forTextStyle: .caption2).bold()
        label.textColor = UIColor(palette.fgDim)
        label.tag = ViewTag.label
        label.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(label)

        // Line count
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let lineLabel = UILabel()
        lineLabel.text = "\(lineCount) lines"
        lineLabel.font = .preferredFont(forTextStyle: .caption2)
        lineLabel.textColor = UIColor(palette.comment)
        lineLabel.tag = ViewTag.lineCount
        lineLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(lineLabel)

        // Spacer
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        // Source toggle
        let toggle = UIButton(type: .system)
        toggle.setTitle(config.sourceToggleLabels.source, for: .normal)
        toggle.titleLabel?.font = .preferredFont(forTextStyle: .caption2)
        toggle.setTitleColor(UIColor(palette.blue), for: .normal)
        toggle.tag = ViewTag.sourceToggle
        toggle.addAction(UIAction { [weak self] _ in self?.toggleSource() }, for: .touchUpInside)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(toggle)

        // Expand button (conditional)
        if showExpand {
            let expand = UIButton(type: .system)
            let expandConfig = UIImage.SymbolConfiguration(textStyle: .caption2)
            expand.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: expandConfig), for: .normal)
            expand.tintColor = UIColor(palette.fgDim)
            expand.tag = ViewTag.expand
            expand.addAction(UIAction { [weak self] _ in self?.onExpandFullScreen?() }, for: .touchUpInside)
            expand.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(expand)
        }

        // Copy button
        let copy = makeCopyButton(palette: palette)
        stack.addArrangedSubview(copy)
        copyButton = copy

        return container
    }

    // MARK: - Floating Capsule (Document)

    private func makeFloatingCapsule(palette: ThemePalette) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.title = self.config.sourceToggleLabels.source
        config.image = UIImage(systemName: "curlybraces")
        config.imagePadding = 4
        config.preferredSymbolConfigurationForImage = .init(textStyle: .caption2)
        config.titleTextAttributesTransformer = .init { attrs in
            var attrs = attrs
            attrs.font = UIFont.preferredFont(forTextStyle: .caption2).bold()
            return attrs
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        FullScreenFloatingControlChrome.applyGlassBackground(to: &config, palette: palette)

        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.toggleSource() }, for: .touchUpInside)
        return button
    }

    // MARK: - Copy Button

    private func makeCopyButton(palette: ThemePalette) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = "Copy"
        config.image = UIImage(systemName: "doc.on.doc")
        config.imagePadding = 2
        config.preferredSymbolConfigurationForImage = .init(textStyle: .caption2)
        config.titleTextAttributesTransformer = .init { attrs in
            var attrs = attrs
            attrs.font = UIFont.preferredFont(forTextStyle: .caption2)
            return attrs
        }
        config.contentInsets = .zero
        config.baseForegroundColor = UIColor(palette.fgDim)

        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.copyTapped() }, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func copyTapped() {
        UIPasteboard.general.string = content
        copyResetTask?.cancel()

        guard let button = copyButton else { return }
        var config = button.configuration ?? .plain()
        config.title = "Copied"
        config.image = UIImage(systemName: "checkmark")
        button.configuration = config

        copyResetTask = Task { @MainActor [weak self, weak button] in
            try? await Task.sleep(for: .seconds(2))
            guard let button else { return }
            var config = button.configuration ?? .plain()
            config.title = "Copy"
            config.image = UIImage(systemName: "doc.on.doc")
            button.configuration = config
            self?.copyResetTask = nil
        }
    }

    // MARK: - Context Menu (Inline)

    private func addContextMenuInteraction(palette: ThemePalette) {
        let interaction = UIContextMenuInteraction(delegate: self)
        addInteraction(interaction)
    }

    // MARK: - Tags

    private enum ViewTag {
        static let sourceToggle = 1001
        static let icon = 1002
        static let label = 1003
        static let lineCount = 1004
        static let expand = 1005
    }

    private struct SourceViewState {
        let contentOffsets: [CGPoint]
        let selections: [NSRange]

        init(_ view: UIView) {
            let descendants = view.subviewsRecursive
            contentOffsets = descendants.compactMap { ($0 as? UIScrollView)?.contentOffset }
            selections = descendants.compactMap { ($0 as? UITextView)?.selectedRange }
        }

        func restore(to view: UIView) {
            let descendants = view.subviewsRecursive
            for (scrollView, offset) in zip(
                descendants.compactMap({ $0 as? UIScrollView }),
                contentOffsets
            ) {
                scrollView.setContentOffset(offset, animated: false)
            }
            for (textView, selection) in zip(
                descendants.compactMap({ $0 as? UITextView }),
                selections
            ) {
                textView.selectedRange = selection
            }
        }
    }
}

// MARK: - UIContextMenuInteractionDelegate

extension RenderableDocumentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return UIMenu(children: []) }
            var actions: [UIAction] = []

            if showExpand {
                actions.append(UIAction(
                    title: "Open Full Screen",
                    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                ) { [weak self] _ in
                    self?.onExpandFullScreen?()
                })
            }

            actions.append(UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = content
            })

            return UIMenu(children: actions)
        })
    }
}

// MARK: - Helpers

#if DEBUG
extension RenderableDocumentView {
    var debugRenderedContentViewForTesting: UIView { renderedContentView }
    var debugIsShowingSourceForTesting: Bool { showingSource }
    var debugContentForTesting: String { content }
    var debugSourceBackgroundColorForTesting: UIColor? { sourceView?.backgroundColor }
    var debugSourceTextForTesting: String? {
        sourceView?.subviewsRecursive.compactMap { ($0 as? UITextView)?.text }.first
    }
    var debugSourceSelectionForTesting: NSRange? {
        sourceView?.subviewsRecursive.compactMap { ($0 as? UITextView)?.selectedRange }.first
    }

    func debugSetSourceSelectionForTesting(_ selection: NSRange) {
        sourceView?.subviewsRecursive.compactMap { $0 as? UITextView }.first?.selectedRange = selection
    }

    func debugToggleSourceForTesting() {
        toggleSource()
    }
}
#endif

private extension UIView {
    var subviewsRecursive: [UIView] {
        subviews + subviews.flatMap(\.subviewsRecursive)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
