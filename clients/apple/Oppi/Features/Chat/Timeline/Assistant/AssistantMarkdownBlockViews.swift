import UIKit

/// A small header button that still takes a 44 pt touch: the hit area grows past the visible
/// bounds, as far as the views that hold it let a touch reach.
final class MinimumHitTargetButton: UIButton {
    private static let minimumHitTarget: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let horizontalInset = min(0, (bounds.width - Self.minimumHitTarget) / 2)
        let verticalInset = min(0, (bounds.height - Self.minimumHitTarget) / 2)
        return bounds.insetBy(dx: horizontalInset, dy: verticalInset).contains(point)
    }
}

/// Code block container with language badge, copy button, and syntax highlighting.
///
/// Owns highlight scheduling so parking this view off
/// `AssistantMarkdownSegmentApplier` (full-screen markdown reader) cannot
/// cancel color work. The applier only passes a scheduling policy.
final class NativeCodeBlockView: UIView {
    enum HighlightScheduling: Equatable, Sendable {
        case none
        case asynchronous
        case synchronous
    }

    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

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
        l.font = AppFont.mono
        l.lineBreakMode = .byTruncatingTail
        l.accessibilityIdentifier = "markdown.codeBlock.language"
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()

    private let wrapButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: CodeWrapControl.symbolName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = MinimumHitTargetButton(type: .system)
        button.configuration = config
        button.accessibilityIdentifier = "markdown.codeBlock.wrap"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }()

    /// Hidden until a host sets `onExpand`: only a host that can open the text full screen shows it.
    private let expandButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 10, weight: .regular
        )
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = MinimumHitTargetButton(type: .system)
        button.configuration = config
        button.isHidden = true
        button.accessibilityIdentifier = "markdown.codeBlock.expand"
        button.accessibilityLabel = String(localized: "Open full screen")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }()

    private let copyButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "doc.on.doc")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 10, weight: .regular
        )
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = MinimumHitTargetButton(type: .system)
        button.configuration = config
        button.accessibilityIdentifier = "markdown.codeBlock.copy"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }()

    private let codeScrollView: HorizontalPanPassthroughScrollView = {
        let sv = HorizontalPanPassthroughScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.alwaysBounceVertical = false
        sv.bounces = false
        sv.isDirectionalLockEnabled = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let codeLabel: BaselineSafeTextView = {
        let tv = BaselineSafeTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.accessibilityIdentifier = "markdown.codeBlock.text"
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return tv
    }()

    private let headerBackground = UIView()
    /// Compact blocks drop the language/wrap/copy header and tighten padding, so a
    /// capped preview shows the first lines of code instead of chrome.
    private var isCompact = false
    private var codeTopBelowHeader: NSLayoutConstraint?
    private var codeTopAtEdge: NSLayoutConstraint?
    private var labelInsetConstraints: [NSLayoutConstraint] = []
    private var labelHeightInset: NSLayoutConstraint?
    private var currentCode: String = ""
    private var currentLanguage: String?
    private var highlightedText: NSAttributedString?
    private var currentPalette: ThemePalette?
    private var currentThemeID: ThemeID = ThemeRuntimeState.currentThemeID()
    private var desiredHighlightIdentity: SyntaxHighlightIdentity?
    private var installedHighlightIdentity: SyntaxHighlightIdentity?
    private var highlightTask: Task<Void, Never>?
    private var isLineWrappingEnabled = false
    private var onExpand: (() -> Void)?
    private var measuredUnwrappedCodeWidth: CGFloat = 0
    /// Pretty-printed JSON shown while wrap is on. `currentCode` stays original.
    private var displayedPrettyJSON: String?
    private var prettyHighlightTask: Task<Void, Never>?
    #if DEBUG
    nonisolated(unsafe) static var highlightDelayForTesting: Duration?
    private(set) var debugHighlightWorkCountForTesting = 0
    #endif

    /// Horizontal padding around the text view inside `codeScrollView`.
    static let codeHorizontalPadding: CGFloat = 24

    /// Explicit width constraint for the label. In the default unwrapped mode it
    /// is the measured code width so the scroll view can pan horizontally. In
    /// wrap mode it tracks the visible viewport width so TextKit wraps lines.
    private var codeLabelWidthConstraint: NSLayoutConstraint?

    private lazy var longPressCopyGesture: UILongPressGestureRecognizer = {
        UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        highlightTask?.cancel()
        prettyHighlightTask?.cancel()
    }

    private func setupViews() {
        accessibilityIdentifier = "markdown.codeBlock"
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
        headerStack.addArrangedSubview(expandButton)
        headerStack.addArrangedSubview(wrapButton)
        headerStack.addArrangedSubview(copyButton)

        addSubview(codeScrollView)
        codeScrollView.addSubview(codeLabel)

        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        wrapButton.addTarget(self, action: #selector(wrapTapped), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        codeLabel.delegate = self
        codeScrollView.addGestureRecognizer(longPressCopyGesture)

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

            codeScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            widthConstraint,
        ])

        let belowHeader = codeScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6)
        let atEdge = codeScrollView.topAnchor.constraint(equalTo: topAnchor)
        codeTopBelowHeader = belowHeader
        codeTopAtEdge = atEdge
        belowHeader.isActive = true
        let heightInset = codeLabel.heightAnchor.constraint(equalTo: codeScrollView.frameLayoutGuide.heightAnchor, constant: -24)
        labelHeightInset = heightInset
        labelInsetConstraints = [
            codeLabel.topAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.topAnchor, constant: 12),
            codeLabel.leadingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            codeLabel.bottomAnchor.constraint(equalTo: codeScrollView.contentLayoutGuide.bottomAnchor, constant: -12),
        ]
        NSLayoutConstraint.activate(labelInsetConstraints + [heightInset])
    }

    private func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        headerBackground.isHidden = compact
        headerStack.isHidden = compact
        codeTopBelowHeader?.isActive = !compact
        codeTopAtEdge?.isActive = compact
        let inset: CGFloat = compact ? 8 : 12
        // top, leading, trailing, bottom
        let signs: [CGFloat] = [1, 1, -1, -1]
        for (constraint, sign) in zip(labelInsetConstraints, signs) {
            constraint.constant = sign * inset
        }
        labelHeightInset?.constant = -2 * inset
        invalidateIntrinsicContentSize()
    }

    /// Configure chrome for an embedded async-render placeholder whose code
    /// path may never call `apply` before the graphical result replaces it.
    func prepareForGraphicalPlaceholder() {
        updateWrapButton()
    }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        let selectionEnabled = router != nil && sourceContext != nil
        codeLabel.isSelectable = selectionEnabled
        longPressCopyGesture.isEnabled = !selectionEnabled
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isLineWrappingEnabled else { return }

        let width = wrappedCodeWidth()
        if abs((codeLabelWidthConstraint?.constant ?? 0) - width) > 0.5 {
            codeLabelWidthConstraint?.constant = width
            updateTextContainerForCurrentWrapping()
            codeLabel.invalidateIntrinsicContentSize()
        }
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        if isLineWrappingEnabled {
            let hasTargetWidth = targetSize.width.isFinite
                && targetSize.width > Self.codeHorizontalPadding
            let targetWidth = hasTargetWidth ? targetSize.width : nil
            let width = wrappedCodeWidth(availableWidth: targetWidth)
            if abs((codeLabelWidthConstraint?.constant ?? 0) - width) > 0.5 {
                codeLabelWidthConstraint?.constant = width
            }
            updateTextContainerForCurrentWrapping()
            codeLabel.invalidateIntrinsicContentSize()
        }

        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    // periphery:ignore:parameters isOpen
    func apply(
        language: String?,
        code: String,
        palette: ThemePalette,
        isOpen: Bool,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        highlightScheduling: HighlightScheduling = .none,
        isCompact compact: Bool = false
    ) {
        setCompact(compact)
        currentPalette = palette
        currentThemeID = themeID
        backgroundColor = palette.ui.bgDark
        headerBackground.backgroundColor = palette.ui.bgHighlight
        layer.borderColor = palette.ui.mdCodeBlockBorder.withAlphaComponent(0.5).cgColor

        languageLabel.text = language ?? "code"
        languageLabel.textColor = palette.ui.comment
        expandButton.tintColor = palette.ui.fgDim
        copyButton.tintColor = palette.ui.fgDim
        updateWrapButton()

        let prettyJSONBeforeApply = displayedPrettyJSON
        defer {
            if prettyJSONBeforeApply != displayedPrettyJSON {
                invalidateTimelineLayout()
            }
        }

        let identity = SyntaxHighlightIdentity(code: code, language: language, themeID: themeID)
        if desiredHighlightIdentity != identity {
            highlightTask?.cancel()
            highlightTask = nil
        }
        desiredHighlightIdentity = identity
        let font = AppFont.monoMedium

        if identity == installedHighlightIdentity, let highlighted = highlightedText {
            currentCode = code
            currentLanguage = language
            if isPrettyJSONDisplayActive {
                _ = presentPrettyJSONIfEligible(recolor: false)
            } else {
                codeLabel.attributedText = highlighted
            }
            applyCurrentLineWrapping(resetHorizontalOffset: false)
            return
        }

        let contentChanged = code != currentCode || language != currentLanguage
        currentCode = code
        currentLanguage = language

        if contentChanged || highlightedText == nil {
            highlightedText = nil
            installedHighlightIdentity = nil
            if !presentPrettyJSONIfEligible(recolor: false) {
                codeLabel.font = font
                codeLabel.textColor = palette.ui.fg
                if isDiff(language) {
                    let plain = NSMutableAttributedString(string: code, attributes: [
                        .font: font,
                        .foregroundColor: palette.ui.fg,
                    ])
                    Self.paintDiffLines(in: plain, palette: palette)
                    codeLabel.attributedText = plain
                } else {
                    codeLabel.attributedText = nil
                    codeLabel.text = code
                }
            }
            updateMeasuredCodeWidth(NSAttributedString(string: code, attributes: [.font: font]))
        } else {
            if isLineWrappingEnabled {
                _ = presentPrettyJSONIfEligible(recolor: true)
            }
            applyCurrentLineWrapping(resetHorizontalOffset: false)
        }

        scheduleHighlightIfNeeded(scheduling: highlightScheduling)
    }

    private func isDiff(_ language: String?) -> Bool {
        language.map { SyntaxLanguage.detect($0) == .diff } ?? false
    }

    /// Added and removed lines of a `diff` block take the theme's diff colors
    /// (the ones the edit-tool diff uses), over whatever the highlighter painted.
    /// File headers (`+++` / `---`) keep the highlighter's colors.
    private static func paintDiffLines(in text: NSMutableAttributedString, palette: ThemePalette) {
        let added = palette.ui.diffAdded
        let removed = palette.ui.diffRemoved
        let source = text.string as NSString
        source.enumerateSubstrings(
            in: NSRange(location: 0, length: source.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            guard range.length > 0 else { return }
            let line = source.substring(with: range)
            let color: UIColor
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                color = added
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                color = removed
            } else {
                return
            }
            text.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    var hasCurrentHighlight: Bool {
        installedHighlightIdentity == desiredHighlightIdentity && highlightedText != nil
    }

    func applyHighlightedCode(
        _ highlighted: NSAttributedString,
        identity: SyntaxHighlightIdentity
    ) {
        guard identity == desiredHighlightIdentity else { return }

        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let font = AppFont.monoMedium
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        if isDiff(currentLanguage), let currentPalette {
            Self.paintDiffLines(in: mutable, palette: currentPalette)
        }
        highlightedText = mutable
        installedHighlightIdentity = identity

        if isPrettyJSONDisplayActive {
            let maxSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            let boundingRect = mutable.boundingRect(
                with: maxSize,
                options: [.usesLineFragmentOrigin],
                context: nil
            )
            measuredUnwrappedCodeWidth = max(1, ceil(boundingRect.width))
            return
        }

        codeLabel.attributedText = mutable
        updateMeasuredCodeWidth(mutable)
    }

    private func scheduleHighlightIfNeeded(scheduling: HighlightScheduling) {
        guard scheduling != .none else { return }
        guard let language = currentLanguage else { return }
        let syntaxLang = SyntaxLanguage.detect(language)
        guard syntaxLang != .unknown else { return }
        guard let identity = desiredHighlightIdentity else { return }
        guard !hasCurrentHighlight else { return }
        if let highlightTask, !highlightTask.isCancelled {
            return
        }

        let code = currentCode
        let themeID = identity.themeID
        #if DEBUG
        debugHighlightWorkCountForTesting += 1
        #endif

        if scheduling == .synchronous {
            applyHighlightedCode(
                SyntaxHighlighter.highlight(code, language: syntaxLang, themeID: themeID),
                identity: identity
            )
            return
        }

        highlightTask = Task { [weak self] in
            #if DEBUG
            if let delay = Self.highlightDelayForTesting {
                try? await Task.sleep(for: delay)
            }
            #endif
            guard !Task.isCancelled else { return }
            let wrapper = await Task.detached(priority: .userInitiated) {
                SendableNSAttributedString(
                    SyntaxHighlighter.highlight(code, language: syntaxLang, themeID: themeID)
                )
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.applyHighlightedCode(wrapper.value, identity: identity)
            }
        }
    }

    @objc private func wrapTapped() {
        isLineWrappingEnabled.toggle()
        updateWrapButton()
        if isLineWrappingEnabled {
            _ = presentPrettyJSONIfEligible(recolor: false)
        } else {
            restoreOriginalCodeIfPrettyWasShowing()
        }
        applyCurrentLineWrapping(resetHorizontalOffset: true)
        invalidateTimelineLayout()
    }

    /// Shows the header's expand button, which runs `action`, or hides it for nil. A host that
    /// can open this block's text full screen sets it; `identifier` scopes the button to the block.
    func configureExpand(identifier: String?, action: (() -> Void)?) {
        onExpand = action
        expandButton.isHidden = action == nil
        expandButton.accessibilityIdentifier = identifier ?? "markdown.codeBlock.expand"
    }

    @objc private func expandTapped() {
        onExpand?()
    }

    @objc private func copyTapped() {
        copyCodeAndShowFeedback()
    }

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        copyCodeAndShowFeedback()
        showCopiedFlash()
    }

    private var isPrettyJSONDisplayActive: Bool {
        displayedPrettyJSON != nil && isLineWrappingEnabled
    }

    private func isJSONFenceLanguage(_ language: String?) -> Bool {
        language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "json"
    }

    private func prettyJSONForCurrentSource() -> String? {
        guard isLineWrappingEnabled, isJSONFenceLanguage(currentLanguage) else { return nil }
        return JSONPrettyPrinter.prettyPrinted(currentCode)
    }

    @discardableResult
    private func presentPrettyJSONIfEligible(recolor: Bool) -> Bool {
        guard let pretty = prettyJSONForCurrentSource() else {
            restoreOriginalCodeIfPrettyWasShowing()
            return false
        }
        let alreadyShowing = displayedPrettyJSON == pretty
            && (codeLabel.attributedText?.string == pretty || codeLabel.text == pretty)
        displayedPrettyJSON = pretty
        if !alreadyShowing || recolor {
            presentPrettyJSON(pretty)
        }
        return true
    }

    private func presentPrettyJSON(_ pretty: String) {
        prettyHighlightTask?.cancel()
        let font = AppFont.monoMedium
        let palette = currentPalette ?? ThemeRuntimeState.currentPalette()
        codeLabel.font = font
        codeLabel.textColor = palette.ui.fg
        codeLabel.attributedText = nil
        codeLabel.text = pretty

        let themeID = currentThemeID
        prettyHighlightTask = Task { @MainActor [weak self] in
            let wrapper = await Task.detached(priority: .userInitiated) {
                SendableNSAttributedString(
                    SyntaxHighlighter.highlight(pretty, language: .json, themeID: themeID)
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.installPrettyJSONHighlight(wrapper.value, pretty: pretty)
        }
    }

    private func installPrettyJSONHighlight(_ highlighted: NSAttributedString, pretty: String) {
        guard isLineWrappingEnabled, displayedPrettyJSON == pretty else { return }
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let font = AppFont.monoMedium
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        codeLabel.attributedText = mutable
        applyCurrentLineWrapping(resetHorizontalOffset: false)
    }

    private func restoreOriginalCodeIfPrettyWasShowing() {
        guard displayedPrettyJSON != nil else { return }
        prettyHighlightTask?.cancel()
        prettyHighlightTask = nil
        displayedPrettyJSON = nil

        let font = AppFont.monoMedium
        if let highlighted = highlightedText,
           installedHighlightIdentity == desiredHighlightIdentity {
            codeLabel.attributedText = highlighted
        } else if let palette = currentPalette {
            codeLabel.font = font
            codeLabel.textColor = palette.ui.fg
            codeLabel.attributedText = nil
            codeLabel.text = currentCode
        } else {
            codeLabel.attributedText = nil
            codeLabel.text = currentCode
        }
    }

    private func copyCodeAndShowFeedback() {
        UIPasteboard.general.string = currentCode
        AppHaptics.impact(style: .light, intensity: 0.7)

        copyButton.configuration?.image = UIImage(systemName: "checkmark")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            self.copyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    private func updateMeasuredCodeWidth(_ text: NSAttributedString) {
        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = text.boundingRect(with: maxSize, options: [.usesLineFragmentOrigin], context: nil)
        measuredUnwrappedCodeWidth = max(1, ceil(boundingRect.width))
        applyCurrentLineWrapping(resetHorizontalOffset: false)
    }

    private func applyCurrentLineWrapping(resetHorizontalOffset: Bool) {
        codeLabel.textContainer.lineBreakMode = isLineWrappingEnabled ? .byCharWrapping : .byClipping
        codeScrollView.isScrollEnabled = !isLineWrappingEnabled
        codeScrollView.alwaysBounceHorizontal = false
        codeScrollView.showsHorizontalScrollIndicator = false
        codeLabelWidthConstraint?.constant = isLineWrappingEnabled ? wrappedCodeWidth() : measuredUnwrappedCodeWidth
        updateTextContainerForCurrentWrapping()

        if resetHorizontalOffset {
            codeScrollView.setContentOffset(.zero, animated: false)
        }

        codeLabel.invalidateIntrinsicContentSize()
        codeScrollView.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func updateTextContainerForCurrentWrapping() {
        codeLabel.textContainer.widthTracksTextView = isLineWrappingEnabled
        codeLabel.textContainer.size = isLineWrappingEnabled
            ? CGSize(
                width: max(1, codeLabelWidthConstraint?.constant ?? wrappedCodeWidth()),
                height: CGFloat.greatestFiniteMagnitude
            )
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeLabel.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: codeLabel.textStorage.length),
            actualCharacterRange: nil
        )
        codeLabel.layoutManager.ensureLayout(for: codeLabel.textContainer)
    }

    private func wrappedCodeWidth(availableWidth explicitAvailableWidth: CGFloat? = nil) -> CGFloat {
        let availableWidth = explicitAvailableWidth
            ?? [codeScrollView.bounds.width, bounds.width, superview?.bounds.width ?? 0]
                .first(where: { $0 > Self.codeHorizontalPadding })
            ?? 320
        return max(1, availableWidth - Self.codeHorizontalPadding)
    }

    private func updateWrapButton() {
        let palette = currentPalette ?? ThemeRuntimeState.currentPalette()
        var config = wrapButton.configuration ?? .plain()
        config.title = nil
        config.image = UIImage(systemName: CodeWrapControl.symbolName)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .regular
        )
        config.baseForegroundColor = isLineWrappingEnabled ? palette.ui.blue : palette.ui.fgDim
        config.background.backgroundColor = isLineWrappingEnabled
            ? palette.ui.blue.withAlphaComponent(0.14)
            : .clear
        config.background.cornerRadius = 8
        wrapButton.configuration = config
        wrapButton.accessibilityLabel = isLineWrappingEnabled ? "Unwrap code lines" : "Wrap code lines"
        wrapButton.accessibilityValue = isLineWrappingEnabled ? "On" : "Off"
    }

    private func invalidateTimelineLayout() {
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: self)
    }
}

#if DEBUG
struct NativeCodeBlockLayoutDiagnostics {
    let wrapsLines: Bool
    let headerTopInset: CGFloat
    let headerHeight: CGFloat
    let codeTopInset: CGFloat
    let headerToCodeGap: CGFloat
}

extension NativeCodeBlockView {
    var debugHasHighlightedTextForTesting: Bool { highlightedText != nil }

    func debugCancelHighlightTaskForTesting() {
        highlightTask?.cancel()
        highlightTask = nil
    }

    var debugWrapButtonAccessibilityLabelForTesting: String? {
        wrapButton.accessibilityLabel
    }

    var debugWrapButtonAccessibilityValueForTesting: String? {
        wrapButton.accessibilityValue
    }

    func layoutDiagnosticsForTesting() -> NativeCodeBlockLayoutDiagnostics {
        layoutIfNeeded()
        let headerFrame = headerStack.convert(headerStack.bounds, to: self)
        let codeFrame = codeScrollView.convert(codeScrollView.bounds, to: self)
        return NativeCodeBlockLayoutDiagnostics(
            wrapsLines: isLineWrappingEnabled,
            headerTopInset: headerFrame.minY,
            headerHeight: headerFrame.height,
            codeTopInset: codeFrame.minY,
            headerToCodeGap: codeFrame.minY - headerFrame.maxY
        )
    }
}
#endif

extension NativeCodeBlockView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

/// UIKit markdown table.
///
/// Default path keeps monospaced single-line columns with horizontal scroll
/// (pixel-aligned via tab stops). Grid mode is used when a column's natural
/// width exceeds the readable clamp, or when wrapping lets a too-wide table fit
/// the viewport (`MarkdownTableColumnLayout.plan`); a table that cannot fit
/// scrolls sideways. `TableChrome` adds the overflow cue and the fold bar.
final class NativeTableBlockView: UIView {
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?
    private var resourceReferenceServerID: String?
    private var resourceReferenceWorkspaceID: String?

    /// Inner card that wraps the scroll view. Carries the background, border,
    /// and corner radius so it shrink-wraps to content width while the outer
    /// view (sized by SwiftUI) can be full-width and transparent.
    private let cardView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 8
        v.layer.borderWidth = 1
        v.clipsToBounds = true
        return v
    }()

    private let scrollView: HorizontalPanPassthroughScrollView = {
        let sv = HorizontalPanPassthroughScrollView()
        sv.showsHorizontalScrollIndicator = true
        sv.alwaysBounceVertical = false
        sv.bounces = false
        sv.isDirectionalLockEnabled = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let tableLabel: BaselineSafeTextView = {
        // TextKit 1: a streamed table appends rows to the text, and its layout
        // manager lays out only the appended glyphs. TextKit 2 lays out the whole
        // table again on every append.
        let tv = BaselineSafeTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        // Scrolling on, but never scrolled: a text view that does not scroll has
        // an intrinsic size, and every fit of the chat row measures it, which
        // lays out the whole table each streaming tick. The table sizes the
        // label from `MarkdownTableClipText` instead.
        tv.isScrollEnabled = true
        tv.isScrollingOnlyForSizing = true
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.scrollsToTop = false
        tv.bounces = false
        tv.isSelectable = false
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.backgroundColor = .clear
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return tv
    }()

    /// Multi-line grid used when any column clamps to `maxReadable`, drawn as
    /// one view. Lives inside `scrollView` so a wide grid can pan horizontally.
    private let gridView: MarkdownTableGridView = {
        let view = MarkdownTableGridView()
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// Explicit width constraint for the label, updated in `apply()` to the
    /// measured content width so UIScrollView knows the content is wider than
    /// the frame and enables horizontal scrolling.
    private var tableLabelWidthConstraint: NSLayoutConstraint?

    /// Card width constraint — shrinks to content or expands to parent width,
    /// whichever is smaller.
    private var cardWidthConstraint: NSLayoutConstraint?

    /// Explicit grid width (sum of clamped columns + gaps + insets). This is the
    /// scroller content width; the grid is not pinned to the card trailing edge.
    private var gridViewWidthConstraint: NSLayoutConstraint?
    private var tableLabelContentConstraints: [NSLayoutConstraint] = []
    private var gridViewContentConstraints: [NSLayoutConstraint] = []

    /// The overflow cue over the scroller and the "Show all N rows" bar under it.
    private lazy var chrome = TableChrome(
        card: cardView,
        scrollView: scrollView,
        open: { [unowned self] in openFullScreen() },
        copy: { [unowned self] in copyTable($0) }
    )

    /// Stored for long-press copy — rebuilt as markdown table text.
    private var currentHeaders: [[MarkdownInline]] = []
    /// The rows drawn: `fullRows`, or its first `rowFoldLimit` rows when folded.
    private var currentRows: [[[MarkdownInline]]] = []
    /// Every row, drawn or not: what copy and the full-screen viewer take.
    private var fullRows: [[[MarkdownInline]]] = []
    static let chatFoldRowLimit = 20
    /// Rows past this many fold behind "Show all N rows"; nil never folds.
    var rowFoldLimit: Int?
    /// The width the owner expects to lay this table out at, used until the view
    /// has a width of its own, so it is not drawn for one width and then redrawn.
    var availableWidthHint: CGFloat?
    /// The column widths, the plan on screen, and the width it was made for.
    private var planning = TablePlanning()
    /// Right edge of each column in scroller content coordinates.
    private var columnTrailingEdges: [CGFloat] = []
    private var currentPalette: ThemePalette?
    /// Whether any cell contains a link (enables text view selectability for taps).
    private var hasLinks = false
    private var isWrapMode = false
    /// `systemLayoutSizeFitting` and `intrinsicContentSize` both measure the
    /// wrap grid. Re-entering that solve from a nested text-view layout pass
    /// overflows the main-thread stack on wide document-reader tables.
    private var isMeasuringLayout = false
    private var lastMeasuredHeight: CGFloat = 1
    /// Height of the rendered body, valid until the body changes. The chat row
    /// measures every table on each streaming tick; re-measuring a finished
    /// table there would make every tick cost O(all table cells).
    private var cachedTableHeight: CGFloat?

    private enum RenderedMode {
        case clip
        case wrap
    }

    /// Nil until the first render.
    private var renderedMode: RenderedMode?
    /// How the wrap grid was drawn. While the grid shows `currentRows`, a
    /// streamed table grows a row at a time: when the columns, header, style,
    /// and display scale hold, only rows past the unchanged prefix are built, so
    /// a tick costs O(new rows) instead of O(table).
    private var renderedWrapColumnWidths: [CGFloat] = []
    private var renderedWrapStyle: MarkdownTableGridStyle?
    /// The clip-mode text on screen, and the height of its laid-out text.
    private var clipText: MarkdownTableClipText?
    private var clipTextHeight: CGFloat = 0
    /// Measured widths of `currentHeaders` and of each row of `currentRows`,
    /// kept so a tick only measures rows that changed. Valid for the fonts they
    /// were measured in.
    private var measuredHeaderWidths: [CellWidth] = []
    private var measuredRowWidths: [[CellWidth]] = []
    private var measuredFonts: [UIFont] = []

    private lazy var longPressCopyGesture: UILongPressGestureRecognizer = {
        UILongPressGestureRecognizer(target: self, action: #selector(longPressCopy(_:)))
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "markdown.table"
        setupViews()
        // Row heights are rounded to the display's pixel grid. A table measured
        // before it is on screen rounds to whole points; measure it again once
        // the real scale is known.
        registerForTraitChanges([UITraitDisplayScale.self, UITraitUserInterfaceStyle.self]) { (table: Self, _: UITraitCollection) in
            table.rebuildWrapGridForTraits()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        backgroundColor = .clear

        addSubview(cardView)
        cardView.addSubview(scrollView)
        scrollView.addSubview(tableLabel)
        scrollView.addSubview(gridView)

        tableLabel.delegate = self
        tableLabel.copyTextProvider = { TableSelectionText.text(in: $0, range: $1) }
        scrollView.delegate = self
        gridView.cellTextViewDelegate = self
        gridView.onOpenLink = { [weak self] url, view in
            self?.openLink(url, from: view)
        }
        cardView.addGestureRecognizer(longPressCopyGesture)

        let labelWidthConstraint = tableLabel.widthAnchor.constraint(equalToConstant: 0)
        tableLabelWidthConstraint = labelWidthConstraint

        let cardWidth = cardView.widthAnchor.constraint(equalTo: widthAnchor)
        cardWidthConstraint = cardWidth

        let gridWidth = gridView.widthAnchor.constraint(equalToConstant: 0)
        gridViewWidthConstraint = gridWidth

        tableLabelContentConstraints = [
            tableLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            tableLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            tableLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            tableLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            tableLabel.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            labelWidthConstraint,
        ]

        // The grid draws its own padding, so it fills the scroller content.
        gridViewContentConstraints = [
            gridView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            gridView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            gridWidth,
        ]

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidth,

            scrollView.topAnchor.constraint(equalTo: cardView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
        ])
        chrome.install { [unowned self] in updateOverflowCue() }
        NSLayoutConstraint.activate(tableLabelContentConstraints)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        scrollView.flashScrollIndicators()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if replanIfNeeded(forWidth: bounds.width) {
            notifyHeightMayHaveChanged()
            super.layoutSubviews()
        }
        updateCardWidth()
        updateOverflowCue()
    }

    private func updateOverflowCue() {
        let visible = scrollView.bounds.width
        chrome.updateCue(visibleMaxX: scrollView.contentOffset.x + visible, contentWidth: currentContentWidth(), trailingEdges: columnTrailingEdges)
    }

    /// UIScrollView has no useful intrinsic height. Measure the active table
    /// body so chat self-sizing cannot clip the last wrapped row.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: cachedOrMeasureTableHeight())
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width.isFinite && targetSize.width > 0
            ? targetSize.width
            : max(1, bounds.width)
        // The height depends on the width the columns are fit to: plan for the
        // width being measured, not the last one laid out.
        if replanIfNeeded(forWidth: width) { cachedTableHeight = nil }
        return CGSize(width: width, height: cachedOrMeasureTableHeight())
    }

    private func cachedOrMeasureTableHeight() -> CGFloat {
        if let cachedTableHeight {
            return cachedTableHeight
        }
        if isMeasuringLayout {
            return lastMeasuredHeight
        }
        isMeasuringLayout = true
        defer { isMeasuringLayout = false }
        let height = measuredTableHeight()
        lastMeasuredHeight = height
        cachedTableHeight = height
        return height
    }

    private func measuredTableHeight() -> CGFloat {
        scrollerHeight() + chrome.footerHeight
    }

    /// Height of the rows, without the fold footer.
    private func scrollerHeight() -> CGFloat {
        if isWrapMode {
            return max(1, ceil(gridView.layout?.contentHeight ?? 0))
        }

        // The label scrolls, so it has no intrinsic height to fall back on.
        return max(1, clipTextHeight + tableLabel.textContainerInset.top + tableLabel.textContainerInset.bottom)
    }

    /// Card width is min(contentWidth, bounds.width) in both clip and grid mode.
    private func updateCardWidth() {
        guard let constraint = cardWidthConstraint else { return }
        let parentWidth = bounds.width
        let contentWidth = currentContentWidth()

        if contentWidth > 0, parentWidth > 0, contentWidth < parentWidth {
            if constraint.firstAnchor === cardView.widthAnchor,
               constraint.secondAnchor === widthAnchor {
                constraint.isActive = false
                let absolute = cardView.widthAnchor.constraint(equalToConstant: contentWidth)
                cardWidthConstraint = absolute
                absolute.isActive = true
            } else {
                constraint.constant = contentWidth
            }
        } else {
            setCardWidthRelativeToParent(constraint)
        }
    }

    private func currentContentWidth() -> CGFloat {
        if isWrapMode {
            return gridViewWidthConstraint?.constant ?? 0
        }
        return tableLabelWidthConstraint?.constant ?? 0
    }

    private func setCardWidthRelativeToParent(_ constraint: NSLayoutConstraint) {
        if constraint.firstAnchor === cardView.widthAnchor,
           constraint.secondAnchor === widthAnchor {
            return
        }
        constraint.isActive = false
        let relative = cardView.widthAnchor.constraint(equalTo: widthAnchor)
        cardWidthConstraint = relative
        relative.isActive = true
    }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        let selectionEnabled = router != nil && sourceContext != nil
        tableLabel.isSelectable = selectionEnabled
        gridView.isInteractive = selectionEnabled || hasLinks
        longPressCopyGesture.isEnabled = !selectionEnabled
    }

    func configureResourceReferenceScope(serverID: String?, workspaceID: String?) {
        resourceReferenceServerID = serverID
        resourceReferenceWorkspaceID = workspaceID
    }

    #if DEBUG
    /// Applies that measured, laid out, and drew; one that changed nothing adds none.
    private(set) var debugRenderCountForTesting = 0
    var debugGridViewForTesting: MarkdownTableGridView { gridView }
    var debugClipTextForTesting: NSAttributedString? { tableLabel.attributedText }
    var debugMeasuredHeightForTesting: CGFloat { cachedOrMeasureTableHeight() }
    #endif

    func apply(headers: [[MarkdownInline]], rows allRows: [[[MarkdownInline]]], palette: ThemePalette) {
        fullRows = allRows
        let rows = rowFoldLimit.map { allRows.count > $0 ? Array(allRows.prefix($0)) : allRows } ?? allRows
        let headerChanged = renderedMode == nil || headers != currentHeaders
        let unchangedRows = Self.commonPrefixCount(currentRows, rows)
        let contentChanged = headerChanged
            || unchangedRows != rows.count
            || unchangedRows != currentRows.count

        let fonts = [AppFont.monoMediumBold, AppFont.monoMedium]
        let fontsChanged = fonts != measuredFonts
        // A streaming tick that finished no row applies the same table again.
        // Nothing to measure, lay out, or draw.
        if !contentChanged, !fontsChanged, currentPalette?.uiCache === palette.uiCache {
            // Same rows, but the hidden ones may have grown, and the width the
            // table is laid out at may have changed the plan.
            refreshChromeAndPlan(palette: palette)
            return
        }
        #if DEBUG
        debugRenderCountForTesting += 1
        #endif

        if fontsChanged {
            measuredFonts = fonts
            measuredRowWidths = []
            measuredHeaderWidths = Self.naturalCellWidths(headers, font: AppFont.monoMediumBold)
            clipText = nil
        } else if headerChanged {
            measuredHeaderWidths = Self.naturalCellWidths(headers, font: AppFont.monoMediumBold)
        }
        let measuredRows = min(unchangedRows, measuredRowWidths.count)
        measuredRowWidths.removeSubrange(measuredRows...)
        for row in rows[measuredRows...] {
            measuredRowWidths.append(Self.naturalCellWidths(row, font: AppFont.monoMedium))
        }

        currentHeaders = headers
        currentRows = rows
        currentPalette = palette

        // Detect links in any cell for selectability.
        hasLinks = Self.containsLink(headers) || rows.contains { Self.containsLink($0) }
        updateGridInteractivity()

        cardView.backgroundColor = palette.ui.bgDark
        cardView.layer.borderColor = palette.ui.mdCodeBlockBorder.withAlphaComponent(0.5).cgColor

        planning.natural = Self.naturalColumnMetrics(
            headerWidths: measuredHeaderWidths,
            rowWidths: measuredRowWidths,
            columnCount: Self.columnCount(headers: headers, rows: rows)
        )

        // Only snap horizontal offset when the table body actually changed.
        if contentChanged {
            scrollView.contentOffset = .zero
        }
        let foldChanged = chrome.update(shownRows: rows.count, totalRows: allRows.count, palette: palette)

        // Mode and column widths come from the content and the layout width; a
        // later width change re-plans in `replanIfNeeded`.
        let previousMode = isWrapMode
        let plan = planning.plan(width: bounds.width, hint: availableWidthHint, displayScale: traitCollection.displayScale)
        let force = contentChanged || plan != planning.rendered
        render(plan, palette: palette, force: force, keptRows: headerChanged ? nil : unchangedRows)

        if previousMode != isWrapMode || foldChanged {
            notifyHeightMayHaveChanged()
        }
        updateCardWidth()
        setNeedsLayout()
        // Do not `layoutIfNeeded()` here. The document reader measures this
        // view inside a collection-view layout pass; a nested layout re-enters
        // `cellForItem`, reuses table cells, and overflows the main thread.
    }

    private func refreshChromeAndPlan(palette: ThemePalette) {
        let foldChanged = chrome.update(shownRows: currentRows.count, totalRows: fullRows.count, palette: palette)
        let plan = planning.plan(width: bounds.width, hint: availableWidthHint, displayScale: traitCollection.displayScale)
        if plan != planning.rendered { render(plan, palette: palette, force: true, keptRows: nil) }
        if foldChanged { notifyHeightMayHaveChanged() }
    }

    private func render(_ plan: MarkdownTableColumnLayout.Plan, palette: ThemePalette, force: Bool, keptRows: Int?) {
        switch plan.presentation {
        case .grid:
            renderWrapMode(columnWidths: plan.columnWidths, palette: palette, force: force, keptRows: keptRows)
        case .clip:
            renderClipMode(columnWidths: plan.columnWidths, palette: palette, force: force, keptRows: keptRows)
        }
        if force { columnTrailingEdges = MarkdownTableColumnLayout.trailingEdges(for: plan) }
        planning.rendered = plan
    }

    /// The viewport changed: redraw if the columns plan differently for `width`,
    /// and say so, because wrapped rows are as tall as the columns are narrow.
    @discardableResult
    private func replanIfNeeded(forWidth width: CGFloat) -> Bool {
        guard let palette = currentPalette,
              let plan = planning.replan(forWidth: width, displayScale: traitCollection.displayScale)
        else { return false }
        render(plan, palette: palette, force: true, keptRows: nil)
        return true
    }

    private func updateGridInteractivity() {
        gridView.isInteractive = hasLinks
            || (reviewCommentSelectionRouter != nil && reviewCommentSourceContext != nil)
    }

    private func notifyHeightMayHaveChanged() {
        cachedTableHeight = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingStreamingHeightCache(startingAt: self)
    }

    private func renderClipMode(
        columnWidths: [CGFloat],
        palette: ThemePalette,
        force: Bool,
        keptRows: Int?
    ) {
        let modeChanged = isWrapMode
        if !force, renderedMode == .clip {
            return
        }

        isWrapMode = false
        tableLabel.isHidden = false
        gridView.isHidden = true
        NSLayoutConstraint.deactivate(gridViewContentConstraints)
        NSLayoutConstraint.activate(tableLabelContentConstraints)
        if modeChanged {
            gridView.clear()
            renderedWrapStyle = nil
        }

        if hasLinks || (reviewCommentSelectionRouter != nil && reviewCommentSourceContext != nil) {
            tableLabel.isSelectable = true
        } else {
            tableLabel.isSelectable = false
        }

        // Same columns and colors as the text on screen: a streamed table grows
        // a row at a time, so only the rows past the unchanged prefix are built
        // and laid out.
        if renderedMode == .clip,
           let keptRows,
           let clipText,
           clipText.columnWidths == columnWidths,
           clipText.paletteIdentity == ObjectIdentifier(palette.uiCache) {
            let edit = clipText.replaceRows(keeping: keptRows, with: currentRows)
            let storage = tableLabel.textStorage
            storage.beginEditing()
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            storage.endEditing()
        } else {
            let text = MarkdownTableClipText(
                headers: currentHeaders,
                columnWidths: columnWidths,
                palette: palette
            )
            text.replaceRows(keeping: 0, with: currentRows)
            clipText = text
            tableLabel.attributedText = NSAttributedString(attributedString: text.storage)
            // Underlines live on the link runs so file links can omit them.
            tableLabel.linkTextAttributes = [
                .foregroundColor: palette.ui.blue,
            ]
        }

        let size = clipText?.measuredSize ?? .zero
        tableLabelWidthConstraint?.constant = ceil(size.width)
        clipTextHeight = ceil(size.height)
        renderedMode = .clip
        if modeChanged || force {
            notifyHeightMayHaveChanged()
        }
    }

    private func renderWrapMode(
        columnWidths: [CGFloat],
        palette: ThemePalette,
        force: Bool,
        keptRows: Int?
    ) {
        if !force, renderedMode == .wrap {
            return
        }

        let style = MarkdownTableGridStyle(palette: palette, traits: traitCollection)
        let scale = max(traitCollection.displayScale, 1)

        // Kept rows were laid out for these columns, header, colors, fonts, and
        // pixel grid; any other change builds the whole grid again.
        if renderedMode == .wrap,
           let keptRows,
           columnWidths == renderedWrapColumnWidths,
           style == renderedWrapStyle,
           var layout = gridView.layout,
           layout.scale == scale {
            layout.replaceBodyRows(keeping: keptRows, with: currentRows)
            gridView.setLayout(layout)
            gridViewWidthConstraint?.constant = layout.contentWidth
            notifyHeightMayHaveChanged()
            return
        }

        isWrapMode = true
        tableLabel.isHidden = true
        gridView.isHidden = false
        NSLayoutConstraint.deactivate(tableLabelContentConstraints)
        NSLayoutConstraint.activate(gridViewContentConstraints)
        tableLabel.attributedText = nil
        tableLabelWidthConstraint?.constant = 0
        clipText = nil
        clipTextHeight = 0

        let layout = MarkdownTableGridLayout(
            headers: currentHeaders,
            rows: currentRows,
            columnWidths: columnWidths,
            style: style,
            scale: scale
        )
        gridView.linkTextColor = style.link
        gridView.setLayout(layout)
        gridViewWidthConstraint?.constant = layout.contentWidth

        renderedMode = .wrap
        renderedWrapColumnWidths = columnWidths
        renderedWrapStyle = style
        notifyHeightMayHaveChanged()
    }

    /// The display scale or appearance changed: colors and pixel rounding are
    /// resolved against them, so a drawn grid builds again.
    private func rebuildWrapGridForTraits() {
        guard renderedMode == .wrap, let palette = currentPalette else {
            notifyHeightMayHaveChanged()
            return
        }
        renderWrapMode(
            columnWidths: renderedWrapColumnWidths,
            palette: palette,
            force: true,
            keptRows: nil
        )
    }

    private static func commonPrefixCount(
        _ lhs: [[[MarkdownInline]]],
        _ rhs: [[[MarkdownInline]]]
    ) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    /// Opens a link from a drawn cell (a VoiceOver activation): the same
    /// request a tap on the link in a text view makes.
    private func openLink(_ url: URL, from view: UIView) {
        AppRootEnvironment.near(view)?.opener.open(classifyLink(url) ?? .system(url))
    }

    private static func containsLink(_ cells: [[MarkdownInline]]) -> Bool {
        cells.contains { containsLink($0) }
    }

    private static func containsLink(_ inlines: [MarkdownInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .link:
                return true
            case .emphasis(let children),
                 .strong(let children),
                 .strikethrough(let children):
                return containsLink(children)
            case .text, .code, .image, .videoEmbed, .audioEmbed, .usdzEmbed, .softBreak, .hardBreak, .html:
                return false
            }
        }
    }

    /// Measure the actual rendered width of a string in the given font.
    /// Correctly handles CJK, emoji, and mixed-script text via real metrics.
    static func measuredTextWidth(_ string: String, font: UIFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func columnCount(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    ) -> Int {
        max(headers.count, rows.first?.count ?? 0)
    }

    /// One cell's single-line width and its longest unbreakable word, in characters.
    private struct CellWidth {
        let natural: CGFloat
        let wordLength: Int
    }

    private static func naturalCellWidths(_ cells: [[MarkdownInline]], font: UIFont) -> [CellWidth] {
        cells.map { cell in
            let text = plainText(from: cell)
            return CellWidth(
                natural: measuredTextWidth(text, font: font),
                wordLength: MarkdownTableColumnLayout.longestUnbreakableLength(text)
            )
        }
    }

    /// Natural single-line column metrics used to choose clip vs grid.
    static func measureNaturalColumns(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]]
    ) -> MarkdownTableColumnLayout.NaturalColumns {
        naturalColumnMetrics(
            headerWidths: naturalCellWidths(headers, font: AppFont.monoMediumBold),
            rowWidths: rows.map { naturalCellWidths($0, font: AppFont.monoMedium) },
            columnCount: columnCount(headers: headers, rows: rows)
        )
    }

    /// Column metrics from already measured cell widths; cells past
    /// `columnCount` are not rendered and do not count.
    private static func naturalColumnMetrics(
        headerWidths: [CellWidth],
        rowWidths: [[CellWidth]],
        columnCount colCount: Int
    ) -> MarkdownTableColumnLayout.NaturalColumns {
        guard colCount > 0 else { return .empty }

        let cellFont = AppFont.monoMedium
        var colWidths = [CGFloat](repeating: 0, count: colCount)
        var wordLengths = [Int](repeating: 0, count: colCount)

        func include(_ row: [CellWidth]) {
            for (index, width) in row.enumerated() where index < colCount {
                colWidths[index] = max(colWidths[index], width.natural)
                wordLengths[index] = max(wordLengths[index], width.wordLength)
            }
        }
        include(headerWidths)
        rowWidths.forEach(include)

        // Match clip-mode padding: lead + trail + separators between columns.
        let leadPadWidth = measuredTextWidth("  ", font: cellFont)
        let sepWidth = measuredTextWidth("  │  ", font: cellFont)
        let trailPadWidth = leadPadWidth
        let buffer: CGFloat = 1
        let content = colWidths.reduce(0, +) + buffer * CGFloat(colCount)
        let separators = sepWidth * CGFloat(max(0, colCount - 1))
        let total = leadPadWidth + content + separators + trailPadWidth
        return MarkdownTableColumnLayout.NaturalColumns(
            columnWidths: colWidths,
            // SF Mono keeps one advance across weights, headers included.
            longestWordWidths: wordLengths.map { ceil(CGFloat($0) * MarkdownTableColumnLayout.monoAdvanceWidth) },
            totalWidth: ceil(total)
        )
    }

    // internal for testing — called from TableColumnAlignmentTests
    static func makeTableAttributedText(
        headers: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        palette: ThemePalette
    ) -> NSAttributedString {
        // Column widths come from the rendered text: SF Mono is monospaced for
        // ASCII, but CJK and emoji fall back to fonts whose advances do not
        // divide evenly into the ASCII space width.
        let columnWidths = naturalColumnMetrics(
            headerWidths: naturalCellWidths(headers, font: AppFont.monoMediumBold),
            rowWidths: rows.map { naturalCellWidths($0, font: AppFont.monoMedium) },
            columnCount: columnCount(headers: headers, rows: rows)
        ).columnWidths
        let text = MarkdownTableClipText(headers: headers, columnWidths: columnWidths, palette: palette)
        text.replaceRows(keeping: 0, with: rows)
        return NSAttributedString(attributedString: text.storage)
    }

    @objc private func longPressCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        UIPasteboard.general.string = markdownTableText()

        AppHaptics.impact(style: .light, intensity: 0.7)

        showCopiedFlash()
    }

    private func markdownTableText() -> String {
        var lines: [String] = []

        let headerLine = "| " + currentHeaders.map { markdownText(from: $0) }.joined(separator: " | ") + " |"
        lines.append(headerLine)

        let separatorLine = "| " + currentHeaders.map { _ in "---" }.joined(separator: " | ") + " |"
        lines.append(separatorLine)

        for row in fullRows {
            let rowLine = "| " + row.map { markdownText(from: $0) }.joined(separator: " | ") + " |"
            lines.append(rowLine)
        }

        return lines.joined(separator: "\n")
    }

    /// Reconstruct markdown source text from inlines (preserves link syntax).
    private func markdownText(from inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s): return s
            case .link(let children, let dest):
                let text = plainText(from: children)
                if let dest { return "[\(text)](\(dest))" }
                return text
            case .emphasis(let children): return "*\(markdownText(from: children))*"
            case .strong(let children): return "**\(markdownText(from: children))**"
            case .code(let s): return "`\(s)`"
            case .strikethrough(let children): return "~~\(markdownText(from: children))~~"
            case .softBreak: return " "
            case .hardBreak: return "\n"
            case .html(let s): return s
            case .image(let alt, let src):
                if let src { return "![\(alt)](\(src))" }
                return alt
            case .videoEmbed(let embed):
                return "![[\(embed.reference.target)]]"
            case .audioEmbed(let embed):
                return "![[\(embed.reference.target)]]"
            case .usdzEmbed(let embed):
                return "![[\(embed.reference.target)]]"
            }
        }.joined()
    }

    private func showCopiedFlash() {
        showCopiedOverlay(on: cardView)
    }
}

extension NativeTableBlockView: UITextViewDelegate {
    /// Classify a table-cell URL for tap/long-press behavior. Exposed for testing.
    func classifyLink(_ url: URL) -> AppOpenRequest? {
        MarkdownLinkInteractionSupport.classify(
            url,
            serverID: resourceReferenceServerID,
            workspaceID: resourceReferenceWorkspaceID
        )
    }

    /// Clip-mode and wrap-mode cells share this helper via the table delegate.
    func primaryAction(for url: URL, from textView: UITextView, defaultAction: UIAction) -> UIAction? {
        MarkdownLinkInteractionSupport.primaryAction(
            for: classifyLink(url),
            from: textView,
            defaultAction: defaultAction
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
        return primaryAction(for: url, from: textView, defaultAction: defaultAction)
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
            FileSharePresenter.share(normalizedURL, sourceView: sourceView)
        }
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if let menu = ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        ) {
            return menu
        }

        guard let router = reviewCommentSelectionRouter,
              let sourceContext = reviewCommentSourceContext,
              let fallbackText = fallbackSelectedText(in: textView, range: range) else {
            return nil
        }

        return ReviewCommentSelectionMenuBuilder.editMenu(
            suggestedActions: suggestedActions,
            selectedText: fallbackText,
            sourceContext: sourceContext,
            router: router,
            textView: textView,
            selectedRange: range
        )
    }

    private func fallbackSelectedText(in textView: UITextView, range: NSRange) -> String? {
        guard range.location != NSNotFound else { return nil }

        let fullText = textView.attributedText?.string ?? textView.text ?? ""
        let nsText = fullText as NSString
        guard range.location < nsText.length else { return nil }

        let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsText.substring(with: lineRange)
        let normalized = ReviewCommentSelectionTextFormatter.normalizedSelectedText(lineText)
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - Full-screen viewer and copy

extension NativeTableBlockView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateOverflowCue()
    }

    /// Opens the whole table, every row and column, in the full-screen viewer.
    func openFullScreen() {
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            .document(.delimitedTable(text: tableText(.tsv), filePath: "table.tsv")),
            from: self
        )
    }

    /// The whole table as copied text: Markdown keeps inline syntax, TSV is plain cells.
    func tableText(_ format: TableCopyFormat) -> String {
        switch format {
        case .markdown:
            return markdownTableText()
        case .tsv:
            return TableTextFormat.tsv(
                headers: currentHeaders.map { plainText(from: $0) },
                rows: fullRows.map { $0.map { plainText(from: $0) } }
            )
        }
    }

    fileprivate func copyTable(_ format: TableCopyFormat) {
        UIPasteboard.general.string = tableText(format)
        AppHaptics.impact(style: .light, intensity: 0.7)
        showCopiedFlash()
    }
}

/// Show a flash overlay + floating "Copied" pill centered on the given view.
@MainActor
private func showCopiedOverlay(on view: UIView) {
    let palette = ThemeRuntimeState.currentPalette()
    let overlay = UIView()
    overlay.backgroundColor = palette.ui.fg.withAlphaComponent(0.08)
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
        // A one-line block is narrow: the pill stays inside it.
        pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
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

private final class CopiedPillView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let palette = ThemeRuntimeState.currentPalette()

        let icon = UIImageView(image: UIImage(systemName: "checkmark"))
        icon.tintColor = palette.ui.fg
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)

        let label = UILabel()
        label.text = "Copied"
        // Capped: a short, transient pill over a block that may be one line tall.
        label.font = AppFont.scaledSystem(13, .semibold, relativeTo: .footnote, maximumPointSize: 22)
        label.textColor = palette.ui.fg
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Transient pill over code content with no blur behind it, so it
        // takes the near-opaque card role.
        backgroundColor = ThemeSurfaceStyle.resolve(.opaqueCard, palette: palette).fill
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
