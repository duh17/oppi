import UIKit

/// The sideways swipe that moves a Rex terminal to the previous or next pane
/// of its session. A pan, not `UISwipeGestureRecognizer`, so a diagonal scroll
/// of the history cannot change pane: it must start mostly sideways and end
/// far enough, or fast enough, along the same axis. The screen follows the
/// finger while it moves (`SSHTerminalPaneTransition`) and this type decides
/// what letting go does.
enum SSHTerminalPaneSwipe {
    /// The back swipe owns the screen's left edge.
    static let edgeInset: CGFloat = 24
    static let minimumTravel: CGFloat = 56
    static let flickTravel: CGFloat = 24
    static let flickVelocity: CGFloat = 600
    /// How much farther a swipe goes along an axis than across it.
    static let dominance: CGFloat = 2

    /// What letting go of a drag does.
    enum Release: Equatable {
        /// Show the pane `step` places along (+1 next, -1 previous).
        case commit(step: Int)
        /// Put the screen back: too short and slow, against the edge, or
        /// thrown back the way it came.
        case springBack
    }

    /// Whether a pan that starts with `velocity` is a sideways swipe.
    static func begins(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * dominance
    }

    /// The pane step a finished pan asks for: +1 (next) for a swipe to the
    /// left, -1 (previous) for a swipe to the right, nil for anything that
    /// was not a clear sideways swipe.
    static func step(translation: CGPoint, velocity: CGPoint) -> Int? {
        guard abs(translation.x) > abs(translation.y) * dominance else { return nil }
        let far = abs(translation.x) >= minimumTravel
        let flicked = abs(translation.x) >= flickTravel && abs(velocity.x) >= flickVelocity
        guard far || flicked else { return nil }
        return direction(of: translation.x)
    }

    /// The step a drag of `translation` points sideways is heading for.
    static func direction(of translation: CGFloat) -> Int { translation < 0 ? 1 : -1 }

    /// What letting go does. `canStep` says whether a pane lies that way: a
    /// swipe against the first or last pane springs back, as does a fast
    /// throw the opposite way from the drag.
    static func release(translation: CGPoint, velocity: CGPoint, canStep: (Int) -> Bool) -> Release {
        guard let step = step(translation: translation, velocity: velocity), canStep(step) else { return .springBack }
        let thrownBack = abs(velocity.x) >= flickVelocity && direction(of: velocity.x) != step
        return thrownBack ? .springBack : .commit(step: step)
    }

    /// How far the screen sits from rest for a finger `translation` points
    /// from where the swipe began. It follows the finger one to one while a
    /// pane lies that way, and gives way like a scroll view's edge when none
    /// does.
    static func offset(translation: CGFloat, width: CGFloat, canStep: Bool) -> CGFloat {
        guard canStep else { return rubberBand(translation, width: width) }
        return min(max(translation, -width), width)
    }

    /// UIScrollView's edge resistance: close to the finger at first, never
    /// past `width`.
    static func rubberBand(_ distance: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let banded = width * (1 - 1 / (abs(distance) * 0.55 / width + 1))
        return distance < 0 ? -banded : banded
    }
}

/// What the grid asks of a Rex terminal's session for the swipe and
/// VoiceOver's Next and Previous Pane: set while the session has more than one
/// pane. Both read and move along the strip's order from the pane last asked for.
@MainActor
struct SSHTerminalPaneStepping {
    /// The name of the pane `delta` places along, nil past either end.
    var neighbour: (Int) -> String?
    /// Shows the pane `delta` places along; false past either end.
    var step: (Int) -> Bool
    /// The pane last asked for: the one whose snapshot ends a switch.
    var shown: () -> String?
}

/// The bar's pane switcher menu: the session's panes in strip order, the
/// shown one checked, one section per window when the session has more than
/// one. Choosing one shows it through the owner that a swipe uses.
@MainActor
enum SSHTerminalRexPaneMenu {
    static func elements(state: RexSessionState, select: @escaping (String) -> Void) -> [UIMenuElement] {
        let actions = state.panes.enumerated().map { index, pane in
            let action = UIAction(title: pane.name, state: pane.blockID == state.shown ? .on : .off) { _ in select(pane.blockID) }
            action.accessibilityIdentifier = "sshTerminal.rexPanes.\(index)"
            return (pane.windowID, pane.windowName, action)
        }
        guard state.namesWindows else { return actions.map { $0.2 } }
        var sections: [(id: String?, name: String?, actions: [UIAction])] = []
        for (id, name, action) in actions {
            if let last = sections.last, last.id == id {
                sections[sections.count - 1].actions.append(action)
            } else {
                sections.append((id, name, [action]))
            }
        }
        return sections.map { UIMenu(title: $0.name ?? "", options: .displayInline, children: $0.actions) }
    }
}

/// The icon a pane has in the bar's switcher. One rule for every pane, with
/// no knowledge of any program: a pane whose program reports status (OSC
/// 7501) is a monogram tile of the first character of its name, which is the
/// program's own mark when it puts one first in its title (`π - …`, `✳ …`);
/// a plain shell, and a program with nothing to start a monogram from, is the
/// terminal glyph.
enum SSHTerminalPaneIcon: Equatable {
    case terminal
    case monogram(String)

    static let terminalSymbol = "terminal.fill"

    /// `program` is `RexSessionState.Pane.program`. The monogram is its first
    /// character that is not white space, uppercased when it is a lowercase
    /// Latin letter and its capital is one character (`ß` stays `ß`). Other
    /// scripts and symbols keep what they are: `π` is a mark (the pi agent's),
    /// not an initial.
    init(program: String?) {
        guard let first = program?.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            self = .terminal
            return
        }
        let latinLowercase = first.unicodeScalars.first.map {
            $0.value < 0x250 && $0.properties.generalCategory == .lowercaseLetter
        } ?? false
        let capital = first.uppercased()
        self = .monogram(latinLowercase && capital.count == 1 ? capital : String(first))
    }

    /// An emoji already is a picture: a character that is an emoji by default,
    /// or one that asked for it (`⚠️`, with U+FE0F). It is drawn in its own
    /// colors, with no tile to cut it from.
    var isPicture: Bool {
        guard case .monogram(let letter) = self else { return false }
        return letter.unicodeScalars.first?.properties.isEmojiPresentation == true
            || letter.unicodeScalars.contains { $0.value == 0xFE0F }
    }

    /// The terminal symbol's canvas, and the part of it that is drawn. A
    /// monogram is drawn in the same part, so the two weigh the same in the
    /// pill (the symbol's canvas has padding around its glyph).
    @MainActor
    private static let terminalMetrics: (canvas: CGSize, drawn: CGRect) = {
        let glyph = UIImage(systemName: terminalSymbol, withConfiguration: SSHTerminalPillButton.symbolConfiguration)
        guard let glyph, glyph.size != .zero else {
            let canvas = CGSize(width: 20, height: 16)
            return (canvas, CGRect(origin: .zero, size: canvas))
        }
        return (glyph.size, drawnBounds(of: glyph))
    }()

    /// Where `image` has pixels (alpha above a hair), in points, in its own
    /// coordinates. An image with none gives a zero rect.
    @MainActor
    static func drawnBounds(of image: UIImage) -> CGRect {
        let format = UIGraphicsImageRendererFormat.default()
        format.preferredRange = .standard
        let raster = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
        guard let cg = raster.cgImage else { return .zero }
        // Redrawn into RGBA of our own, whose layout is known: a renderer's varies.
        let (width, height) = (cg.width, cg.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return .zero }
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        let scale = raster.scale
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// The icon as an image on the terminal symbol's canvas, drawn where the
    /// symbol's glyph is. A monogram is a template, cut out of a rounded tile
    /// the way the glyph's prompt is; a picture keeps its colors.
    @MainActor
    func image() -> UIImage {
        let glyph = UIImage(systemName: Self.terminalSymbol, withConfiguration: SSHTerminalPillButton.symbolConfiguration)
            ?? UIImage()
        guard case .monogram(let letter) = self else { return glyph.withRenderingMode(.alwaysTemplate) }
        let (canvas, tile) = Self.terminalMetrics
        let renderer = UIGraphicsImageRenderer(size: canvas)
        func draw(_ text: NSAttributedString) {
            let box = text.size()
            text.draw(at: CGPoint(x: tile.midX - box.width / 2, y: tile.midY - box.height / 2))
        }
        if isPicture {
            // Drawn big, measured, and fitted into the glyph's place: an emoji's
            // own box is not the picture's.
            let side: CGFloat = 64
            let big = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                let text = NSAttributedString(string: letter, attributes: [.font: UIFont.systemFont(ofSize: side * 0.6)])
                let box = text.size()
                text.draw(at: CGPoint(x: (side - box.width) / 2, y: (side - box.height) / 2))
            }
            let found = Self.drawnBounds(of: big)
            guard !found.isEmpty else { return glyph.withRenderingMode(.alwaysTemplate) }
            let scale = min(tile.width / found.width, tile.height / found.height)
            return renderer.image { _ in
                big.draw(in: CGRect(
                    x: tile.midX - found.midX * scale, y: tile.midY - found.midY * scale,
                    width: side * scale, height: side * scale
                ))
            }.withRenderingMode(.alwaysOriginal)
        }
        return renderer.image { context in
            UIColor.black.setFill()
            UIBezierPath(roundedRect: tile, cornerRadius: tile.height * 0.28).fill()
            let font = UIFont.systemFont(ofSize: tile.height * 0.68, weight: .bold)
            // A mark that can also be an emoji (`✳`) is asked for in its text form,
            // so it is cut out as a mark, not as the emoji's silhouette.
            let scalars = letter.unicodeScalars
            let canBeEmoji = scalars.first?.properties.isEmoji == true && !scalars.contains { $0.value == 0xFE0E }
            context.cgContext.setBlendMode(.destinationOut)
            draw(NSAttributedString(string: canBeEmoji ? letter + "\u{FE0E}" : letter, attributes: [.font: font, .foregroundColor: UIColor.black]))
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// The bar's pane switcher: one button in the trailing pill, beside Rex's
/// sessions, for a session with more than one pane. It draws the shown pane's
/// icon (`SSHTerminalPaneIcon`), which rolls to the next pane's when the pane
/// changes (up for a pane further along the strip, down for one before it; a
/// crossfade with Reduce Motion), and opens a menu of the session's panes.
final class SSHTerminalRexPanesButton: SSHTerminalPillButton {
    private let glyph = SSHTerminalRexPaneGlyphView()
    private var shownBlock: String?
    private var shownIndex: Int?
    /// The icon the Large Content Viewer shows, so it is made when the icon changes.
    private var largeIcon: SSHTerminalPaneIcon?

    /// The icon on show, for a test.
    var icon: SSHTerminalPaneIcon { glyph.icon }

    init() {
        super.init(image: nil, label: "Pane", identifier: "sshTerminal.bar.rexPanes")
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showsMenuAsPrimaryAction = true
        preferredMenuElementOrder = .fixed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The menu lists the session as it is when the button opens.
    func installMenu(state: @escaping () -> RexSessionState?, select: @escaping (String) -> Void) {
        menu = UIMenu(children: [UIDeferredMenuElement.uncached { completion in
            completion(state().map { SSHTerminalRexPaneMenu.elements(state: $0, select: select) } ?? [])
        }])
    }

    /// Draws the shown pane. Hidden for a session of one pane.
    func apply(state: RexSessionState?, tint: UIColor) {
        glyph.tintColor = tint
        guard let state, state.showsSwitcher, let index = state.shownIndex else {
            isHidden = true
            shownBlock = nil
            shownIndex = nil
            return
        }
        let wasShown = !isHidden
        isHidden = false
        let icon = SSHTerminalPaneIcon(program: state.panes[index].program)
        // The label is the button's purpose; the value is the pane and where it is.
        accessibilityValue = "\(state.shownName), \(index + 1) of \(state.panes.count)"
        largeContentTitle = state.shownName
        if icon != largeIcon {
            largeIcon = icon
            largeContentImage = icon.image()
        }
        if wasShown, let shownBlock, shownBlock != state.shown, window != nil {
            glyph.roll(toward: index > (shownIndex ?? index) ? 1 : -1, to: icon)
        } else {
            // The same pane, or the first draw: a program that starts or stops
            // reporting changes the icon in place.
            glyph.show(icon)
        }
        shownBlock = state.shown
        shownIndex = index
    }
}

/// The switcher's icon, and the roll between one pane's icon and the next.
final class SSHTerminalRexPaneGlyphView: UIView {
    /// How far an icon travels while it leaves or arrives.
    static let travel: CGFloat = 10
    static let duration: TimeInterval = 0.25

    private(set) var icon = SSHTerminalPaneIcon.terminal

    private func makeImageView(_ icon: SSHTerminalPaneIcon) -> UIImageView {
        let view = UIImageView(image: icon.image())
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .center
        view.isAccessibilityElement = false
        return view
    }

    private lazy var current = makeImageView(icon)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pin(current)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func pin(_ view: UIImageView) {
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 24, height: 24) }

    /// Draws `icon` now, with no roll.
    func show(_ next: SSHTerminalPaneIcon) {
        guard next != icon else { return }
        icon = next
        current.image = next.image()
    }

    /// The icon rolls up for `direction` +1 (the old one leaves upward, the new
    /// one comes from below) and down for -1. An earlier roll still running
    /// ends where it was going.
    func roll(toward direction: Int, to next: SSHTerminalPaneIcon) {
        for stale in subviews where stale !== current { stale.removeFromSuperview() }
        let leaving = current
        icon = next
        let arriving = makeImageView(next)
        current = arriving
        pin(arriving)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let shift = reduceMotion ? 0 : CGFloat(direction) * Self.travel
        arriving.alpha = 0
        arriving.transform = CGAffineTransform(translationX: 0, y: shift)
        UIView.animate(withDuration: reduceMotion ? 0.2 : Self.duration, delay: 0, options: .curveEaseOut) {
            leaving.alpha = 0
            leaving.transform = CGAffineTransform(translationX: 0, y: -shift)
            arriving.alpha = 1
            arriving.transform = .identity
        } completion: { _ in
            leaving.removeFromSuperview()
        }
    }
}

/// The layout minimap, at the grid's top right: the shown pane's window as
/// one rounded cell per pane at its place in the layout, the shown one in the
/// accent color, the others gray. A cell is a button that shows its pane. The
/// accent highlight is one view that moves to the new pane's cell when the
/// pane changes. Drawn for a window with more than one pane.
final class SSHTerminalRexMinimapView: UIView {
    static let size = CGSize(width: 76, height: 48)
    static let moveDuration: TimeInterval = 0.25
    private static let padding: CGFloat = 4
    private static let gap: CGFloat = 1.5

    private let backdrop = UIView()
    /// The shown cell's accent, above the gray cells.
    private let highlight = UIView()
    private var cells: [(cell: RexSessionLayout.Cell, button: UIButton)] = []
    private var shown: String?
    /// Asks to show a pane: the same request a swipe or a menu choice makes.
    var select: (String) -> Void = { _ in }

    /// Where the highlight is, for a test to read while it moves.
    var highlightFrame: CGRect { highlight.frame }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.layer.cornerRadius = 8
        backdrop.layer.cornerCurve = .continuous
        backdrop.isUserInteractionEnabled = false
        highlight.layer.cornerRadius = 3
        highlight.layer.cornerCurve = .continuous
        highlight.isUserInteractionEnabled = false
        addSubview(backdrop)
        addSubview(highlight)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Pane layout"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(state: RexSessionState, shownTint: UIColor, otherTint: UIColor, backdropColor: UIColor) {
        let sameCells = state.minimap == cells.map(\.cell)
        if !sameCells {
            cells.forEach { $0.button.removeFromSuperview() }
            cells = state.minimap.enumerated().map { index, cell in
                let button = UIButton(type: .custom)
                button.layer.cornerRadius = 3
                button.layer.cornerCurve = .continuous
                button.accessibilityIdentifier = "sshTerminal.rexMinimap.\(index)"
                button.addAction(UIAction { [weak self] _ in self?.select(cell.blockID) }, for: .touchUpInside)
                insertSubview(button, belowSubview: highlight)
                return (cell, button)
            }
            setNeedsLayout()
        }
        backdrop.backgroundColor = backdropColor
        highlight.backgroundColor = shownTint
        for (cell, button) in cells {
            let isShown = cell.blockID == state.shown
            button.backgroundColor = otherTint
            button.accessibilityLabel = state.panes.first { $0.blockID == cell.blockID }?.name ?? "Terminal"
            button.accessibilityTraits = isShown ? [.button, .selected] : .button
        }
        let moved = shown != state.shown
        shown = state.shown
        guard moved else { return }
        // The same window with another pane shown: the highlight moves. A new
        // window's cells (or the first draw) just appear.
        let animated = sameCells && window != nil && !UIAccessibility.isReduceMotionEnabled
        placeHighlight(animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        for (cell, button) in cells {
            button.frame = CGRect(
                x: area.minX + cell.rect.minX * area.width,
                y: area.minY + cell.rect.minY * area.height,
                width: cell.rect.width * area.width,
                height: cell.rect.height * area.height
            ).insetBy(dx: Self.gap, dy: Self.gap)
        }
        if highlight.layer.animationKeys()?.isEmpty ?? true { placeHighlight(animated: false) }
    }

    private func placeHighlight(animated: Bool) {
        guard let target = cells.first(where: { $0.cell.blockID == shown })?.button.frame else {
            highlight.isHidden = true
            return
        }
        highlight.isHidden = false
        guard animated else {
            highlight.frame = target
            return
        }
        UIView.animate(withDuration: Self.moveDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.highlight.frame = target
        }
    }
}
