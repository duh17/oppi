import PhotosUI
import UIKit

/// Snapshot of theme colors for UIKit composer chrome. Built from `ThemePalette`
/// on the SwiftUI seam so this file stays SwiftUI-free.
struct ComposerThemeColors {
    var bg: UIColor
    var bgDark: UIColor
    var bgHighlight: UIColor
    var fg: UIColor
    var fgDim: UIColor
    var comment: UIColor
    var blue: UIColor
    var cyan: UIColor
    var green: UIColor
    var orange: UIColor
    var purple: UIColor
    var red: UIColor
    var yellow: UIColor
    var scrim: UIColor
    var elevatedStroke: UIColor
    var floatingFill: UIColor
}

enum ComposerAttachmentButtonPlacement {
    case leading
    case trailing
}

/// The + menu and media pickers shared by the inline and expanded composers.
@MainActor
enum ComposerAttachmentPickers {
    /// Photo Library, Camera, Choose File, Canvas, in the app's menu order.
    /// Item identifiers are `<identifierPrefix>.<item>`.
    static func menu(
        identifierPrefix: String,
        onSelect: @escaping (PaperMarkupCanvasSession.AttachmentMenuItem) -> Void
    ) -> UIMenu {
        UIMenu(children: PaperMarkupCanvasSession.attachmentMenuItems.map { item in
            UIAction(
                title: item.title,
                image: UIImage(systemName: item.systemImage),
                identifier: UIAction.Identifier("\(identifierPrefix).\(String(describing: item))")
            ) { _ in onSelect(item) }
        })
    }

    /// Over full screen keeps the composer's presenter in the window.
    static func photoLibrary(delegate: PHPickerViewControllerDelegate) -> PHPickerViewController {
        let picker = PHPickerViewController(
            configuration: PhotoLibraryPicker.makeConfiguration(
                selectionLimit: ComposerShared.maxPhotoSelectionCount
            )
        )
        picker.delegate = delegate
        picker.modalPresentationStyle = .overFullScreen
        return picker
    }

    static func camera(
        delegate: UIImagePickerControllerDelegate & UINavigationControllerDelegate
    ) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = delegate
        picker.modalPresentationStyle = .overFullScreen
        return picker
    }
}

/// Composer capsule: the same untinted Liquid Glass as its pills and the
/// app's floating controls, a theme hairline, and 20pt continuous corners.
/// Glass blurs the timeline behind it, so the bar needs no opaque fill.
final class ComposerThemedPanelView: UIView {
    var cornerRadius: CGFloat = 20 {
        didSet { applyShape() }
    }

    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    let contentView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glassView.clipsToBounds = true
        contentView.backgroundColor = .clear
        addSubview(glassView)
        addSubview(contentView)
        for view in [glassView, contentView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        applyShape()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(colors: ComposerThemeColors) {
        layer.borderColor = colors.elevatedStroke.cgColor
        layer.borderWidth = 0.5
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyShape()
    }

    private func applyShape() {
        let radius = cornerRadius
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        for view in [glassView, contentView] {
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
        }
    }
}

/// Circle send / stop / ignore control with a 44pt hit target and press fade.
/// The composer's Send and Stop: the symbol and colors its primary button
/// draws for each. The SSH terminal bar draws a coding agent's Return and
/// interrupt keys with the same looks (`SSHTerminalPillButton.showAgentKey`).
struct ComposerPrimaryActionLook {
    let systemImage: String
    let fill: UIColor
    let stroke: UIColor
    let foreground: UIColor
    let symbol: UIImage.SymbolConfiguration

    static let sendSymbol = "arrow.up"
    static let stopSymbol = "stop.fill"

    /// Send while it can send: blue, purple while the agent is busy (the
    /// message steers the running turn).
    static func send(busy: Bool, colors: ComposerThemeColors) -> Self {
        filled(sendSymbol, fill: busy ? colors.purple : colors.blue, colors: colors, pointSize: 15)
    }

    /// Stop while a turn runs: red, orange once stopping.
    static func stop(stopping: Bool, colors: ComposerThemeColors) -> Self {
        filled(stopSymbol, fill: stopping ? colors.orange : colors.red, colors: colors, pointSize: 14)
    }

    private static func filled(_ systemImage: String, fill: UIColor, colors: ComposerThemeColors, pointSize: CGFloat) -> Self {
        Self(
            systemImage: systemImage,
            fill: fill,
            stroke: fill.withAlphaComponent(0.9),
            foreground: ComposerColorContrast.foreground(for: fill, fg: colors.fg, bg: colors.bg),
            symbol: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        )
    }
}

extension UIButton {
    /// The composer draws its own buttons: fills, strokes, glass, and pop-up
    /// menus from its configuration. The Mac build runs in the Mac idiom,
    /// where a button's automatic behavioral style is `.mac`: it draws an
    /// AppKit-style button that drops the configuration's background (Send
    /// became a bare arrow) and draws nothing for a button whose tap opens a
    /// menu (the thinking pill and "+" vanished). The iPad style keeps the
    /// same drawing as iPhone and iPad, where it is already the automatic one.
    func drawsComposerChrome() {
        preferredBehavioralStyle = .pad
    }
}

final class ComposerCircleActionButton: UIButton {
    var visualDiameter: CGFloat = ComposerInputMetrics.controlDiameter {
        didSet { invalidateIntrinsicContentSize() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        drawsComposerChrome()
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: visualDiameter, height: visualDiameter)
    }

    func apply(
        systemImage: String,
        fill: UIColor,
        stroke: UIColor,
        foreground: UIColor,
        showsProgress: Bool,
        diameter: CGFloat = ComposerInputMetrics.controlDiameter,
        symbol: UIImage.SymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    ) {
        visualDiameter = diameter
        var config = UIButton.Configuration.plain()
        config.background.backgroundColor = fill
        config.background.strokeColor = stroke
        config.background.strokeWidth = 1
        config.background.cornerRadius = diameter / 2
        config.cornerStyle = .capsule
        config.baseForegroundColor = foreground
        config.contentInsets = .zero
        if showsProgress {
            config.image = nil
            config.showsActivityIndicator = true
        } else {
            config.showsActivityIndicator = false
            config.image = UIImage(systemName: systemImage)
            config.preferredSymbolConfigurationForImage = symbol
        }
        configuration = config
        invalidateIntrinsicContentSize()
    }

    func apply(
        _ look: ComposerPrimaryActionLook,
        showsProgress: Bool,
        diameter: CGFloat = ComposerInputMetrics.controlDiameter
    ) {
        apply(
            systemImage: look.systemImage, fill: look.fill, stroke: look.stroke, foreground: look.foreground,
            showsProgress: showsProgress, diameter: diameter, symbol: look.symbol
        )
    }
}

/// The composer's action pills are shorter than a comfortable touch. Each pill,
/// and each container that holds pills, accepts touches across a 44pt band
/// around its bounds; the action row's own bounds still clip that band.
enum ComposerHitTarget {
    static let minimumSide: CGFloat = 44

    static func contains(_ point: CGPoint, in bounds: CGRect, minimumSide: CGFloat = Self.minimumSide) -> Bool {
        bounds.insetBy(
            dx: min(0, (bounds.width - minimumSide) / 2),
            dy: min(0, (bounds.height - minimumSide) / 2)
        ).contains(point)
    }
}

/// Holds action pills without clipping their hit band to the pills' height.
final class ComposerPillStackView: UIStackView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ComposerHitTarget.contains(point, in: bounds)
    }
}

/// The composer's action row. It refits its pop-up controls
/// (`ComposerBarController.fitPopUpActions`) each time it lays out, when its
/// own width is current: the bar's `viewDidLayoutSubviews` can run before a
/// narrowed row (a pane split) gets its new bounds.
final class ComposerActionRowStackView: UIStackView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Scrolling row of action pills; see `ComposerPillStackView`.
final class ComposerPillScrollView: UIScrollView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ComposerHitTarget.contains(point, in: bounds)
    }
}

/// Glass capsule used for attach and busy-mode. Matches the SwiftUI
/// `.glassEffect(.regular, in: Capsule())` pills: clear glass under plain
/// content, so the label keeps the theme foreground instead of the dark
/// glyphs a glass button configuration picks over the composer.
final class ComposerGlassPillButton: UIButton {
    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))

    override init(frame: CGRect) {
        super.init(frame: frame)
        drawsComposerChrome()
        glassView.isUserInteractionEnabled = false
        glassView.clipsToBounds = true
        insertSubview(glassView, at: 0)
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.frame = bounds
        glassView.layer.cornerRadius = bounds.height / 2
        glassView.layer.cornerCurve = .continuous
        sendSubviewToBack(glassView)
    }

    /// True once `applyPopUpStyle` ran: the gray capsule of the row's pop-up
    /// buttons (a circle when it has no title), with no glass of its own.
    /// `apply` puts the glass pill back.
    private var usesPopUpStyle = false {
        didSet {
            guard usesPopUpStyle != oldValue else { return }
            glassView.isHidden = usesPopUpStyle
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        if usesPopUpStyle {
            let width = configuration?.title == nil ? ComposerPopUpButton.height : super.intrinsicContentSize.width
            return CGSize(width: max(width, ComposerPopUpButton.height), height: ComposerPopUpButton.height)
        }
        if configuration?.title == nil, configuration?.image != nil {
            return CGSize(width: 36, height: 23)
        }
        return super.intrinsicContentSize
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ComposerHitTarget.contains(point, in: bounds)
    }

    /// The "+" (a symbol) or the busy send mode (a title with the pop-up
    /// indicator) in a row of pop-up buttons (`ComposerAction.Chrome.popUp`):
    /// the same gray capsule, height, and body text, so the row reads as one set.
    func applyPopUpStyle(colors: ComposerThemeColors, systemImage: String? = nil, title: String? = nil) {
        usesPopUpStyle = true
        var config = ComposerPopUpButton.baseConfiguration(
            tint: colors.fg,
            fill: ComposerPopUpButton.fill(for: colors)
        )
        if let systemImage {
            config.image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        }
        if let title {
            config.title = title
            config.indicator = .popup
            config.indicatorColorTransformer = UIConfigurationColorTransformer { _ in .secondaryLabel }
            config.titleLineBreakMode = .byTruncatingTail
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.preferredFont(forTextStyle: .body)
                return outgoing
            }
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        } else {
            config.contentInsets = .zero
        }
        configuration = config
        isPointerInteractionEnabled = true
        invalidateIntrinsicContentSize()
    }

    func apply(
        title: String?,
        systemImage: String?,
        colors: ComposerThemeColors,
        chevron: Bool = false,
        symbolPointSize: CGFloat = 13,
        weight: UIImage.SymbolWeight = .semibold
    ) {
        usesPopUpStyle = false
        isPointerInteractionEnabled = false
        var config = UIButton.Configuration.plain()
        config.background.backgroundColor = .clear
        config.baseForegroundColor = colors.fg
        let horizontal: CGFloat = title == nil ? 12 : 11
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: horizontal, bottom: 6, trailing: horizontal)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return outgoing
        }
        if let title {
            config.title = title
        }
        if let systemImage {
            config.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: weight)
            )
            if title != nil {
                config.imagePadding = 5
            }
        }
        if chevron {
            config.imagePlacement = .trailing
            config.image = UIImage(
                systemName: "chevron.up.chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .semibold
                )
            )
            config.imagePadding = 5
        }
        configuration = config
        invalidateIntrinsicContentSize()
    }
}

/// Model / thinking / agent / workspace pill. Matches the SwiftUI `PillLabel`
/// (caption2, 11pt icon, trailing chevron, 21pt capsule) with a 44pt hit band.
final class ComposerToolbarPillButton: UIButton {
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 2
    private static let minimumContentHeight: CGFloat = 17

    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let captionLabel = UILabel()
    private let chevronView = UIImageView()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        drawsComposerChrome()
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        glassView.clipsToBounds = true
        glassView.isUserInteractionEnabled = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        iconView.contentMode = .scaleAspectFit
        captionLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .medium
        )
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevronView.image = UIImage(systemName: "chevron.down", withConfiguration: chevronConfig)
        chevronView.contentMode = .scaleAspectFit
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(captionLabel)
        stack.addArrangedSubview(chevronView)
        addSubview(glassView)
        addSubview(stack)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let iconW = iconView.widthAnchor.constraint(equalToConstant: 11)
        let iconH = iconView.heightAnchor.constraint(equalToConstant: 11)
        iconWidthConstraint = iconW
        iconHeightConstraint = iconH
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
            iconW,
            iconH,
            chevronView.widthAnchor.constraint(equalToConstant: 9),
            chevronView.heightAnchor.constraint(equalToConstant: 11),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sized by the label, not UIButton's empty-content default (about
    /// 30×34), which squeezed the title away and made the pill tall.
    override var intrinsicContentSize: CGSize {
        let content = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(
            width: ceil(content.width) + Self.horizontalPadding * 2,
            height: max(ceil(content.height), Self.minimumContentHeight) + Self.verticalPadding * 2
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.layer.cornerRadius = bounds.height / 2
        glassView.layer.cornerCurve = .continuous
    }

    override var isHighlighted: Bool {
        didSet { alpha = isEnabled ? (isHighlighted ? 0.82 : 1) : 0.45 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? (isHighlighted ? 0.82 : 1) : 0.45 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ComposerHitTarget.contains(point, in: bounds)
    }

    func apply(
        title: String,
        icon: UIImage?,
        tint: UIColor,
        showsChevron: Bool,
        colors: ComposerThemeColors
    ) {
        captionLabel.text = title
        captionLabel.textColor = tint
        // An empty title makes an icon-only pill (Pi in the agent picker), and
        // its mark steps up so it carries the pill on its own.
        captionLabel.isHidden = title.isEmpty
        let iconSide: CGFloat = icon == nil ? 0 : (title.isEmpty ? 15 : 11)
        chevronView.tintColor = tint
        chevronView.isHidden = !showsChevron
        iconView.image = icon
        iconView.tintColor = tint
        iconView.isHidden = icon == nil
        iconWidthConstraint?.constant = iconSide
        iconHeightConstraint?.constant = iconSide
        glassView.backgroundColor = colors.floatingFill.withAlphaComponent(0.001)
        invalidateIntrinsicContentSize()
    }
}

/// Review-comment template chip.
final class ComposerActionChipButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        drawsComposerChrome()
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(title: String, systemImage: String?, colors: ComposerThemeColors) {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.baseForegroundColor = colors.fg
        config.background.backgroundColor = colors.bgHighlight.withAlphaComponent(0.85)
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.title = title
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return outgoing
        }
        if let systemImage {
            config.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            )
            config.imagePadding = 6
        }
        configuration = config
    }
}

/// Trailing review-comment cancel control.
final class ComposerActionCancelButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        drawsComposerChrome()
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(colors: ComposerThemeColors) {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = colors.fgDim
        config.background.backgroundColor = colors.bgHighlight.withAlphaComponent(0.85)
        config.background.cornerRadius = 16
        config.contentInsets = .zero
        config.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        )
        configuration = config
        accessibilityLabel = "Cancel comment"
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 32, height: 32) }
}

enum ComposerColorContrast {
    static func contrastingForeground(on fill: UIColor, candidates: [UIColor]) -> UIColor {
        let fillLum = relativeLuminance(of: fill)
        return candidates.max { lhs, rhs in
            contrastRatio(relativeLuminance(of: lhs), fillLum)
                < contrastRatio(relativeLuminance(of: rhs), fillLum)
        } ?? candidates[0]
    }

    static func foreground(for fill: UIColor, fg: UIColor, bg: UIColor) -> UIColor {
        contrastingForeground(on: fill, candidates: [fg, bg])
    }

    private static func contrastRatio(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

extension UIFont {
    fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

final class ComposerFilePillStripView: UIView {
    var onRemove: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var colors = ComposerThemeColors.placeholder

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(pointers: [PendingFileReference], colors: ComposerThemeColors) {
        self.colors = colors
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for file in pointers {
            let pill = ComposerRepoFilePillView()
            pill.apply(file: file, colors: colors, onRemove: { [weak self] in
                self?.onRemove?(file.id)
            })
            stack.addArrangedSubview(pill)
        }
        isHidden = pointers.isEmpty
    }
}

final class ComposerRepoFilePillView: UIView {
    private let prefixLabel = UILabel()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let removeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        prefixLabel.font = UIFont.preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        nameLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.contentMode = .scaleAspectFit
        let xConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        removeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xConfig), for: .normal)
        removeButton.accessibilityLabel = "Remove file"

        let stack = UIStackView(arrangedSubviews: [prefixLabel, iconView, nameLabel, removeButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            removeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(file: PendingFileReference, colors: ComposerThemeColors, onRemove: @escaping () -> Void) {
        let accent: UIColor
        switch file.kind {
        case .reviewFile: accent = colors.cyan
        case .workspaceFile: accent = colors.purple
        case .gitCommit: accent = colors.orange
        }
        prefixLabel.text = file.displayPrefix ?? {
            switch file.kind {
            case .reviewFile: return "Review"
            case .workspaceFile: return "Repo"
            case .gitCommit: return "Commit"
            }
        }()
        prefixLabel.textColor = accent
        nameLabel.text = file.displayName
        nameLabel.textColor = colors.fg
        let icon: FileIcon
        switch file.kind {
        case .gitCommit:
            icon = FileIcon(symbolName: "arrow.triangle.branch", tint: .orange)
        case .workspaceFile, .reviewFile:
            icon = file.isDirectory
                ? FileIcon(symbolName: "folder.fill", tint: .yellow)
                : FileIcon.forPath(file.path)
        }
        iconView.image = icon.uiImage(pointSize: 9, weight: .medium)
        removeButton.tintColor = colors.comment
        removeButton.removeTarget(nil, action: nil, for: .allEvents)
        removeButton.addAction(UIAction { _ in onRemove() }, for: .touchUpInside)
        backgroundColor = accent.withAlphaComponent(0.10)
        layer.borderColor = accent.withAlphaComponent(0.18).cgColor
    }
}

/// The "Dictation stopped" notice. Retry starts a new take; Dismiss (and the
/// manager's auto-dismiss timer) clears the notice, and the draft is already
/// restored (or, for a take kept as possibly incomplete, already holds its
/// text), so neither loses anything. Touching the notice holds the timer.
final class ComposerDictationFailureView: UIView {
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onInteractionChange: ((Bool) -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private lazy var dismissButton = NoticeChrome.dismissButton(identifier: "composer.dictationFailure.dismiss") { [weak self] in
        self?.onDismiss?()
    }
    private var touchHold: NoticeTouchHold?
    private var messageView: NoticeMessageView?
    /// Centers the X on the title's first line; follows the title's font.
    private var dismissCenterOffset: NSLayoutConstraint?

    /// Wires Retry, Dismiss, and the touch-hold to whichever manager the host
    /// has now.
    func connect(manager: @escaping () -> VoiceInputManager?, retry: @escaping () -> Void) {
        onRetry = retry
        onDismiss = { manager()?.dismissCaptureFailure() }
        onInteractionChange = { manager()?.setCaptureFailureInteracting($0) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "composer.dictationFailure"
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.text = "Dictation stopped"
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        messageLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.accessibilityIdentifier = "composer.dictationFailure.message"
        var retryConfig = UIButton.Configuration.plain()
        retryConfig.title = "Retry dictation"
        retryConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return outgoing
        }
        retryConfig.contentInsets = .zero
        retryButton.configuration = retryConfig
        retryButton.accessibilityIdentifier = "composer.dictationFailure.retry"
        retryButton.accessibilityLabel = "Retry dictation"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        // The X is centered on the title's first line, not the header's middle:
        // the title can wrap at large text sizes.
        let header = UIView()
        for view in [titleLabel, dismissButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let dismissCenter = dismissButton.centerYAnchor.constraint(equalTo: titleLabel.topAnchor)
        dismissCenterOffset = dismissCenter
        // The header is as short as the title and the X allow.
        let shortest = header.heightAnchor.constraint(equalToConstant: 0)
        shortest.priority = .defaultLow
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dismissButton.leadingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            dismissButton.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            dismissCenter,
            shortest,
        ])
        let message = NoticeChrome.cappedMessage(messageLabel)
        messageView = message
        let stack = UIStackView(arrangedSubviews: [header, message, retryButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        touchHold = NoticeTouchHold(view: self) { [weak self] in self?.onInteractionChange?($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let firstLineCenter = titleLabel.font.lineHeight / 2
        if dismissCenterOffset?.constant != firstLineCenter { dismissCenterOffset?.constant = firstLineCenter }
        let width = max(bounds.width - 24, 280)
        titleLabel.preferredMaxLayoutWidth = width
        messageLabel.preferredMaxLayoutWidth = width
    }

    func apply(message: String, colors: ComposerThemeColors) {
        if isHidden || messageLabel.text != message { messageView?.flashWhenOverflowing() }
        messageLabel.text = message
        titleLabel.textColor = colors.fg
        messageLabel.textColor = colors.fg
        retryButton.configuration?.baseForegroundColor = colors.fg
        dismissButton.tintColor = colors.comment
        backgroundColor = colors.bgDark
        titleLabel.preferredMaxLayoutWidth = 320
        messageLabel.preferredMaxLayoutWidth = 320
        isHidden = false
        invalidateIntrinsicContentSize()
    }
}

final class ComposerSendProgressView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let checkView = UIImageView()
    private let label = UILabel()
    /// The batch's share sent while a send uploads its attachments, in the
    /// spinner's place: each attachment shows its own ring, so the batch needs no
    /// full-width bar, only its words.
    private let ring = ProgressRingGlyph(lineWidth: 2)

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        checkView.contentMode = .scaleAspectFit
        label.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityIdentifier = "chat.sendProgress"
        ring.isHidden = true
        let stack = UIStackView(arrangedSubviews: [spinner, checkView, ring, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 12),
            checkView.heightAnchor.constraint(equalToConstant: 12),
            ring.widthAnchor.constraint(equalToConstant: 12),
            ring.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `fraction` swaps the spinner for the batch's ring; `isPaused` for a pause glyph.
    func apply(
        text: String?,
        isSending: Bool,
        colors: ComposerThemeColors,
        fraction: Double? = nil,
        isPaused: Bool = false
    ) {
        guard let text else {
            setHiddenIfChanged(true)
            spinner.stopAnimating()
            return
        }
        setHiddenIfChanged(false)
        label.text = text
        label.textColor = colors.comment
        spinner.color = colors.comment
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        ring.setHiddenIfChanged(isPaused || fraction == nil)
        if isPaused {
            spinner.stopAnimating()
            spinner.setHiddenIfChanged(true)
            checkView.setHiddenIfChanged(false)
            checkView.image = UIImage(systemName: "pause.circle", withConfiguration: config)
            checkView.tintColor = colors.comment
        } else if let fraction {
            spinner.stopAnimating()
            spinner.setHiddenIfChanged(true)
            checkView.setHiddenIfChanged(true)
            ring.apply(track: colors.comment.withAlphaComponent(0.3), arc: colors.blue, fraction: fraction)
        } else if isSending {
            spinner.startAnimating()
            checkView.setHiddenIfChanged(true)
            spinner.setHiddenIfChanged(false)
        } else {
            spinner.stopAnimating()
            spinner.setHiddenIfChanged(true)
            checkView.setHiddenIfChanged(false)
            checkView.image = UIImage(systemName: "checkmark.circle", withConfiguration: config)
            checkView.tintColor = colors.comment
        }
    }
}

extension UIView {
    /// Flips an arranged subview's hidden flag at once, never as a stack-view
    /// animation. An animated hide finishes later and can land after a newer
    /// flip: repeated hides during a rotation left the row hidden when focus
    /// showed it, and commenting with dictation (focus, comment mode, and
    /// dictation start back to back) left the action row and its items laid out
    /// as hidden while visible. Callers animate the resulting layout instead.
    func setHiddenIfChanged(_ hidden: Bool) {
        guard isHidden != hidden else { return }
        Self.performWithoutAnimation { isHidden = hidden }
    }
}

extension ComposerThemeColors {
    /// Used only before the first theme apply; never shown as a designed look.
    static var placeholder: ComposerThemeColors {
        let gray = UIColor.gray
        return ComposerThemeColors(
            bg: gray,
            bgDark: gray,
            bgHighlight: gray,
            fg: .label,
            fgDim: .secondaryLabel,
            comment: .tertiaryLabel,
            blue: .systemBlue,
            cyan: .systemCyan,
            green: .systemGreen,
            orange: .systemOrange,
            purple: .systemPurple,
            red: .systemRed,
            yellow: .systemYellow,
            scrim: gray,
            elevatedStroke: gray,
            floatingFill: gray
        )
    }
}
