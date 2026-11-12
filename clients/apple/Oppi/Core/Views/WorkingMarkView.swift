import UIKit

/// The still "agent is working" mark for every surface outside the focused
/// chat: session rows, Thread strips, the workspace sidebar, the terminal's
/// program status, and schedules. The focused chat's working row keeps the
/// animated `WorkingSpinnerUIView`; this mark is one frame of the same style,
/// so the two read as one indicator.
///
/// It is a cached image and never redraws on its own: no display link, timer,
/// or Metal layer, so a list of working sessions costs nothing per frame. It
/// draws again only when the chosen style, the tint, the theme, or the text
/// size changes. The orb styles draw the orb's Reduce Motion frame (bolder than
/// the animated dots, which a still frame cannot rely on motion to show),
/// braille draws its first frame, and Game of Life draws a glider.
///
/// The mark is as tall as `textStyle`'s line, so it stands in for a word on
/// that line without changing the line's height, and follows Dynamic Type. It
/// is not an accessibility element; the element that contains it speaks
/// `spokenLabel`.
final class WorkingMarkView: UIImageView {
    /// What VoiceOver says for a working agent wherever this mark shows.
    static let spokenLabel = String(localized: "Working")

    private let textStyle: UIFont.TextStyle
    private var tint: UIColor = .systemBlue
    private var palette: ThemePalette?
    private(set) var style = SpinnerStyle.current
    nonisolated(unsafe) private var styleObserver: NSObjectProtocol?

    /// The mark's side: the line height of its text style at this view's text size.
    var side: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection).lineHeight)
    }

    init(textStyle: UIFont.TextStyle) {
        self.textStyle = textStyle
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityLabel = Self.spokenLabel
        contentMode = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        let traits: [UITrait] = [UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]
        registerForTraitChanges(traits) { (view: Self, _) in
            view.invalidateIntrinsicContentSize()
            view.render()
        }
        // "queue: .main": a style change can be posted from any thread.
        styleObserver = NotificationCenter.default.addObserver(
            forName: AppPreferenceStore.Appearance.spinnerDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.style = SpinnerStyle.current
                self.render()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: side, height: side)
    }

    /// Colors for `tint` over `palette`'s page.
    func apply(tint: UIColor, palette: ThemePalette) {
        self.tint = tint
        self.palette = palette
        render()
    }

    private func render() {
        guard let palette else { return }
        let key = WorkingMarkImage.Key(
            style: style,
            tint: tint.resolvedColor(with: traitCollection),
            accents: [palette.blue, palette.cyan, palette.purple, palette.orange]
                .map { $0.resolvedColor(with: traitCollection) },
            isDark: WorkingMarkImage.isDark(palette.ui.bg.resolvedColor(with: traitCollection)),
            side: side
        )
        let next = WorkingMarkImage.image(for: key)
        if image !== next { image = next }
    }
}

/// The still mark's images, drawn once per style, colors, and size and shared
/// by every mark on screen.
@MainActor
enum WorkingMarkImage {
    struct Key: Hashable {
        let style: SpinnerStyle
        let tint: UIColor
        let accents: [UIColor]
        let isDark: Bool
        let side: CGFloat
    }

    private static var cache: [Key: UIImage] = [:]

    static func isDark(_ background: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return OrbTint.isDarkBackground(red: red, green: green, blue: blue)
    }

    static func image(for key: Key) -> UIImage {
        if let image = cache[key] { return image }
        // A handful of styles, themes, and text sizes: the cache stays small,
        // and a theme switch starts it over.
        if cache.count > 64 { cache.removeAll() }
        let size = CGSize(width: key.side, height: key.side)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            switch key.style {
            case .brailleDots: drawBraille(key, in: size)
            case .gameOfLife: drawGlider(key, in: context.cgContext, size: size)
            case .working, .searching, .solving: drawOrb(key, in: context.cgContext, size: size)
            }
        }
        cache[key] = image
        return image
    }

    /// The orb's Reduce Motion frame, laid out as the Metal view lays it out,
    /// with each dot fuller and larger than the shader draws it: the animated
    /// orb reads through motion, and a still frame at line height needs weight.
    private static func drawOrb(_ key: Key, in context: CGContext, size: CGSize) {
        guard let orbStyle = key.style.orbStyle else { return }
        let sizeClass = OrbSizeClass.workingCompact
        let frame = OrbGeometry.frame(
            style: orbStyle, sizeClass: sizeClass, size: sizeClass.designSize,
            geometryTime: OrbDisplayPolicy.reduceMotionTime
        )
        let scale = size.width / sizeClass.designSize
        let tint = rgb(key.tint)
        let accents = key.accents.map(rgb)
        for dot in frame.dots {
            let accent = accents[min(max(Int(dot.palette.rounded()), 0), accents.count - 1)]
            let mix = min(max(dot.accent, 0), 1)
            let hue = (0..<3).map { tint[$0] + (accent[$0] - tint[$0]) * mix }
            let amount = min(max(1 - dot.white, 0), 1)
            let rgb = key.isDark
                ? hue.map { $0 * (0.6 + 0.4 * amount) }
                : hue.map { 1 + ($0 - 1) * (0.75 + 0.25 * amount) }
            context.setFillColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 0.55 + 0.45 * min(max(dot.a, 0), 1))
            let radius = max(dot.r * scale * 1.35, 0.6)
            context.fillEllipse(in: CGRect(
                x: dot.x * scale - radius, y: dot.y * scale - radius, width: radius * 2, height: radius * 2
            ))
        }
    }

    /// Braille's first frame, filling the line in the spinner's monospaced font.
    private static func drawBraille(_ key: Key, in size: CGSize) {
        let font = UIFont.monospacedSystemFont(ofSize: size.height * 0.9, weight: .semibold)
        let text = NSAttributedString(string: BrailleSpinnerUIView.brailleFrames[0], attributes: [
            .font: font, .foregroundColor: key.tint,
        ])
        let bounds = text.size()
        text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
    }

    /// A Game of Life glider in the tint, filling the line.
    private static func drawGlider(_ key: Key, in context: CGContext, size: CGSize) {
        let cells = [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)]
        let pitch = size.width / 3.4
        let inset = max(pitch * 0.12, 0.5)
        let origin = (size.width - pitch * 3) / 2
        context.setFillColor(key.tint.cgColor)
        for (column, row) in cells {
            let rect = CGRect(
                x: origin + CGFloat(column) * pitch, y: origin + CGFloat(row) * pitch, width: pitch, height: pitch
            ).insetBy(dx: inset, dy: inset)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: inset).cgPath)
        }
        context.fillPath()
    }

    private static func rgb(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue]
    }
}
