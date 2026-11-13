import UIKit

/// Text size, wrapping, and spacing for full-screen readers. Shared by
/// `FullScreenCodeViewController` and the review diff reader (`DiffReaderView`).
///
/// A UIKit controller that owns the popover or sheet: a glass panel with a
/// text-size slider, a wrap switch and a spacing control where the content
/// family supports them, and Reset View. It reads the theme from
/// `ThemeRuntimeState`, so it needs no app root.
final class FullScreenViewingOptionsController: UIViewController {
    private static let panelWidth: CGFloat = 340
    private static let outerMargin: CGFloat = 16
    private static let innerPadding: CGFloat = 20
    /// The slider moves in 5% steps.
    static let textScaleStep: CGFloat = 0.05

    private var family: FullScreenReaderContentFamily
    private var preferences: FullScreenReaderPreferences
    private let onTextScaleChanged: (CGFloat) -> Void
    private let onWrappingChanged: (Bool) -> Void
    private let onSpacingChanged: (FullScreenReaderSpacing) -> Void
    private let onReset: () -> Void

    var onDismiss: ((FullScreenViewingOptionsController) -> Void)?

    private let scrollView = UIScrollView()
    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let contentStack = UIStackView()

    private let headerIcon = UIImageView()
    private let headerGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let headerTitle = UILabel()
    private let headerSubtitle = UILabel()
    private let header = UIStackView()

    private let textSizeIcon = UIImageView()
    private let textSizeTitle = UILabel()
    private let textSizeValue = UILabel()
    private let textSizeSlider = TextScaleSlider()
    private let textSizeGroup = UIStackView()
    /// The title row and the percent: side by side, stacked at accessibility sizes.
    private let textSizeTop = UIStackView()

    private let wrapDivider = UIView()
    private let wrapIcon = UIImageView()
    private let wrapTitle = UILabel()
    private let wrapSwitch = UISwitch()
    private let wrapRow = UIStackView()

    private let spacingDivider = UIView()
    private let spacingIcon = UIImageView()
    private let spacingTitle = UILabel()
    private let spacingControl = UISegmentedControl(
        items: FullScreenReaderSpacing.allCases.map(\.displayName)
    )
    private let spacingGroup = UIStackView()

    private let resetButton = UIButton(configuration: .bordered())

    /// The sheet detent: the panel at its natural height, at the sheet's width.
    var preferredSheetHeight: CGFloat {
        fittingHeight(forWidth: view.bounds.width > 0 ? view.bounds.width : Self.panelWidth)
    }

    init(
        family: FullScreenReaderContentFamily,
        preferences: FullScreenReaderPreferences,
        onTextScaleChanged: @escaping (CGFloat) -> Void,
        onWrappingChanged: @escaping (Bool) -> Void,
        onSpacingChanged: @escaping (FullScreenReaderSpacing) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.family = family
        self.preferences = preferences
        self.onTextScaleChanged = onTextScaleChanged
        self.onWrappingChanged = onWrappingChanged
        self.onSpacingChanged = onSpacingChanged
        self.onReset = onReset
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { nil }

    // MARK: - Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.accessibilityIdentifier = "fullscreen.viewingOptions"

        glassView.cornerConfiguration = .corners(radius: 28)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glassView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        glassView.contentView.addSubview(scrollView)

        configureControls()
        buildContent()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let margin = Self.outerMargin
        let padding = Self.innerPadding
        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            glassView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            glassView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            glassView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -margin),
            scrollView.topAnchor.constraint(equalTo: glassView.contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: padding),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -padding),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: padding),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -padding),
            scrollView.contentLayoutGuide.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: -padding),
            scrollView.contentLayoutGuide.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: padding),
        ])
        preferredContentSize = CGSize(width: Self.panelWidth, height: fittingHeight(forWidth: Self.panelWidth))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A popover takes its size from here; a larger text size grows it.
        let height = fittingHeight(forWidth: Self.panelWidth)
        if preferredContentSize.height != height || preferredContentSize.width != Self.panelWidth {
            preferredContentSize = CGSize(width: Self.panelWidth, height: height)
        }
        scrollView.isScrollEnabled = scrollView.contentSize.height > scrollView.bounds.height + 0.5
    }

    /// The panel's height at `width`: the stack at its natural height inside
    /// the glass padding, the outer margin, and the bottom safe area (a
    /// sheet's home indicator).
    private func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let stackWidth = width - 2 * (Self.outerMargin + Self.innerPadding)
        let stackHeight = contentStack.systemLayoutSizeFitting(
            CGSize(width: stackWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        return ceil(stackHeight + 2 * (Self.innerPadding + Self.outerMargin) + view.safeAreaInsets.bottom)
    }

    private func configureControls() {
        for label in [headerTitle, headerSubtitle, textSizeTitle, textSizeValue, wrapTitle, spacingTitle] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        textSizeValue.numberOfLines = 1
        textSizeValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        textSizeValue.setContentHuggingPriority(.required, for: .horizontal)
        textSizeValue.isAccessibilityElement = false
        for icon in [headerIcon, textSizeIcon, wrapIcon, spacingIcon] {
            icon.isAccessibilityElement = false
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        headerTitle.text = String(localized: "Viewing Options")
        headerSubtitle.text = String(localized: "Reader controls")
        headerIcon.contentMode = .center
        headerGlass.cornerConfiguration = .capsule()
        headerGlass.contentView.addSubview(headerIcon)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerGlass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerGlass.widthAnchor.constraint(equalToConstant: 34),
            headerGlass.heightAnchor.constraint(equalToConstant: 34),
            headerIcon.centerXAnchor.constraint(equalTo: headerGlass.contentView.centerXAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: headerGlass.contentView.centerYAnchor),
        ])
        // One element: the title and its subtitle read together.
        header.isAccessibilityElement = true
        header.accessibilityLabel = "\(String(localized: "Viewing Options")), \(String(localized: "Reader controls"))"
        header.accessibilityTraits = .header
        header.accessibilityIdentifier = "fullscreen.viewingOptions.header"

        textSizeTitle.text = String(localized: "Text Size")
        textSizeSlider.minimumValue = Float(FullScreenReaderPreferences.minimumTextScale)
        textSizeSlider.maximumValue = Float(FullScreenReaderPreferences.maximumTextScale)
        textSizeSlider.step = Float(Self.textScaleStep)
        textSizeSlider.minimumValueImage = UIImage(systemName: "textformat.size.smaller")
        textSizeSlider.maximumValueImage = UIImage(systemName: "textformat.size.larger")
        textSizeSlider.accessibilityLabel = String(localized: "Text Size")
        textSizeSlider.accessibilityIdentifier = "fullscreen.viewingOptions.textSize"
        textSizeSlider.addAction(UIAction { [weak self] action in
            guard let self, let slider = action.sender as? UISlider else { return }
            let scale = Self.snappedTextScale(CGFloat(slider.value))
            slider.value = Float(scale)
            // A drag crosses many raw values inside one 5% step; the owner
            // saves and re-applies only when the step changes.
            guard scale != preferences.textScale else { return }
            preferences.textScale = scale
            setNeedsUpdateProperties()
            onTextScaleChanged(scale)
        }, for: .valueChanged)

        wrapTitle.text = String(localized: "Wrap Text")
        wrapSwitch.accessibilityLabel = String(localized: "Wrap Text")
        wrapSwitch.accessibilityIdentifier = "fullscreen.viewingOptions.wrap"
        wrapSwitch.setContentHuggingPriority(.required, for: .horizontal)
        wrapSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        wrapSwitch.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            onWrappingChanged(toggle.isOn)
        }, for: .valueChanged)

        spacingTitle.text = String(localized: "Spacing")
        spacingControl.accessibilityLabel = String(localized: "Spacing")
        spacingControl.accessibilityIdentifier = "fullscreen.viewingOptions.spacing"
        spacingControl.addAction(UIAction { [weak self] action in
            guard let self, let control = action.sender as? UISegmentedControl,
                  FullScreenReaderSpacing.allCases.indices.contains(control.selectedSegmentIndex) else { return }
            onSpacingChanged(FullScreenReaderSpacing.allCases[control.selectedSegmentIndex])
        }, for: .valueChanged)

        var reset = UIButton.Configuration.bordered()
        reset.cornerStyle = .capsule
        reset.title = String(localized: "Reset View")
        reset.image = UIImage(systemName: "arrow.counterclockwise")
        reset.imagePadding = 6
        resetButton.configuration = reset
        resetButton.accessibilityIdentifier = "fullscreen.viewingOptions.reset"
        resetButton.addAction(UIAction { [weak self] _ in self?.onReset() }, for: .primaryActionTriggered)
    }

    private func buildContent() {
        contentStack.axis = .vertical
        contentStack.spacing = 18

        let headerText = UIStackView(arrangedSubviews: [headerTitle, headerSubtitle])
        headerText.axis = .vertical
        headerText.spacing = 2
        header.addArrangedSubview(headerGlass)
        header.addArrangedSubview(headerText)
        header.axis = .horizontal
        header.spacing = 12
        header.alignment = .center

        let textSizeTitleRow = UIStackView(arrangedSubviews: [textSizeIcon, textSizeTitle])
        textSizeTitleRow.axis = .horizontal
        textSizeTitleRow.spacing = 6
        textSizeTitleRow.alignment = .center
        textSizeTitleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textSizeTop.addArrangedSubview(textSizeTitleRow)
        textSizeTop.addArrangedSubview(textSizeValue)
        textSizeTop.spacing = 12
        textSizeGroup.addArrangedSubview(textSizeTop)
        textSizeGroup.addArrangedSubview(textSizeSlider)
        textSizeGroup.axis = .vertical
        textSizeGroup.spacing = 10

        wrapRow.addArrangedSubview(wrapIcon)
        wrapRow.addArrangedSubview(wrapTitle)
        wrapRow.addArrangedSubview(wrapSwitch)
        wrapRow.axis = .horizontal
        wrapRow.spacing = 6
        wrapRow.alignment = .center
        wrapRow.setCustomSpacing(12, after: wrapTitle)

        let spacingTop = UIStackView(arrangedSubviews: [spacingIcon, spacingTitle])
        spacingTop.axis = .horizontal
        spacingTop.spacing = 6
        spacingTop.alignment = .center
        spacingGroup.addArrangedSubview(spacingTop)
        spacingGroup.addArrangedSubview(spacingControl)
        spacingGroup.axis = .vertical
        spacingGroup.spacing = 10

        for divider in [wrapDivider, spacingDivider] {
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)).isActive = true
            divider.isAccessibilityElement = false
        }

        for arranged in [header, textSizeGroup, wrapDivider, wrapRow, spacingDivider, spacingGroup, resetButton] {
            contentStack.addArrangedSubview(arranged)
        }
    }

    // MARK: - State

    override func updateProperties() {
        super.updateProperties()
        // Beside the title, the percent squeezes it to a letter per line at
        // accessibility sizes; under it, both read in full.
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        textSizeTop.axis = stacked ? .vertical : .horizontal
        textSizeTop.alignment = stacked ? .leading : .center
        let fg = UIColor.themeFg
        let dim = UIColor.themeFgDim
        let cyan = UIColor.themeCyan

        view.tintColor = cyan
        headerIcon.image = .scaledSymbol(FullScreenViewingOptionsSymbols.readerModeIconName, style: .title3, weight: .semibold, color: fg)
        headerTitle.font = .scaled(.headline)
        headerTitle.textColor = fg
        headerSubtitle.font = .scaled(.caption1)
        headerSubtitle.textColor = dim

        textSizeIcon.image = .scaledSymbol("textformat.size", style: .subheadline, weight: .semibold, color: fg)
        textSizeTitle.font = .scaled(.subheadline, .semibold)
        textSizeTitle.textColor = fg
        textSizeValue.font = .scaled(.subheadline, .medium, monospacedDigits: true)
        textSizeValue.textColor = dim
        let percent = Int(round(preferences.textScale * 100))
        textSizeValue.text = "\(percent)%"
        textSizeSlider.accessibilityValue = String(localized: "\(percent) percent")
        if !textSizeSlider.isTracking, CGFloat(textSizeSlider.value) != preferences.textScale {
            textSizeSlider.value = Float(preferences.textScale)
        }

        wrapIcon.image = .scaledSymbol(CodeWrapControl.symbolName, style: .subheadline, color: fg)
        wrapTitle.font = .scaled(.subheadline)
        wrapTitle.textColor = fg
        wrapSwitch.onTintColor = cyan
        if wrapSwitch.isOn != preferences.wrapsText {
            wrapSwitch.setOn(preferences.wrapsText, animated: false)
        }

        spacingIcon.image = .scaledSymbol("line.3.horizontal.decrease", style: .subheadline, weight: .semibold, color: fg)
        spacingTitle.font = .scaled(.subheadline, .semibold)
        spacingTitle.textColor = fg
        if let index = FullScreenReaderSpacing.allCases.firstIndex(of: preferences.spacing),
           spacingControl.selectedSegmentIndex != index {
            spacingControl.selectedSegmentIndex = index
        }

        for divider in [wrapDivider, spacingDivider] {
            divider.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
        }
        wrapDivider.isHidden = !family.supportsWrapping
        wrapRow.isHidden = !family.supportsWrapping
        spacingDivider.isHidden = !family.supportsSpacing
        spacingGroup.isHidden = !family.supportsSpacing

        var reset = resetButton.configuration ?? .bordered()
        reset.baseForegroundColor = cyan
        reset.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.subheadline)
            return outgoing
        }
        resetButton.configuration = reset
    }

    /// `value` on the slider's 5% grid, inside the reader's text-scale range.
    static func snappedTextScale(_ value: CGFloat) -> CGFloat {
        FullScreenReaderPreferences.clampedTextScale((value / textScaleStep).rounded() * textScaleStep)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?(self)
        }
    }

    func apply(family: FullScreenReaderContentFamily, preferences: FullScreenReaderPreferences) {
        guard self.family != family || self.preferences != preferences else { return }
        self.family = family
        self.preferences = preferences
        setNeedsUpdateProperties()
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    /// A popover from a rail bar item or the floating button, which UIKit
    /// adapts to a sheet sized to the panel when compact. With neither control
    /// it is a sheet.
    func configurePresentation(barItem: UIBarButtonItem?, sourceButton: UIView?) {
        let detentIdentifier = UISheetPresentationController.Detent.Identifier("viewing-options")
        var presentation = ModalPresentation.popoverOrSheet(
            detents: [
                .custom(identifier: detentIdentifier) { [weak self] context in
                    min(self?.preferredSheetHeight ?? 280, context.maximumDetentValue)
                }
            ],
            selected: detentIdentifier,
            grabber: true,
            cornerRadius: 24
        )
        // The floating button sits at the bottom trailing corner; a bar item keeps any direction.
        if barItem == nil { presentation = presentation.arrowDirections([.down, .right]) }
        if barItem == nil, sourceButton == nil { presentation.style = .pageSheet }
        presentation.apply(to: self, source: sourceButton)
        if let barItem {
            popoverPresentationController?.barButtonItem = barItem
        }
    }

    /// The floating glass Viewing Options button. Callers add the target.
    static func makeFloatingButton(palette: ThemePalette) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: FullScreenViewingOptionsSymbols.readerModeIconName)
        config.preferredSymbolConfigurationForImage = .init(
            pointSize: FullScreenFloatingControlChrome.symbolPointSize,
            weight: .semibold
        )
        let contentPadding = FullScreenFloatingControlChrome.standaloneContentPadding
        config.contentInsets = NSDirectionalEdgeInsets(
            top: contentPadding,
            leading: contentPadding,
            bottom: contentPadding,
            trailing: contentPadding
        )
        FullScreenFloatingControlChrome.applyGlassBackground(to: &config, palette: palette)

        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "fullscreen.viewingOptions.button"
        button.accessibilityLabel = String(localized: "Viewing Options")
        button.accessibilityHint = String(localized: "Adjust text size, wrapping, and spacing")
        return button
    }

    static func updateFloatingButton(
        _ button: UIButton,
        palette: ThemePalette,
        preferences: FullScreenReaderPreferences
    ) {
        var config = button.configuration ?? .plain()
        FullScreenFloatingControlChrome.applyGlassBackground(to: &config, palette: palette)
        button.configuration = config
        button.accessibilityValue = accessibilityValue(for: preferences)
    }

    /// What VoiceOver says for the Viewing Options control: the text size.
    static func accessibilityValue(for preferences: FullScreenReaderPreferences) -> String {
        String(localized: "Text size \(Int(round(preferences.textScale * 100))) percent")
    }
}

/// A slider whose VoiceOver increment and decrement use its own step
/// (UIKit's default is 10% of the range).
private final class TextScaleSlider: UISlider {
    var step: Float = 0.05

    override func accessibilityIncrement() { nudge(step) }
    override func accessibilityDecrement() { nudge(-step) }

    private func nudge(_ delta: Float) {
        value = min(maximumValue, max(minimumValue, value + delta))
        sendActions(for: .valueChanged)
    }
}

enum FullScreenViewingOptionsSymbols {
    static var readerModeIconName: String {
        if UIImage(systemName: "text.page") != nil {
            return "text.page"
        }
        return "doc.text"
    }
}
