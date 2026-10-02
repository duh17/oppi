import SwiftUI
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

    var palette: ThemePalette { themeID.palette }

    /// Extension links route through the host first, then the browser preference
    /// for web links or the system for other unhandled schemes.
    @MainActor
    func open(_ url: URL) {
        guard onOpenURL?(url) != true else { return }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            AppSupportLinks.open(url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// Markdown blocks bind the session/workspace identity so wiki links become
    /// the same resource references assistant prose produces.
    var markdownResourceAccess: MarkdownResourceAccess {
        MarkdownResourceAccess(identity: .init(
            serverID: linkContext.serverID,
            workspaceID: linkContext.workspaceID,
            sessionID: linkContext.sessionID
        ))
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
}

// MARK: - Fonts and colors

@MainActor
enum ExtensionNativeBlockStyle {
    /// Dynamic Type font for `style`, sized from the style's default point size.
    static func font(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        monospaced: Bool = false,
        traits: UIFontDescriptor.SymbolicTraits = []
    ) -> UIFont {
        let size = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        var font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        if !traits.isEmpty,
           let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    static func activityColor(_ tone: ExtensionNativeBlockPresentation.ActivityTone, palette: ThemePalette) -> UIColor {
        switch tone {
        case .running: UIColor(palette.blue)
        case .success: UIColor(palette.green)
        case .warning: UIColor(palette.orange)
        case .error: UIColor(palette.red)
        case .queued: UIColor(palette.purple)
        case .inactive, .neutral: UIColor(palette.comment)
        }
    }

    /// The rounded, faintly filled inset that frames code-like and grouped content.
    static func applyInset(to view: UIView, palette: ThemePalette, cornerRadius: CGFloat = 12) {
        view.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.04)
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor(palette.fg).withAlphaComponent(0.08).cgColor
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
            .foregroundColor: UIColor(palette.fg),
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
            attributes[.foregroundColor] = UIColor(palette.cyan)
        }
        if let url {
            attributes[.link] = url
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func roleColor(_ role: String?, palette: ThemePalette) -> UIColor? {
        switch role {
        case "primary": UIColor(palette.fg)
        case "secondary": UIColor(palette.comment)
        case "muted": UIColor(palette.fgDim)
        case "accent": UIColor(palette.cyan)
        case "success": UIColor(palette.green)
        case "warning": UIColor(palette.orange)
        case "danger": UIColor(palette.red)
        case "code": UIColor(palette.yellow)
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
            resourceAccess: context.markdownResourceAccess,
            readerPreferences: Self.preferences,
            renderingMode: .staticReader
        ))
        invalidateIntrinsicContentSize()
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
                    .foregroundColor: UIColor(isActive ? palette.green : palette.comment),
                    .baselineOffset: 1,
                ]))
                text.append(NSAttributedString(string: title, attributes: [
                    .font: ExtensionNativeBlockStyle.font(.caption1, weight: .semibold),
                    .foregroundColor: UIColor(palette.fg),
                ]))
            case .text(let isActivity):
                text.append(ANSIParser.attributedString(
                    from: line,
                    baseForeground: isActivity ? palette.comment : palette.fg
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
            attributedString: ANSIParser.attributedString(from: resolved, baseForeground: palette.fg)
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

final class ExtensionNativeSectionBlockView: UIView, ExtensionNativeBlockRendering {
    private let titleLabel = ExtensionNativeBlockStyle.label(.caption1, weight: .semibold)
    private let subtitleLabel = ExtensionNativeBlockStyle.label(.caption2)
    private let children = ExtensionNativeBlockStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let headerStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        headerStack.axis = .vertical
        headerStack.spacing = 2
        let stack = UIStackView(arrangedSubviews: [headerStack, children])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        children.spacing = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .section(let base, let title, let subtitle, let blocks) = block else { return }
        let palette = context.palette
        ExtensionNativeBlockStyle.applyInset(to: self, palette: palette)
        titleLabel.text = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.textColor = UIColor(palette.fg)
        titleLabel.isHidden = titleLabel.text?.isEmpty ?? true
        subtitleLabel.text = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        subtitleLabel.textColor = UIColor(palette.comment)
        subtitleLabel.isHidden = subtitleLabel.text?.isEmpty ?? true
        titleLabel.superview?.isHidden = titleLabel.isHidden && subtitleLabel.isHidden
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

    func apply(fraction: Double, palette: ThemePalette) {
        self.fraction = CGFloat(fraction)
        backgroundColor = UIColor(palette.fg).withAlphaComponent(0.12)
        fill.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.82)
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
        guard case .progress(let base, let rawLabel, let value, let indeterminate) = block else { return }
        let palette = context.palette
        let trimmedLabel = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelText = trimmedLabel?.isEmpty == false ? trimmedLabel : nil
        let fraction = ExtensionNativeBlockPresentation.normalizedProgress(value)
        let isIndeterminate = indeterminate == true || fraction == nil

        label.text = labelText
        label.textColor = UIColor(palette.fg)
        label.isHidden = labelText == nil
        spinner.color = UIColor(palette.blue)
        spinner.isHidden = !isIndeterminate
        if isIndeterminate { spinner.startAnimating() } else { spinner.stopAnimating() }
        row.isHidden = !isIndeterminate && labelText == nil
        bar.isHidden = isIndeterminate
        if let fraction { bar.apply(fraction: fraction, palette: palette) }

        accessibilityLabel = base.accessibility?.label ?? labelText ?? "Progress"
        accessibilityValue = base.accessibility?.value
            ?? (isIndeterminate ? "In progress" : fraction.map(ExtensionNativeBlockPresentation.percentText))
    }
}

// MARK: - Activity list

final class ExtensionNativeActivityListView: UIView, ExtensionNativeBlockRendering {
    private let stack = UIStackView()
    private var rowViews: [String: ExtensionNativeActivityRowView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .activityList(_, let rows) = block else { return }
        apply(rows: rows, context: context)
    }

    func apply(rows: [ExtensionUIActivityRow], context: ExtensionNativeBlockContext) {
        var next: [String: ExtensionNativeActivityRowView] = [:]
        var ordered: [UIView] = []
        for row in rows where next[row.id] == nil {
            let view = rowViews[row.id] ?? ExtensionNativeActivityRowView()
            view.apply(row: row, context: context)
            next[row.id] = view
            ordered.append(view)
        }
        rowViews = next
        guard stack.arrangedSubviews != ordered else { return }
        for view in stack.arrangedSubviews where !ordered.contains(view) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in ordered.enumerated() {
            stack.insertArrangedSubview(view, at: index)
        }
    }
}

/// One activity row: state marker, title/subtitle/detail, optional progress,
/// nested children, and navigation when the row carries a link. A row with
/// `blocks` is a disclosure row: tapping shows or hides the blocks, which are
/// built only while shown, and a link moves to its own trailing button. Expansion survives snapshots because list views
/// reuse row views by row id.
final class ExtensionNativeActivityRowView: UIView {
    private let control = UIControl()
    private let marker = UIImageView()
    private let titleLabel = ExtensionNativeBlockStyle.label(.caption1, weight: .semibold)
    private let subtitleLabel = ExtensionNativeBlockStyle.label(.caption2)
    private let detailLabel = ExtensionNativeBlockStyle.label(.caption2)
    private let progressBar = ExtensionNativeProgressBar()
    private let chevron = UIImageView()
    private let childContainer = UIView()
    private var childList: ExtensionNativeActivityListView?
    private let detailContainer = UIView()
    private let linkButton = UIButton(type: .system)
    private var detailStack: ExtensionNativeBlockStackView?
    private var isExpanded = false
    private lazy var minimumHeight = control.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)

    private var row: ExtensionUIActivityRow?
    private var context: ExtensionNativeBlockContext?

    override init(frame: CGRect) {
        super.init(frame: frame)

        marker.contentMode = .center
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.isAccessibilityElement = false
        chevron.contentMode = .center
        chevron.isAccessibilityElement = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, detailLabel, progressBar])
        labels.axis = .vertical
        labels.spacing = 3
        labels.setCustomSpacing(7, after: detailLabel)
        labels.isUserInteractionEnabled = false

        let markerColumn = UIView()
        markerColumn.isUserInteractionEnabled = false
        markerColumn.addSubview(marker)
        let content = UIStackView(arrangedSubviews: [markerColumn, labels, chevron])
        content.axis = .horizontal
        content.alignment = .top
        content.spacing = 10
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(content)
        control.layer.cornerRadius = 12
        control.layer.cornerCurve = .continuous
        control.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        detailContainer.isHidden = true
        linkButton.isHidden = true
        linkButton.addTarget(self, action: #selector(handleLinkTap), for: .touchUpInside)
        linkButton.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [control, linkButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 4
        let column = UIStackView(arrangedSubviews: [header, detailContainer, childContainer])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: control.topAnchor, constant: 5),
            content.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -6),
            content.bottomAnchor.constraint(lessThanOrEqualTo: control.bottomAnchor, constant: -5),
            content.centerYAnchor.constraint(equalTo: control.centerYAnchor).withPriority(.defaultLow),
            markerColumn.widthAnchor.constraint(equalToConstant: 14),
            marker.topAnchor.constraint(equalTo: markerColumn.topAnchor, constant: 3),
            marker.centerXAnchor.constraint(equalTo: markerColumn.centerXAnchor),
            marker.widthAnchor.constraint(equalToConstant: 14),
            marker.heightAnchor.constraint(equalToConstant: 14),
            markerColumn.heightAnchor.constraint(greaterThanOrEqualToConstant: 17),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            linkButton.widthAnchor.constraint(equalToConstant: 44),
            linkButton.heightAnchor.constraint(equalToConstant: 44),
            minimumHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(row: ExtensionUIActivityRow, context: ExtensionNativeBlockContext) {
        self.row = row
        self.context = context
        render()
    }

    private var linkURL: URL? {
        row.flatMap(ExtensionNativeBlockPresentation.activityRowURL)
    }

    private var detailBlocks: [ExtensionUINativeBlock] {
        row?.blocks?.compactMap(\.nativeDisplayBlock) ?? []
    }

    private func render() {
        guard let row, let context else { return }
        let palette = context.palette
        let tone = ExtensionNativeBlockPresentation.activityTone(row.state)
        let accent = ExtensionNativeBlockStyle.activityColor(tone, palette: palette)
        let detailBlocks = detailBlocks
        let hasDetail = !detailBlocks.isEmpty
        let rowLink = linkURL
        // The row tap has one job: disclosure when the row has blocks, else
        // navigation. A row with both keeps its link on a separate button.
        let linkURL = hasDetail ? nil : rowLink

        marker.image = UIImage(
            systemName: Self.markerSymbol(tone),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: tone == .inactive ? .regular : .semibold)
        )
        marker.tintColor = accent

        titleLabel.text = row.title
        titleLabel.textColor = UIColor(palette.fg)
        Self.setOptional(row.subtitle, on: subtitleLabel, color: UIColor(palette.comment))
        Self.setOptional(row.detail, on: detailLabel, color: UIColor(palette.comment))

        if let progress = ExtensionNativeBlockPresentation.normalizedProgress(row.progress) {
            progressBar.isHidden = false
            progressBar.apply(fraction: progress, palette: palette)
        } else {
            progressBar.isHidden = true
        }

        let isLinked = linkURL != nil
        let isInteractive = isLinked || hasDetail
        chevron.isHidden = !isInteractive
        chevron.image = UIImage(
            systemName: hasDetail ? (isExpanded ? "chevron.up" : "chevron.down") : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2, scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        )
        chevron.tintColor = UIColor(palette.comment)
        minimumHeight.constant = isInteractive ? 44 : 34

        let emphasized = tone == .running || tone == .warning || tone == .error
        control.backgroundColor = UIColor(palette.fg).withAlphaComponent(emphasized ? 0.05 : 0)
        control.layer.borderWidth = emphasized ? 1 : 0
        control.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.16).cgColor
        control.isUserInteractionEnabled = isInteractive

        control.isAccessibilityElement = true
        control.accessibilityIdentifier = "extension.native.activity.row.\(row.id)"
        control.accessibilityLabel = ExtensionNativeBlockPresentation.activityRowAccessibilityLabel(row)
        control.accessibilityValue = ExtensionNativeBlockPresentation.activityRowAccessibilityValue(row)
        control.accessibilityTraits = isInteractive ? .button : .staticText
        control.accessibilityHint = hasDetail
            ? (isExpanded ? "Hides details" : "Shows details")
            : linkURL.flatMap { url in
            ExtensionSurfaceLinkRouting.accessibilityHint(
                for: ExtensionSurfaceLinkRouting.action(
                    for: url,
                    serverID: context.linkContext.serverID,
                    workspaceID: context.linkContext.workspaceID,
                    currentSessionId: context.linkContext.sessionID ?? ""
                )
            )
        }

        let separateLink = hasDetail ? rowLink : nil
        linkButton.isHidden = separateLink == nil
        linkButton.setImage(UIImage(
            systemName: "arrow.up.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        ), for: .normal)
        linkButton.tintColor = UIColor(palette.comment)
        linkButton.accessibilityIdentifier = "extension.native.activity.row.\(row.id).link"
        linkButton.accessibilityLabel = "Open \(row.title)"
        linkButton.accessibilityHint = separateLink.flatMap { url in
            ExtensionSurfaceLinkRouting.accessibilityHint(
                for: ExtensionSurfaceLinkRouting.action(
                    for: url,
                    serverID: context.linkContext.serverID,
                    workspaceID: context.linkContext.workspaceID,
                    currentSessionId: context.linkContext.sessionID ?? ""
                )
            )
        }

        if hasDetail, isExpanded {
            let stack = detailStack ?? makeDetailStack()
            stack.apply(blocks: detailBlocks, context: context)
            detailContainer.isHidden = false
        } else {
            detailContainer.isHidden = true
            if !hasDetail, let stack = detailStack {
                stack.removeFromSuperview()
                detailStack = nil
                isExpanded = false
            }
        }

        let children = row.children ?? []
        if !children.isEmpty {
            let list = childList ?? makeChildList()
            list.apply(rows: children, context: context)
            childContainer.isHidden = false
        } else {
            childContainer.isHidden = true
        }
    }

    private func makeChildList() -> ExtensionNativeActivityListView {
        let list = ExtensionNativeActivityListView()
        list.translatesAutoresizingMaskIntoConstraints = false
        childContainer.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: childContainer.topAnchor),
            list.leadingAnchor.constraint(equalTo: childContainer.leadingAnchor, constant: 22),
            list.trailingAnchor.constraint(equalTo: childContainer.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: childContainer.bottomAnchor),
        ])
        childList = list
        return list
    }

    private func makeDetailStack() -> ExtensionNativeBlockStackView {
        let stack = ExtensionNativeBlockStackView()
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        detailStack = stack
        return stack
    }

    @objc private func handleTap() {
        if !detailBlocks.isEmpty {
            isExpanded.toggle()
            render()
            invalidateExtensionNativeBlockHost()
            UIAccessibility.post(notification: .layoutChanged, argument: control)
            return
        }
        guard let url = linkURL else { return }
        context?.open(url)
    }

    @objc private func handleLinkTap() {
        guard let url = linkURL else { return }
        context?.open(url)
    }

    private static func setOptional(_ text: String?, on label: UILabel, color: UIColor) {
        let value = text?.isEmpty == false ? text : nil
        label.text = value
        label.isHidden = value == nil
        label.textColor = color
    }

    private static func markerSymbol(_ tone: ExtensionNativeBlockPresentation.ActivityTone) -> String {
        switch tone {
        case .running: "play.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .queued: "clock.circle.fill"
        case .inactive: "circle"
        case .neutral: "circle.fill"
        }
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
        backgroundColor = .separator
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
/// detail). The host reports content height changes so SwiftUI re-measures.
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
        // constraints now, or the measurement SwiftUI takes right after this
        // update (sizeThatFits) sees the previous, emptied arrangement.
        layoutIfNeeded()
        contentDidChange()
    }

    /// Re-measure after content changed outside a SwiftUI update.
    func contentDidChange() {
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        guard case .capped = sizing else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let width = bounds.width > 0 ? bounds.width : (window?.windowScene?.screen.bounds.width ?? 390)
        return CGSize(width: UIView.noIntrinsicMetric, height: viewportHeight(for: width))
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

// MARK: - SwiftUI bridge

/// SwiftUI placement of the UIKit block renderer. Chrome (pills, drawer header,
/// sheets) stays in SwiftUI; every block paints through UIKit.
struct ExtensionNativeBlocksView: UIViewRepresentable {
    let content: ExtensionNativeBlockContent
    let sizing: ExtensionNativeBlockScrollView.Sizing
    var contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    var spacing: CGFloat = 10
    var accessibilityIdentifier: String?
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)?
    var onDoubleTap: (() -> Void)?

    @Environment(\.themeID) private var themeID

    func makeUIView(context: Context) -> ExtensionNativeBlockScrollView {
        ExtensionNativeBlockScrollView()
    }

    func updateUIView(_ uiView: ExtensionNativeBlockScrollView, context: Context) {
        uiView.update(
            content: content,
            context: ExtensionNativeBlockContext(
                themeID: themeID,
                linkContext: linkContext,
                onOpenURL: onOpenURL
            ),
            sizing: sizing,
            contentInsets: contentInsets,
            spacing: spacing,
            accessibilityIdentifier: accessibilityIdentifier,
            onDoubleTap: onDoubleTap
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ExtensionNativeBlockScrollView,
        context: Context
    ) -> CGSize? {
        guard case .capped = sizing else { return nil }
        let width = proposal.width ?? uiView.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.viewportHeight(for: width))
    }
}
