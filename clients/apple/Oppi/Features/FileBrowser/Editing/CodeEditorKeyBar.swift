import UIKit

/// Keys above the software keyboard: the user's chosen keys scroll sideways
/// beside a pinned Hide Keyboard key. Arrow keys repeat while held. Key
/// chrome and the sideways-swipe scroller are the SSH terminal's, so both
/// key bars press and scroll the same way.
final class CodeEditorKeyBar: UIView {
    var onKey: (CodeEditorBarKey) -> Void = { _ in }
    var onHideKeyboard: () -> Void = {}

    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let fill = UIView()
    private let scroll = SSHTerminalKeyScrollView()
    private let row = UIStackView()
    private let hide = SSHTerminalKeyButton()
    private var colors = ComposerThemeColors.placeholder
    private var shownKeys: [CodeEditorBarKey] = []
    private var repeatTimer: Timer?
    private var repeatDelay: Timer?

    private static let height: CGFloat = 50

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.height))
        autoresizingMask = [.flexibleWidth]
        accessibilityIdentifier = "workspace-file-editor.key-bar"
        glass.isUserInteractionEnabled = false
        fill.isUserInteractionEnabled = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.blocksScrolling = { [weak self] in self?.repeatTimer != nil }
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        hide.accessibilityIdentifier = "workspace-file-editor.key.hide-keyboard"
        hide.accessibilityLabel = String(localized: "Hide Keyboard")
        hide.addAction(UIAction { [weak self] _ in self?.onHideKeyboard() }, for: .touchUpInside)

        for view in [glass, fill, scroll, row, hide] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(glass)
        addSubview(fill)
        addSubview(scroll)
        scroll.addSubview(row)
        addSubview(hide)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            hide.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 2),
            hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    func apply(keys: [CodeEditorBarKey], foreground: UIColor, background: UIColor) {
        tintColor = foreground
        fill.backgroundColor = background.withAlphaComponent(0.55)
        let colorsChanged = colors.fg != foreground
        colors.fg = foreground
        hide.apply(title: nil, systemImage: "keyboard.chevron.compact.down", colors: colors)
        guard keys != shownKeys || colorsChanged else { return }
        shownKeys = keys
        stopRepeating()
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in keys {
            let button = SSHTerminalKeyButton()
            button.apply(title: key.title, systemImage: key.systemImage, colors: colors, compactTitle: key.title?.count == 1)
            button.accessibilityIdentifier = "workspace-file-editor.key.\(key.id)"
            button.accessibilityLabel = key.label
            if key.repeats {
                button.addAction(UIAction { [weak self] _ in self?.startRepeating(key) }, for: .touchDown)
                for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
                    button.addAction(UIAction { [weak self] _ in self?.stopRepeating() }, for: event)
                }
            } else {
                button.addAction(UIAction { [weak self] _ in self?.onKey(key) }, for: .touchUpInside)
            }
            row.addArrangedSubview(button)
        }
    }

    private func startRepeating(_ key: CodeEditorBarKey) {
        stopRepeating()
        onKey(key)
        repeatDelay = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repeatDelay = nil
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onKey(key) }
                }
            }
        }
    }

    private func stopRepeating() {
        repeatDelay?.invalidate()
        repeatDelay = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopRepeating() }
    }
}
