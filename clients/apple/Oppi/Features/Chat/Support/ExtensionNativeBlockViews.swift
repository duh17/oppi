import UIKit

// MARK: - Content and context

/// What an extension surface body paints: semantic native blocks, or terminal
/// lines (a plain `setWidget(string[])` widget or a surface's fallback lines).
enum ExtensionNativeBlockContent: Equatable {
    case blocks([ExtensionUINativeBlock])
    case terminalLines([String])

    init(surface: ExtensionUINativeSurface) {
        let blocks = surface.nativeDisplayBlocks
        self = blocks.isEmpty ? .terminalLines(surface.fallbackDisplayLines) : .blocks(blocks)
    }
}

/// Rendering environment shared by every block view of one surface.
struct ExtensionNativeBlockContext {
    var themeID: ThemeID
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)?
    /// Busy sessions' live tails by session id. An activity row linking to
    /// `oppi://session/<id>` shows its session's tail under its text.
    var sessionLiveTails: [String: ConversationChildTail] = [:]
    /// The host's menu for a session an activity row links to (`url`), read when the menu
    /// opens; `rowState` is the row's protocol state. Nil, or a nil menu, offers no menu.
    var sessionMenu: (@MainActor (_ sessionId: String, _ url: URL, _ rowState: String?) -> UIMenu?)?

    var palette: ThemePalette { themeID.palette }

    /// Extension links belong to the host that mounted the surface (the chat
    /// routes them through `AppOpener`). Without a host there is no window to
    /// open into, so nothing happens.
    @MainActor
    func open(_ url: URL) {
        _ = onOpenURL?(url)
    }

    /// What a tap on `url` would do, for an accessibility hint.
    @MainActor
    func linkOutcome(for url: URL) -> ExtensionSurfaceLinkOutcome? {
        ExtensionSurfaceLinkRouting.outcome(
            for: url,
            serverID: linkContext.serverID,
            workspaceID: linkContext.workspaceID,
            currentSessionId: linkContext.sessionID ?? ""
        )
    }

    /// Inputs that change painted output. Closures are refreshed on every apply.
    fileprivate var signature: Signature {
        Signature(themeID: themeID, linkContext: linkContext)
    }

    fileprivate struct Signature: Equatable {
        let themeID: ThemeID
        let linkContext: ExtensionSurfaceLinkContext
    }
}

@MainActor
protocol ExtensionNativeBlockRendering: UIView {
    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext)
    /// The host is about to measure at, and show this block at, `width`.
    /// Blocks whose height depends on width before layout use it.
    func adoptLayoutWidth(_ width: CGFloat)
}

extension ExtensionNativeBlockRendering {
    func adoptLayoutWidth(_ width: CGFloat) {}
}

// MARK: - Fonts and colors

@MainActor
enum ExtensionNativeBlockStyle {
    /// Dynamic Type font for `style`, sized from the style's default point size.
    static func font(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        monospaced: Bool = false,
        monospacedDigits: Bool = false,
        traits: UIFontDescriptor.SymbolicTraits = []
    ) -> UIFont {
        let size = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        var font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : monospacedDigits
                ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : UIFont.systemFont(ofSize: size, weight: weight)
        if !traits.isEmpty,
           let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    static func activityColor(_ tone: ExtensionNativeBlockPresentation.ActivityTone, palette: ThemePalette) -> UIColor {
        switch tone {
        case .running: palette.ui.blue
        case .success: palette.ui.green
        case .warning: palette.ui.orange
        case .error: palette.ui.red
        case .queued: palette.ui.purple
        case .inactive, .neutral: palette.ui.comment
        }
    }

    /// The rounded, faintly filled inset that frames code-like and grouped content.
    static func applyInset(to view: UIView, palette: ThemePalette, cornerRadius: CGFloat = 12) {
        view.backgroundColor = palette.ui.fg.withAlphaComponent(0.04)
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 0.5
        view.layer.borderColor = palette.ui.fg.withAlphaComponent(0.08).cgColor
    }

    static func label(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.font = font(style, weight: weight)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
}

extension Array where Element == ExtensionUITextSpan {
    /// Semantic span roles and traits mapped onto the active theme. Links stay
    /// real URLs; color is never the only signal for a link (it is underlined).
    @MainActor
    func extensionNativeAttributedString(
        palette: ThemePalette,
        textStyle: UIFont.TextStyle = .caption1,
        monospaced: Bool = false
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in self {
            result.append(span.extensionNativeAttributedString(
                palette: palette,
                textStyle: textStyle,
                monospaced: monospaced
            ))
        }
        return result
    }
}

private extension ExtensionUITextSpan {
    @MainActor
    func extensionNativeAttributedString(
        palette: ThemePalette,
        textStyle: UIFont.TextStyle,
        monospaced: Bool
    ) -> NSAttributedString {
        let traits = Set((traits ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let role = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var symbolicTraits: UIFontDescriptor.SymbolicTraits = []
        if traits.contains("bold") { symbolicTraits.insert(.traitBold) }
        if traits.contains("italic") { symbolicTraits.insert(.traitItalic) }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: ExtensionNativeBlockStyle.font(
                textStyle,
                monospaced: monospaced || role == "code" || traits.contains("monospaced"),
                traits: symbolicTraits
            ),
            .foregroundColor: palette.ui.fg,
        ]
        if traits.contains("underline") {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if traits.contains("strikethrough") {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        let url = ExtensionNativeBlockPresentation.linkURL(link)
        if let color = Self.roleColor(role, palette: palette) {
            attributes[.foregroundColor] = color
        } else if url != nil {
            attributes[.foregroundColor] = palette.ui.cyan
        }
        if let url {
            attributes[.link] = url
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func roleColor(_ role: String?, palette: ThemePalette) -> UIColor? {
        switch role {
        case "primary": palette.ui.fg
        case "secondary": palette.ui.comment
        case "muted": palette.ui.fgDim
        case "accent": palette.ui.cyan
        case "success": palette.ui.green
        case "warning": palette.ui.orange
        case "danger": palette.ui.red
        case "code": palette.ui.yellow
        default: nil
        }
    }
}

extension UIView {
    /// Tells the enclosing block scroll host that content height changed
    /// outside an `apply` (row expansion, async rendering).
    func invalidateExtensionNativeBlockHost() {
        var view: UIView? = self
        while let current = view {
            current.setNeedsLayout()
            if let host = current as? ExtensionNativeBlockScrollView {
                host.contentDidChange()
                return
            }
            view = current.superview
        }
    }
}

// MARK: - Block stack

/// Vertical list of native block views. Views are reused per block identity
/// (kind + id + occurrence), so a replacement snapshot keeps view state such
/// as horizontal terminal scroll offsets for blocks whose ids stay stable.
final class ExtensionNativeBlockStackView: UIView {
    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var blockViews: [String: any ExtensionNativeBlockRendering] = [:]
    private var terminalLinesView: ExtensionNativeTerminalView?

    var spacing: CGFloat {
        get { stackView.spacing }
        set { stackView.spacing = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Hands `width`, the width this stack is shown at, to its blocks.
    func adoptLayoutWidth(_ width: CGFloat) {
        for case let block as any ExtensionNativeBlockRendering in stackView.arrangedSubviews {
            block.adoptLayoutWidth(width)
        }
    }

    func apply(_ content: ExtensionNativeBlockContent, context: ExtensionNativeBlockContext) {
        switch content {
        case .blocks(let blocks):
            apply(blocks: blocks, context: context)
        case .terminalLines(let lines):
            let view = terminalLinesView ?? ExtensionNativeTerminalView()
            terminalLinesView = view
            view.apply(widgetLines: lines, context: context)
            install([view])
            blockViews = [:]
        }
    }

    func apply(blocks: [ExtensionUINativeBlock], context: ExtensionNativeBlockContext) {
        var occurrences: [String: Int] = [:]
        var nextViews: [String: any ExtensionNativeBlockRendering] = [:]
        var ordered: [UIView] = []

        for block in blocks {
            let identity = "\(block.fallbackIdentity):\(block.id)"
            let occurrence = occurrences[identity, default: 0]
            occurrences[identity] = occurrence + 1
            let key = "\(identity)#\(occurrence)"
            guard let view = blockViews[key] ?? Self.makeView(for: block) else { continue }
            view.apply(block, context: context)
            nextViews[key] = view
            ordered.append(view)
        }

        blockViews = nextViews
        terminalLinesView = nil
        install(ordered)
    }

    private func install(_ ordered: [UIView]) {
        guard stackView.arrangedSubviews != ordered else { return }
        for view in stackView.arrangedSubviews where !ordered.contains(view) {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in ordered.enumerated() {
            stackView.insertArrangedSubview(view, at: index)
        }
    }

    private static func makeView(for block: ExtensionUINativeBlock) -> (any ExtensionNativeBlockRendering)? {
        switch block {
        case .text: ExtensionNativeTextBlockView()
        case .markdown: ExtensionNativeMarkdownBlockView()
        case .section: ExtensionNativeSectionBlockView()
        case .activityList: ExtensionNativeActivityListView()
        case .progress: ExtensionNativeProgressBlockView()
        case .terminal: ExtensionNativeTerminalView()
        case .code: NativeCodeBlockView()
        case .divider: ExtensionNativeDividerView()
        case .spacer: ExtensionNativeSpacerView()
        case .table: ExtensionNativeTableBlockView()
        case .chart: ExtensionNativeChartBlockView()
        case .unsupported: nil
        }
    }
}

// MARK: - Text

/// Read-only, selectable rich text whose links route through the surface host.
final class ExtensionNativeLinkTextView: UITextView, UITextViewDelegate {
    var openURL: ((URL) -> Void)?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        // Span attributes own link styling.
        linkTextAttributes = [:]
        delegate = self
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
        return UIAction { _ in openURL(url) }
    }
}

final class ExtensionNativeTextBlockView: UIView, ExtensionNativeBlockRendering {
    private let textView = ExtensionNativeLinkTextView()
    private var applied: (block: ExtensionUINativeBlock, signature: ExtensionNativeBlockContext.Signature)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        textView.openURL = { context.open($0) }
        guard case .text(let base, let spans) = block,
              applied?.block != block || applied?.signature != context.signature else { return }
        applied = (block, context.signature)
        textView.attributedText = spans.extensionNativeAttributedString(palette: context.palette)
        textView.accessibilityLabel = base.accessibility?.label
        textView.accessibilityHint = base.accessibility?.hint
    }
}

// MARK: - Markdown

/// Extension Markdown uses the chat's UIKit Markdown renderer at reader-compact size.
final class ExtensionNativeMarkdownBlockView: UIView, ExtensionNativeBlockRendering {
    private static let preferences = FullScreenReaderPreferences(
        textScale: FullScreenReaderPreferences.minimumTextScale,
        spacing: .compact
    )

    private let markdownView = AssistantMarkdownContentView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(markdownView)
        NSLayoutConstraint.activate([
            markdownView.topAnchor.constraint(equalTo: topAnchor),
            markdownView.leadingAnchor.constraint(equalTo: leadingAnchor),
            markdownView.trailingAnchor.constraint(equalTo: trailingAnchor),
            markdownView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .markdown(_, let markdown) = block else { return }
        markdownView.linkOpenHandler = context.onOpenURL
        // The content view skips identical configurations itself.
        markdownView.apply(configuration: .make(
            content: markdown,
            isStreaming: false,
            themeID: context.themeID,
            resourceAccess: context.linkContext.markdownResourceAccess,
            readerPreferences: Self.preferences,
            renderingMode: .staticReader
        ))
        invalidateIntrinsicContentSize()
    }

    func adoptLayoutWidth(_ width: CGFloat) {
        markdownView.hostLayoutWidth = width
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        markdownView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }
}

// MARK: - Code

/// Code blocks reuse the chat's highlighted, copyable, wrap-toggling code view.
extension NativeCodeBlockView: ExtensionNativeBlockRendering {
    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .code(_, let language, let text) = block else { return }
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(
            language: trimmedLanguage?.isEmpty == false ? trimmedLanguage : nil,
            code: text,
            palette: context.palette,
            isOpen: false,
            themeID: context.themeID,
            highlightScheduling: .asynchronous
        )
    }
}

// MARK: - Terminal

/// Monospaced lines that keep terminal alignment and scroll horizontally
/// instead of wrapping. Paints `terminal` span blocks, raw terminal `text`
/// (resolved by the same VT engine as bash output), and plain widget lines.
final class ExtensionNativeTerminalView: UIView, ExtensionNativeBlockRendering {
    private static let padding = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)

    private let scrollView = UIScrollView()
    private let textView = ExtensionNativeLinkTextView()
    private lazy var textWidth = textView.widthAnchor.constraint(equalToConstant: 1)
    private lazy var textHeight = textView.heightAnchor.constraint(equalToConstant: 1)
    private var appliedBlock: (block: ExtensionUINativeBlock, signature: ExtensionNativeBlockContext.Signature)?
    private var appliedLines: (lines: [String], signature: ExtensionNativeBlockContext.Signature)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.accessibilityIdentifier = "extension-widget-lines-scroll"
        addSubview(scrollView)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.addSubview(textView)

        let padding = Self.padding
        let fillWidth = textView.widthAnchor.constraint(
            greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(padding.leading + padding.trailing)
        )
        textWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: padding.top),
            textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: padding.leading),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -padding.trailing),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -padding.bottom),
            scrollView.frameLayoutGuide.heightAnchor.constraint(
                equalTo: textView.heightAnchor,
                constant: padding.top + padding.bottom
            ),
            textWidth,
            textHeight,
            fillWidth,
        ])

        // Scaled fonts re-resolve with Dynamic Type; the unwrapped lines need a new measure.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.measureText()
            view.invalidateExtensionNativeBlockHost()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        textView.openURL = { context.open($0) }
        guard case .terminal(let base, let lines, let raw) = block,
              appliedBlock?.block != block || appliedBlock?.signature != context.signature else { return }
        appliedBlock = (block, context.signature)
        if let raw {
            install(Self.paintTerminalOutput(raw, palette: context.palette), palette: context.palette)
            textView.accessibilityLabel = base.accessibility?.label
            return
        }
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(line.extensionNativeAttributedString(
                palette: context.palette,
                textStyle: .caption2,
                monospaced: true
            ))
        }
        install(text, palette: context.palette)
        textView.accessibilityLabel = base.accessibility?.label
    }

    /// Plain widget lines: ANSI colors kept, `●`/`○` headers drawn as status rows,
    /// `⎿` activity lines dimmed.
    func apply(widgetLines lines: [String], context: ExtensionNativeBlockContext) {
        textView.openURL = { context.open($0) }
        guard appliedLines?.lines != lines || appliedLines?.signature != context.signature else { return }
        appliedLines = (lines, context.signature)
        let palette = context.palette
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            switch ExtensionNativeBlockPresentation.widgetLineStyle(line) {
            case .header(let title, let isActive):
                text.append(NSAttributedString(string: "●  ", attributes: [
                    .font: UIFont.systemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: isActive ? palette.green : palette.comment,
                    .baselineOffset: 1,
                ]))
                text.append(NSAttributedString(string: title, attributes: [
                    .font: ExtensionNativeBlockStyle.font(.caption1, weight: .semibold),
                    .foregroundColor: palette.ui.fg,
                ]))
            case .text(let isActivity):
                text.append(ANSIParser.attributedString(
                    from: line,
                    baseForeground: isActivity ? palette.ui.comment : palette.ui.fg
                ))
            }
        }
        install(text, palette: palette)
        textView.accessibilityLabel = nil
    }

    /// Raw output is untrusted: the VT engine runs with terminal effects off, and
    /// the result reaches UIKit only as text plus SGR. Extensions bound the tail size.
    private static func paintTerminalOutput(_ raw: String, palette: ThemePalette) -> NSMutableAttributedString {
        #if canImport(GhosttyVt)
        var resolved = (try? TerminalLogEngine.render(raw)) ?? raw
        #else
        var resolved = raw
        #endif
        while resolved.hasSuffix("\n") { resolved.removeLast() }
        return NSMutableAttributedString(
            attributedString: ANSIParser.attributedString(from: resolved, baseForeground: palette.ui.fg)
        )
    }

    private func install(_ text: NSMutableAttributedString, palette: ThemePalette) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byClipping
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        textView.attributedText = text
        ExtensionNativeBlockStyle.applyInset(to: self, palette: palette)
        measureText()
        invalidateIntrinsicContentSize()
    }

    private func measureText() {
        guard let text = textView.attributedText else { return }
        let size = text.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        textWidth.constant = ceil(size.width) + 1
        textHeight.constant = max(1, ceil(size.height))
    }
}

// MARK: - Section

/// A titled group of blocks, drawn as a list section is: a grouped header over its blocks, with
/// no box of its own, so a section of lists in a drawer is not a card inside a card.
final class ExtensionNativeSectionBlockView: UIView, ExtensionNativeBlockRendering {
    private let header = UIListContentView(configuration: .groupedHeader())
    private let children = ExtensionNativeBlockStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [header, children])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        children.spacing = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func adoptLayoutWidth(_ width: CGFloat) {
        children.adoptLayoutWidth(width)
    }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .section(let base, let title, let subtitle, let blocks) = block else { return }
        let palette = context.palette
        var configuration = UIListContentConfiguration.groupedHeader()
        configuration.text = title?.trimmedNonEmpty
        configuration.textProperties.color = palette.ui.comment
        configuration.textProperties.font = ExtensionNativeBlockStyle.font(.footnote, weight: .semibold)
        configuration.secondaryText = subtitle?.trimmedNonEmpty
        configuration.secondaryTextProperties.color = palette.ui.comment
        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0)
        header.configuration = configuration
        header.isHidden = configuration.text == nil && configuration.secondaryText == nil
        header.accessibilityTraits = .header
        children.apply(blocks: blocks, context: context)
        children.isHidden = blocks.isEmpty
        accessibilityLabel = base.accessibility?.label
    }
}

// MARK: - Progress

final class ExtensionNativeProgressBar: UIView {
    private let fill = UIView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(fill)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Paint the bar in its own colours, or in `tint` when the node declaring it carried a tone.
    func apply(fraction: Double, palette: ThemePalette, tint: UIColor? = nil) {
        self.fraction = CGFloat(fraction)
        backgroundColor = tint?.withAlphaComponent(0.18) ?? palette.ui.fg.withAlphaComponent(0.12)
        fill.backgroundColor = (tint ?? palette.ui.fg).withAlphaComponent(0.82)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        fill.layer.cornerRadius = bounds.height / 2
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }
}

final class ExtensionNativeProgressBlockView: UIView, ExtensionNativeBlockRendering {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = ExtensionNativeBlockStyle.label(.caption1)
    private let bar = ExtensionNativeProgressBar()
    private let row = UIStackView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.addArrangedSubview(spinner)
        row.addArrangedSubview(label)
        stack.axis = .vertical
        stack.spacing = 6
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(bar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 5),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        apply(block, context: context, tint: nil)
    }

    /// A composite may declare a tone for its bar. The v1 block has none, and keeps the host's own
    /// foreground, so both callers share one view.
    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext, tint: UIColor?) {
        guard case .progress(let base, let rawLabel, let value, let indeterminate) = block else { return }
        let palette = context.palette
        let trimmedLabel = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelText = trimmedLabel?.isEmpty == false ? trimmedLabel : nil
        let fraction = ExtensionNativeBlockPresentation.normalizedProgress(value)
        let isIndeterminate = indeterminate == true || fraction == nil

        label.text = labelText
        label.textColor = palette.ui.fg
        label.isHidden = labelText == nil
        spinner.color = tint ?? palette.ui.blue
        spinner.isHidden = !isIndeterminate
        if isIndeterminate { spinner.startAnimating() } else { spinner.stopAnimating() }
        row.isHidden = !isIndeterminate && labelText == nil
        bar.isHidden = isIndeterminate
        if let fraction { bar.apply(fraction: fraction, palette: palette, tint: tint) }

        accessibilityLabel = base.accessibility?.label ?? labelText ?? "Progress"
        accessibilityValue = base.accessibility?.value
            ?? (isIndeterminate ? "In progress" : fraction.map(ExtensionNativeBlockPresentation.percentText))
    }
}

// MARK: - Table

/// Query results reuse the chat's delimited-table grid. Height hugs the fitted
/// row count so the drawer and full-screen reader can scroll the surface.
final class ExtensionNativeTableBlockView: UIView, ExtensionNativeBlockRendering {
    private var tableView: DelimitedTableRenderView?
    private var heightConstraint: NSLayoutConstraint?
    private var applied: (block: ExtensionUINativeBlock, signature: ExtensionNativeBlockContext.Signature)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        accessibilityIdentifier = "extension.native.table"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .table(let base, let columns, let rows, let truncated) = block else { return }
        if applied?.block == block, applied?.signature == context.signature { return }
        applied = (block, context.signature)
        let plan = Self.plan(columns: columns, rows: rows, truncated: truncated == true)
        if let existing = tableView, existing.displays(plan) {
            accessibilityLabel = base.accessibility?.label ?? "Table"
            return
        }
        tableView?.removeFromSuperview()
        let view = DelimitedTableRenderView(plan: plan, palette: context.palette)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let height = view.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        tableView = view
        heightConstraint = height
        accessibilityLabel = base.accessibility?.label ?? "Table"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let tableView else { return }
        let width = bounds.width > 0 ? bounds.width : 360
        let height = tableView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if abs((heightConstraint?.constant ?? 0) - height) > 0.5 {
            heightConstraint?.constant = max(1, height)
            invalidateExtensionNativeBlockHost()
        }
    }

    private static func plan(
        columns: [String],
        rows: [[ExtensionUITableCell]],
        truncated: Bool
    ) -> DelimitedTableViewerPlan {
        let table = DelimitedTable(
            headers: columns,
            rows: rows.map { $0.map(\.displayText) },
            columnCount: columns.count,
            totalRowCount: (columns.isEmpty && rows.isEmpty ? 0 : 1) + rows.count,
            totalColumnCount: columns.count,
            truncatedRows: truncated,
            truncatedColumns: false,
            truncatedCells: truncated
        )
        return DelimitedTableViewerPlan(kind: .csv, source: "", table: table)
    }
}

// MARK: - Chart

/// Charts reuse the Core Graphics Mermaid XY and pie renderers by building their
/// diagram models directly. No Mermaid source, SwiftUI, or Swift Charts.
final class ExtensionNativeChartBlockView: UIView, ExtensionNativeBlockRendering {
    private let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isAccessibilityElement = true
        return view
    }()
    private var heightConstraint: NSLayoutConstraint?
    private var applied: (block: ExtensionUINativeBlock, signature: ExtensionNativeBlockContext.Signature, width: CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
        let height = imageView.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        heightConstraint = height
        accessibilityIdentifier = "extension.native.chart"
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .chart(let base, let kind, let title, _, _, _) = block else { return }
        imageView.accessibilityLabel = base.accessibility?.label ?? title ?? "\(kind) chart"
        rasterizeIfNeeded(block, context: context)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let applied else { return }
        rasterizeIfNeeded(applied.block, context: ExtensionNativeBlockContext(
            themeID: applied.signature.themeID,
            linkContext: applied.signature.linkContext
        ))
    }

    private func rasterizeIfNeeded(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        let width = max(bounds.width > 0 ? bounds.width : 360, 40)
        if applied?.block == block,
           applied?.signature == context.signature,
           abs((applied?.width ?? 0) - width) < 0.5 {
            return
        }
        applied = (block, context.signature, width)
        guard let image = Self.rasterize(block, theme: context.palette.renderTheme, width: width) else {
            imageView.image = nil
            heightConstraint?.constant = 1
            return
        }
        imageView.image = image
        let height = image.size.height
        if abs((heightConstraint?.constant ?? 0) - height) > 0.5 {
            heightConstraint?.constant = max(1, height)
            invalidateExtensionNativeBlockHost()
        }
    }

    private static func rasterize(
        _ block: ExtensionUINativeBlock,
        theme: RenderTheme,
        width: CGFloat
    ) -> UIImage? {
        guard case .chart(_, let kind, let title, let labels, let series, _) = block else { return nil }
        let configuration = RenderConfiguration(
            fontSize: 14,
            maxWidth: width,
            theme: theme,
            displayMode: .inline
        )
        let layout: MermaidFlowchartRenderer.FlowchartLayout
        if kind == "pie" {
            let slices = labels.enumerated().compactMap { index, label -> PieSlice? in
                guard let value = series.first?.values[safe: index] else { return nil }
                return PieSlice(label: label, value: value)
            }
            layout = MermaidPieRenderer.layout(
                PieDiagram(title: title, slices: slices, showData: true),
                configuration: configuration
            )
        } else {
            let seriesKind: XYChartSeriesKind = kind == "line" ? .line : .bar
            layout = MermaidXYChartRenderer.layout(
                XYChartDiagram(
                    title: title,
                    xAxis: .categorical(title: nil, categories: labels),
                    yAxis: XYChartYAxis(title: nil, min: nil, max: nil),
                    series: series.map {
                        XYChartSeries(kind: seriesKind, name: $0.name, values: $0.values)
                    },
                    orientation: .vertical
                ),
                configuration: configuration
            )
        }
        let size = layout.customSize ?? .zero
        guard let draw = layout.customDraw, size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(ctx.cgContext, .zero)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Divider and spacer

final class ExtensionNativeDividerView: UIView, ExtensionNativeBlockRendering {
    override init(frame: CGRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 1 / max(1, UITraitCollection.current.displayScale)).isActive = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        apply(block, context: context, tint: nil)
    }

    /// A composite paints its rule from the theme it draws in; the v1 block declares no tone and
    /// keeps the host's separator, so both callers share one view.
    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext, tint: UIColor?) {
        backgroundColor = tint ?? .separator
    }
}

final class ExtensionNativeSpacerView: UIView, ExtensionNativeBlockRendering {
    private lazy var height = heightAnchor.constraint(equalToConstant: 6)

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .spacer(_, let size) = block else { return }
        height.constant = switch size {
        case "large": 16
        case "medium": 10
        default: 6
        }
        height.isActive = true
        isAccessibilityElement = false
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

// MARK: - Scroll host

/// Hosts one surface's blocks in a vertical scroll view.
///
/// `.capped` hugs its content up to `maxHeight` and scrolls past it (the
/// composer drawer viewport); `.fill` takes the space it is given (full-screen
/// detail). The host reports content height changes by invalidating its
/// intrinsic size.
final class ExtensionNativeBlockScrollView: UIView, UIGestureRecognizerDelegate {
    enum Sizing: Equatable {
        case capped(maxHeight: CGFloat)
        case fill
    }

    private final class ReportingScrollView: UIScrollView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    private let scrollView = ReportingScrollView()
    private let blockStack = ExtensionNativeBlockStackView()
    private var insetConstraints: [NSLayoutConstraint] = []
    private var contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    private var sizing: Sizing = .fill
    private var onDoubleTap: (() -> Void)?
    private var lastContentHeight: CGFloat = -1

    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = true
        scrollView.onLayout = { [weak self] in self?.scrollViewDidLayout() }
        addSubview(scrollView)

        blockStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(blockStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        installInsetConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(
        content: ExtensionNativeBlockContent,
        context: ExtensionNativeBlockContext,
        sizing: Sizing,
        contentInsets: NSDirectionalEdgeInsets,
        spacing: CGFloat,
        accessibilityIdentifier: String?,
        onDoubleTap: (() -> Void)?
    ) {
        self.sizing = sizing
        self.onDoubleTap = onDoubleTap
        if self.contentInsets != contentInsets {
            self.contentInsets = contentInsets
            installInsetConstraints()
        }
        blockStack.spacing = spacing
        scrollView.accessibilityIdentifier = accessibilityIdentifier
        syncDoubleTapRecognizer()
        blockStack.apply(content, context: context)
        // The apply swaps arranged subviews; flush the stack views' arrangement
        // constraints now, or a measurement right after this update
        // (`viewportHeight(for:)`) sees the previous, emptied arrangement.
        layoutIfNeeded()
        contentDidChange()
    }

    /// Re-measure after content changed outside `update`.
    func contentDidChange() {
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        guard case .capped = sizing else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let width = bounds.width > 0 ? bounds.width : ((superview?.bounds.width).flatMap { $0 > 0 ? $0 : nil } ?? 390)
        return CGSize(width: UIView.noIntrinsicMetric, height: viewportHeight(for: width))
    }

    /// The host will show this viewport at `width`. Blocks lay out what
    /// depends on width before it is measured.
    func adoptLayoutWidth(_ width: CGFloat) {
        blockStack.adoptLayoutWidth(max(1, width - contentInsets.leading - contentInsets.trailing))
    }

    /// Height the capped viewport wants at `width`: its content, at most `maxHeight`.
    func viewportHeight(for width: CGFloat) -> CGFloat {
        let content = contentHeight(for: width)
        guard case .capped(let maxHeight) = sizing else { return content }
        return min(max(1, maxHeight), content)
    }

    private func contentHeight(for width: CGFloat) -> CGFloat {
        let stackWidth = max(1, width - contentInsets.leading - contentInsets.trailing)
        let height = blockStack.systemLayoutSizeFitting(
            CGSize(width: stackWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard height.isFinite else { return 1 }
        return max(1, ceil(height + contentInsets.top + contentInsets.bottom))
    }

    private func scrollViewDidLayout() {
        let contentHeight = scrollView.contentSize.height
        let canScroll: Bool
        switch sizing {
        case .capped(let maxHeight):
            canScroll = contentHeight > maxHeight + 0.5
        case .fill:
            canScroll = true
        }
        scrollView.isScrollEnabled = canScroll
        scrollView.alwaysBounceVertical = canScroll

        // Replacement content can be shorter than the current offset; never
        // leave empty scroll space below the last block.
        let maxOffsetY = max(0, contentHeight - scrollView.bounds.height)
        if scrollView.contentOffset.y > maxOffsetY + 0.5 {
            scrollView.contentOffset.y = maxOffsetY
        }

        if abs(contentHeight - lastContentHeight) > 0.5 {
            lastContentHeight = contentHeight
            invalidateIntrinsicContentSize()
        }
    }

    private func installInsetConstraints() {
        NSLayoutConstraint.deactivate(insetConstraints)
        insetConstraints = [
            blockStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: contentInsets.top),
            blockStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: contentInsets.leading),
            blockStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -contentInsets.trailing),
            blockStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -contentInsets.bottom),
            // Below required so height measurement at a proposed width wins over a
            // frame that has not been laid out yet.
            blockStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -(contentInsets.leading + contentInsets.trailing)
            ).withPriority(.required - 1),
        ]
        NSLayoutConstraint.activate(insetConstraints)
    }

    private func syncDoubleTapRecognizer() {
        let isInstalled = doubleTapRecognizer.view === scrollView
        if onDoubleTap != nil, !isInstalled {
            scrollView.addGestureRecognizer(doubleTapRecognizer)
        } else if onDoubleTap == nil, isInstalled {
            scrollView.removeGestureRecognizer(doubleTapRecognizer)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onDoubleTap?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Selectable block text would otherwise claim the double tap for word
    /// selection. Its taps wait for the full-screen double tap to fail; scroll
    /// pans never wait.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === doubleTapRecognizer
            && otherGestureRecognizer is UITapGestureRecognizer
            && otherGestureRecognizer.view?.isDescendant(of: scrollView) == true
    }
}
