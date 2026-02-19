import UIKit

// MARK: - Native Markdown Content View

/// Native UIKit markdown renderer for assistant messages.
///
/// Single renderer for both streaming and finalized content. Uses
/// `parseCommonMark()` (apple/swift-markdown, cmark-backed) for parsing
/// and `FlatSegment` for rendering.
///
/// **Streaming**: parses on every content update (~1ms for cmark + segment
/// build). Updates existing views in-place when segment structure is stable.
/// Shows a pulsing cursor.
///
/// **Finalized**: reads from `MarkdownSegmentCache` when available, otherwise
/// parses once and caches.
final class AssistantMarkdownContentView: UIView {

    struct Configuration: Equatable {
        let content: String
        let isStreaming: Bool
        let themeID: ThemeID

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.content == rhs.content
                && lhs.isStreaming == rhs.isStreaming
                && lhs.themeID == rhs.themeID
        }
    }

    // MARK: - View hierarchy

    private let stackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .fill
        sv.spacing = 8
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    // Cursor removed — streaming text growth is sufficient visual feedback,
    // and the working indicator at the timeline bottom handles busy state.

    /// Very large responses fall back to plain text to avoid expensive layout.
    private static let plainTextFallbackThreshold = 20_000

    // MARK: - State

    private var currentConfig: Configuration?
    /// Segment types currently rendered — used for structural diff.
    private var renderedSegmentSignatures: [SegmentSignature] = []
    /// References to text views in the stack for in-place content updates.
    private var textViews: [Int: BaselineSafeTextView] = [:]
    /// References to code block views for in-place updates.
    private var codeBlockViews: [Int: NativeCodeBlockView] = [:]
    /// References to table views for in-place updates during streaming.
    private var tableViews: [Int: NativeTableBlockView] = [:]

    private var highlightTasks: [Int: Task<Void, Never>] = [:]

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Setup

    private func setupViews() {
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Apply

    func apply(configuration config: Configuration) {
        guard config != currentConfig else { return }
        currentConfig = config

        let segments = buildSegments(config)
        let signatures = segments.map(SegmentSignature.init)

        if signatures == renderedSegmentSignatures {
            updateInPlace(segments: segments, config: config)
        } else {
            rebuild(segments: segments, signatures: signatures, config: config)
        }
    }

    // MARK: - Segment building

    private func buildSegments(_ config: Configuration) -> [FlatSegment] {
        let content = config.content

        // Plain-text fallback for very large messages.
        guard content.count <= Self.plainTextFallbackThreshold else {
            var plain = AttributedString(content)
            plain.foregroundColor = config.themeID.palette.fg
            return [.text(plain)]
        }

        // Cache hit (finalized only — streaming content changes every update).
        if !config.isStreaming,
           let cached = MarkdownSegmentCache.shared.get(content, themeID: config.themeID) {
            return cached
        }

        let blocks = parseCommonMark(content)
        let segments = FlatSegment.build(from: blocks, themeID: config.themeID)

        // Cache finalized parses.
        if !config.isStreaming {
            MarkdownSegmentCache.shared.set(content, themeID: config.themeID, segments: segments)
        }

        return segments
    }

    // MARK: - Structural rebuild

    private func rebuild(
        segments: [FlatSegment],
        signatures: [SegmentSignature],
        config: Configuration
    ) {
        // Cancel pending highlights.
        for task in highlightTasks.values { task.cancel() }
        highlightTasks.removeAll()

        // Remove all arranged subviews.
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        textViews.removeAll()
        codeBlockViews.removeAll()
        tableViews.removeAll()

        let palette = config.themeID.palette

        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let attributed):
                let tv = makeTextView(palette: palette)
                tv.attributedText = Self.normalizedAttributedText(
                    from: attributed, palette: palette
                )
                stackView.addArrangedSubview(tv)
                textViews[index] = tv

            case .codeBlock(let language, let code):
                let codeView = NativeCodeBlockView()
                let isOpen = config.isStreaming && index == segments.count - 1
                    && hasUnclosedCodeFence(config.content)
                codeView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
                stackView.addArrangedSubview(codeView)
                codeBlockViews[index] = codeView
                if !isOpen {
                    scheduleHighlight(index: index, language: language, code: code)
                }

            case .table(let headers, let rows):
                let tableView = NativeTableBlockView()
                tableView.apply(headers: headers, rows: rows, palette: palette)
                stackView.addArrangedSubview(tableView)
                tableViews[index] = tableView

            case .thematicBreak:
                let hr = makeThematicBreak(palette: palette)
                stackView.addArrangedSubview(hr)
            }
        }

        renderedSegmentSignatures = signatures
    }

    // MARK: - In-place update (hot path for streaming)

    private func updateInPlace(segments: [FlatSegment], config: Configuration) {
        let palette = config.themeID.palette

        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let attributed):
                if let tv = textViews[index] {
                    tv.attributedText = Self.normalizedAttributedText(
                        from: attributed, palette: palette
                    )
                }
            case .codeBlock(let language, let code):
                if let codeView = codeBlockViews[index] {
                    let isOpen = config.isStreaming && index == segments.count - 1
                        && hasUnclosedCodeFence(config.content)
                    codeView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
                    if !isOpen && highlightTasks[index] == nil {
                        scheduleHighlight(index: index, language: language, code: code)
                    }
                }
            case .table(let headers, let rows):
                if let tableView = tableViews[index] {
                    tableView.apply(headers: headers, rows: rows, palette: palette)
                }
            case .thematicBreak:
                break
            }
        }
    }

    // MARK: - Text view factory

    private func makeTextView(palette: ThemePalette) -> BaselineSafeTextView {
        let tv = BaselineSafeTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        tv.textColor = UIColor(palette.fg)
        tv.font = .preferredFont(forTextStyle: .body)
        tv.tintColor = UIColor(palette.blue)
        tv.linkTextAttributes = [
            .foregroundColor: UIColor(palette.blue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        return tv
    }

    // MARK: - Thematic break factory

    private func makeThematicBreak(palette: ThemePalette) -> UIView {
        let hr = UIView()
        hr.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.4)
        hr.translatesAutoresizingMaskIntoConstraints = false
        hr.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return hr
    }

    // MARK: - Attributed text normalization

    /// Ensures all runs have a base font and appropriate foreground color.
    ///
    /// Fixes dark-on-dark text in light→dark theme switches and fills in
    /// missing font attributes from the AttributedString builder.
    static func normalizedAttributedText(
        from attributed: AttributedString,
        palette: ThemePalette
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }

        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let baseColor = UIColor(palette.fg)
        let baseLuminance = Self.perceivedLuminance(of: baseColor)
        let shouldCorrectDarkText = baseLuminance > 0.55

        mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var updates: [NSAttributedString.Key: Any] = [:]

            if attributes[.font] == nil {
                updates[.font] = baseFont
            }

            if let color = attributes[.foregroundColor] as? UIColor {
                if shouldCorrectDarkText && Self.perceivedLuminance(of: color) < 0.2 {
                    updates[.foregroundColor] = baseColor
                }
            } else {
                updates[.foregroundColor] = baseColor
            }

            if !updates.isEmpty {
                mutable.addAttributes(updates, range: range)
            }
        }

        return mutable
    }

    private static func perceivedLuminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            var w: CGFloat = 0
            guard color.getWhite(&w, alpha: &a) else { return 0 }
            return w
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - Code fence detection

    /// Check if the source content has an unclosed code fence.
    ///
    /// Used during streaming to determine if the last code block segment
    /// is still being written (skip syntax highlighting, show as in-progress).
    private func hasUnclosedCodeFence(_ content: String) -> Bool {
        var openFences = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if openFences > 0 { openFences -= 1 } else { openFences += 1 }
            }
        }
        return openFences > 0
    }

    // MARK: - Async syntax highlighting

    private func scheduleHighlight(index: Int, language: String?, code: String) {
        guard let langStr = language,
              SyntaxLanguage.detect(langStr) != .unknown else { return }

        let lang = SyntaxLanguage.detect(langStr)
        highlightTasks[index]?.cancel()
        highlightTasks[index] = Task { [weak self] in
            let highlighted = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(code, language: lang)
            }.value
            guard !Task.isCancelled else { return }
            self?.codeBlockViews[index]?.applyHighlightedCode(highlighted)
        }
    }

}

// MARK: - UITextViewDelegate (deep link routing)

extension AssistantMarkdownContentView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content else {
            return defaultAction
        }

        return shouldOpenLinkExternally(url) ? defaultAction : nil
    }

    @MainActor
    func shouldOpenLinkExternally(_ url: URL) -> Bool {
        let normalizedURL = Self.normalizedInteractionURL(url)

        guard let scheme = normalizedURL.scheme?.lowercased() else {
            return true
        }

        if scheme == "pi" || scheme == "oppi" {
            NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: normalizedURL)
            return false
        }

        return true
    }

    private static let trailingLinkDelimiters: Set<Character> = ["`", "'", "\"", "\u{2018}", "\u{201C}"]
    private static let trailingEncodedLinkDelimiters = ["%60", "%27", "%22"]

    private static func normalizedInteractionURL(_ url: URL) -> URL {
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

// MARK: - Segment Signature (structural diff)

/// Lightweight token for comparing segment structure without content.
private enum SegmentSignature: Equatable {
    case text
    case codeBlock
    case table
    case thematicBreak

    init(_ segment: FlatSegment) {
        switch segment {
        case .text: self = .text
        case .codeBlock: self = .codeBlock
        case .table: self = .table
        case .thematicBreak: self = .thematicBreak
        }
    }
}

// MARK: - Native Code Block View

/// Code block container with language badge, copy button, and syntax highlighting.
///
/// Renders a code block with language badge, copy button, and
/// optional syntax highlighting. Supports in-place content updates
/// for streaming.
final class NativeCodeBlockView: UIView {

    private let headerStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.alignment = .center
        sv.spacing = 8
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let languageLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let copyButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "doc.on.doc")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 10, weight: .regular
        )
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let codeScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let codeLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        // Prevent Auto Layout from compressing the label to the scroll frame width.
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }()

    private let headerBackground = UIView()
    private var currentCode: String = ""

    /// Explicit width constraint for the label, updated in `apply()` to the
    /// measured content width so UIScrollView knows the content is wider than
    /// the frame and enables horizontal scrolling.
    private var codeLabelWidthConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true

        headerBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBackground)
        addSubview(headerStack)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(languageLabel)
        headerStack.addArrangedSubview(spacer)
        headerStack.addArrangedSubview(copyButton)

        addSubview(codeScrollView)
        codeScrollView.addSubview(codeLabel)

        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
        codeScrollView.addGestureRecognizer(longPress)

        let widthConstraint = codeLabel.widthAnchor.constraint(equalToConstant: 0)
        codeLabelWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            headerBackground.topAnchor.constraint(equalTo: topAnchor),
            headerBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBackground.bottomAnchor.constraint(equalTo: headerStack.bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            codeScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6),
            codeScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Pin content to contentLayoutGuide (determines scrollable area).
            codeLabel.topAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.topAnchor, constant: 12),
            codeLabel.leadingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            codeLabel.bottomAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.bottomAnchor, constant: -12),

            // Height: lock content height to frame height so the scroll view
            // self-sizes vertically based on code text (horizontal-only scroll).
            codeLabel.heightAnchor.constraint(equalTo: codeScrollView.frameLayoutGuide.heightAnchor, constant: -24),

            // Width: set explicitly from measured content so scroll view
            // knows content extends beyond its frame.
            widthConstraint,
        ])
    }

    func apply(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        currentCode = code

        backgroundColor = UIColor(palette.bgDark)
        headerBackground.backgroundColor = UIColor(palette.bgHighlight)
        layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.35).cgColor

        languageLabel.text = language ?? "code"
        languageLabel.textColor = UIColor(palette.comment)

        copyButton.tintColor = UIColor(palette.fgDim)

        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        codeLabel.font = font
        codeLabel.textColor = UIColor(palette.fg)
        codeLabel.text = code

        // Measure content width so the scroll view can scroll horizontally.
        let attrText = NSAttributedString(string: code, attributes: [.font: font])
        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = attrText.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        codeLabelWidthConstraint?.constant = ceil(boundingRect.width)
    }

    func applyHighlightedCode(_ highlighted: AttributedString) {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(highlighted))
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        codeLabel.attributedText = mutable

        // Re-measure content width after highlighting (font attributes may differ).
        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = mutable.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        codeLabelWidthConstraint?.constant = ceil(boundingRect.width)
    }

    @objc private func copyTapped() {
        copyCodeAndShowFeedback()
    }

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        copyCodeAndShowFeedback()
        showCopiedFlash()
    }

    private func copyCodeAndShowFeedback() {
        UIPasteboard.general.string = currentCode
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.7)

        // Brief "Copied" feedback on the copy button.
        copyButton.configuration?.image = UIImage(systemName: "checkmark")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            self.copyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: self)
    }
}

// MARK: - Native Table Block View

/// UIKit table rendered as a single attributed string in a horizontal scroll view.
///
/// Uses monospaced column alignment (like the diff view) for pixel-perfect
/// columns. Much tighter and better-looking than a stack-of-stacks approach.
final class NativeTableBlockView: UIView {

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let tableLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        // Prevent Auto Layout from compressing the label to the scroll frame width.
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }()

    /// Explicit width constraint for the label, updated in `apply()` to the
    /// measured content width so UIScrollView knows the content is wider than
    /// the frame and enables horizontal scrolling.
    private var tableLabelWidthConstraint: NSLayoutConstraint?

    /// Stored for long-press copy — rebuilt as markdown table text.
    private var currentHeaders: [String] = []
    private var currentRows: [[String]] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true

        addSubview(scrollView)
        scrollView.addSubview(tableLabel)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
        scrollView.addGestureRecognizer(longPress)

        let widthConstraint = tableLabel.widthAnchor.constraint(equalToConstant: 0)
        tableLabelWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tableLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            tableLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            tableLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            tableLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            // Height: lock content to frame (horizontal-only scroll).
            tableLabel.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            // Width: set explicitly from measured content so scroll view
            // knows content extends beyond its frame.
            widthConstraint,
        ])
    }

    func apply(headers: [String], rows: [[String]], palette: ThemePalette) {
        currentHeaders = headers
        currentRows = rows

        backgroundColor = UIColor(palette.bgDark)
        layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.35).cgColor
        let attrText = Self.makeTableAttributedText(
            headers: headers, rows: rows, palette: palette
        )
        tableLabel.attributedText = attrText

        // Measure content width so the scroll view can scroll horizontally.
        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = attrText.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        tableLabelWidthConstraint?.constant = ceil(boundingRect.width)
    }

    /// Monospaced column width of a string — counts emoji/CJK as 2 columns.
    ///
    /// `String.count` treats 🔴 as 1, but monospaced fonts render it ~2 chars wide.
    /// Uses the same heuristic as terminal column-width calculations (wcwidth-style).
    private static func monoColumnWidth(_ string: String) -> Int {
        var width = 0
        for scalar in string.unicodeScalars {
            let value = scalar.value
            switch value {
            // ASCII printable
            case 0x20...0x7E:
                width += 1
            // Common fullwidth / CJK ranges
            case 0x1100...0x115F, // Hangul Jamo
                 0x2E80...0x303E, // CJK Radicals, Kangxi, Ideographic
                 0x3041...0x33BF, // Hiragana, Katakana, CJK Compatibility
                 0x3400...0x4DBF, // CJK Unified Extension A
                 0x4E00...0x9FFF, // CJK Unified
                 0xA000...0xA4CF, // Yi
                 0xAC00...0xD7AF, // Hangul Syllables
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0xFE30...0xFE6F, // CJK Compatibility Forms
                 0xFF01...0xFF60, // Fullwidth Forms
                 0xFFE0...0xFFE6, // Fullwidth Signs
                 0x20000...0x2FFFF, // CJK Extension B+
                 0x30000...0x3FFFF: // CJK Extension G+
                width += 2
            // Emoji (Miscellaneous Symbols, Dingbats, Emoticons, Transport, Supplemental, etc.)
            case 0x2600...0x27BF, // Misc Symbols + Dingbats
                 0x1F300...0x1F9FF, // Emoji block
                 0x1FA00...0x1FA6F, // Chess Symbols / Extended-A
                 0x1FA70...0x1FAFF: // Extended-A continued
                width += 2
            // Variation selectors, zero-width joiners, etc. — zero width
            case 0xFE00...0xFE0F, 0x200D, 0x20E3:
                break
            default:
                width += 1
            }
        }
        return width
    }

    /// Pad a string to a target monospaced column width with spaces.
    private static func monoPad(_ string: String, toColumnWidth target: Int) -> String {
        let currentWidth = monoColumnWidth(string)
        let padding = max(0, target - currentWidth)
        return string + String(repeating: " ", count: padding)
    }

    private static func makeTableAttributedText(
        headers: [String],
        rows: [[String]],
        palette: ThemePalette
    ) -> NSAttributedString {
        let colCount = max(headers.count, rows.first?.count ?? 0)
        guard colCount > 0 else { return NSAttributedString() }

        // Compute column widths using monospaced column width (emoji = 2).
        var colWidths = [Int](repeating: 0, count: colCount)
        for (i, h) in headers.enumerated() where i < colCount {
            colWidths[i] = max(colWidths[i], monoColumnWidth(h))
        }
        for row in rows {
            for (i, cell) in row.enumerated() where i < colCount {
                colWidths[i] = max(colWidths[i], monoColumnWidth(cell))
            }
        }

        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 3

        let headerFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let cellFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let headerColor = UIColor(palette.cyan)
        let cellColor = UIColor(palette.fg)
        let dimColor = UIColor(palette.comment).withAlphaComponent(0.4)
        let headerBgColor = UIColor(palette.bgHighlight)
        let altRowBgColor = UIColor(palette.bgHighlight).withAlphaComponent(0.45)

        // Header row.
        let headerStart = result.length
        for (i, header) in headers.enumerated() {
            let padded = monoPad(header, toColumnWidth: colWidths[i])
            let prefix = i == 0 ? " " : " │ "
            result.append(NSAttributedString(string: prefix, attributes: [
                .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
            ]))
            result.append(NSAttributedString(string: padded, attributes: [
                .font: headerFont, .foregroundColor: headerColor, .paragraphStyle: paragraph,
            ]))
        }
        result.append(NSAttributedString(string: " ", attributes: [
            .font: cellFont, .paragraphStyle: paragraph,
        ]))
        let headerEnd = result.length
        result.addAttribute(
            .backgroundColor, value: headerBgColor,
            range: NSRange(location: headerStart, length: headerEnd - headerStart)
        )

        // Data rows.
        for (rowIdx, row) in rows.enumerated() {
            result.append(NSAttributedString(string: "\n"))
            let rowStart = result.length

            for i in 0..<colCount {
                let cell = i < row.count ? row[i] : ""
                let padded = monoPad(cell, toColumnWidth: colWidths[i])
                let prefix = i == 0 ? " " : " │ "
                result.append(NSAttributedString(string: prefix, attributes: [
                    .font: cellFont, .foregroundColor: dimColor, .paragraphStyle: paragraph,
                ]))
                result.append(NSAttributedString(string: padded, attributes: [
                    .font: cellFont, .foregroundColor: cellColor, .paragraphStyle: paragraph,
                ]))
            }
            result.append(NSAttributedString(string: " ", attributes: [
                .font: cellFont, .paragraphStyle: paragraph,
            ]))

            // Alternating row backgrounds.
            if rowIdx % 2 == 1 {
                let rowEnd = result.length
                result.addAttribute(
                    .backgroundColor, value: altRowBgColor,
                    range: NSRange(location: rowStart, length: rowEnd - rowStart)
                )
            }
        }

        return result
    }

    // MARK: - Long press to copy

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        UIPasteboard.general.string = markdownTableText()

        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.7)

        showCopiedFlash()
    }

    /// Reconstruct a markdown-formatted table for clipboard.
    private func markdownTableText() -> String {
        var lines: [String] = []

        let headerLine = "| " + currentHeaders.joined(separator: " | ") + " |"
        lines.append(headerLine)

        let separatorLine = "| " + currentHeaders.map { _ in "---" }.joined(separator: " | ") + " |"
        lines.append(separatorLine)

        for row in currentRows {
            let rowLine = "| " + row.joined(separator: " | ") + " |"
            lines.append(rowLine)
        }

        return lines.joined(separator: "\n")
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: self)
    }
}

// MARK: - Shared Copied Feedback

/// Show a flash overlay + floating "Copied" pill centered on the given view.
///
/// Used by `NativeCodeBlockView` and `NativeTableBlockView` for long-press copy.
private func showCopiedOverlay(on view: UIView) {
    let overlay = UIView()
    overlay.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    overlay.frame = view.bounds
    overlay.layer.cornerRadius = view.layer.cornerRadius
    overlay.isUserInteractionEnabled = false
    view.addSubview(overlay)

    let pill = CopiedPillView()
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pill)
    NSLayoutConstraint.activate([
        pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        pill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    pill.alpha = 0
    pill.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

    UIView.animate(withDuration: 0.15) {
        pill.alpha = 1
        pill.transform = .identity
    }

    UIView.animate(withDuration: 0.3, delay: 0.8, options: .curveEaseOut) {
        pill.alpha = 0
        pill.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        overlay.alpha = 0
    } completion: { _ in
        pill.removeFromSuperview()
        overlay.removeFromSuperview()
    }
}

/// Small floating "Copied" badge for long-press feedback.
private final class CopiedPillView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)

        let icon = UIImageView(image: UIImage(systemName: "checkmark"))
        icon.tintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 11, weight: .semibold
        )

        let label = UILabel()
        label.text = "Copied"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = UIColor.black.withAlphaComponent(0.75)
        layer.cornerRadius = 16
        isUserInteractionEnabled = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
