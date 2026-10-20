import UIKit

/// Link detection for extension `ctx.ui.notify()` messages: http(s) links
/// only, never file or app URLs.
enum ExtensionNotifyChip {
    static func attributedMessage(_ message: String) -> AttributedString {
        var attributed = AttributedString(message)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let nsRange = NSRange(message.startIndex..., in: message)
        detector.enumerateMatches(in: message, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let stringRange = Range(match.range, in: message),
                  let url = URL(string: String(message[stringRange])),
                  Self.isHTTPURL(url),
                  let attributedRange = Range(stringRange, in: attributed)
            else { return }
            attributed[attributedRange].link = url
        }
        return attributed
    }

    static func containsHTTPLinks(_ attributed: AttributedString) -> Bool {
        attributed.runs.contains { run in
            guard let url = run.link else { return false }
            return isHTTPURL(url)
        }
    }

    fileprivate static func isHTTPURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    fileprivate static func iconName(for notifyType: String?) -> String {
        switch notifyType {
        case "error": "exclamationmark.circle.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "bell"
        }
    }

    fileprivate static func tint(for notifyType: String?, palette: ThemePalette) -> UIColor {
        let color = switch notifyType {
        case "error": palette.red
        case "warning": palette.orange
        default: palette.cyan
        }
        return UIColor(color)
    }
}

/// Strip pill for extension `ctx.ui.notify()`, on the above-composer row.
final class ExtensionNotifyChipView: ExtensionStripPillControl {
    var onToggleExpanded: (() -> Void)?
    private let icon = UIImageView()
    private let nameLabel = ExtensionChromeFont.label(.caption1, .semibold)
    private let countLabel = ExtensionChromeFont.label(.caption2, .semibold)
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        for view in [icon, nameLabel, countLabel, chevron] {
            row.addArrangedSubview(view)
        }
        accessibilityIdentifier = "chat.extensionNotify.chip"
        addAction(UIAction { [weak self] _ in self?.onToggleExpanded?() }, for: .touchUpInside)
    }

    func apply(_ state: ExtensionNotifyChipStore.SessionState, palette: ThemePalette) {
        let newest = state.newest
        let tint = ExtensionNotifyChip.tint(for: newest.notifyType, palette: palette)
        icon.image = UIImage.scaledSymbol(ExtensionNotifyChip.iconName(for: newest.notifyType), style: .caption1, weight: .bold, color: tint)
        nameLabel.text = newest.extensionDisplayName
        nameLabel.textColor = UIColor(palette.fg)
        countLabel.text = "\(state.count)"
        countLabel.textColor = UIColor(palette.comment)
        countLabel.isHidden = state.count <= 1
        chevron.image = UIImage.scaledSymbol(state.isExpanded ? "chevron.down" : "chevron.right", style: .caption2, weight: .bold, color: UIColor(palette.comment))
        surface.apply(palette: palette, active: state.isExpanded ? tint : nil)

        let base = "Notification from \(newest.extensionDisplayName): \(newest.message)"
        accessibilityLabel = state.count > 1 ? "\(base). \(state.count) notifications" : base
        accessibilityHint = state.isExpanded ? "Collapses the notification" : "Expands the notification"
        accessibilityValue = state.isExpanded ? "Expanded" : "Collapsed"
    }
}

/// Drawer under the above-composer strip for extension `ctx.ui.notify()`:
/// who sent it, collapse and dismiss, then every notification, newest first.
final class ExtensionNotifyDrawerView: ExtensionDrawerPanelView {
    var onCollapse: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenURL: ((URL) -> Bool)?

    private let titleLabel = ExtensionChromeFont.label(.subheadline, .semibold)
    private let countLabel = ExtensionChromeFont.label(.caption1)
    private let collapseButton = UIButton(type: .custom)
    private let dismissButton = UIButton(type: .custom)
    private let entries = UIStackView()
    private var shown: (state: ExtensionNotifyChipStore.SessionState, themeID: ThemeID)?

    init() {
        super.init(spacing: 10)
        accessibilityIdentifier = "chat.extensionNotify.expanded"
        collapseButton.accessibilityLabel = "Collapse notification"
        collapseButton.addAction(UIAction { [weak self] _ in self?.onCollapse?() }, for: .touchUpInside)
        dismissButton.accessibilityLabel = "Dismiss"
        dismissButton.accessibilityIdentifier = "chat.extensionNotify.dismiss"
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
        for button in [collapseButton, dismissButton] {
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 32),
            ])
        }
        let titles = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        titles.axis = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = UIStackView(arrangedSubviews: [titles, collapseButton, dismissButton])
        header.axis = .horizontal
        header.alignment = .top
        header.spacing = 10

        entries.axis = .vertical
        entries.alignment = .fill
        entries.spacing = 10
        let list = CappedScrollView(content: entries, maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight)
        list.scrollView.accessibilityIdentifier = "chat.extensionNotify.list"

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ state: ExtensionNotifyChipStore.SessionState, themeID: ThemeID) {
        guard shown?.state != state || shown?.themeID != themeID else { return }
        shown = (state, themeID)
        let palette = themeID.palette
        surface.apply(palette: palette)
        titleLabel.text = "From extension · \(state.newest.extensionDisplayName)"
        titleLabel.textColor = UIColor(palette.fg)
        countLabel.text = "\(state.count) notifications"
        countLabel.textColor = UIColor(palette.comment)
        countLabel.isHidden = state.count <= 1

        var collapse = UIButton.Configuration.plain()
        collapse.image = UIImage.scaledSymbol("chevron.up", style: .caption1, weight: .bold, color: UIColor(palette.comment))
        collapse.background.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.04)
        collapse.background.cornerRadius = 16
        collapse.contentInsets = .zero
        collapseButton.configuration = collapse
        var dismiss = UIButton.Configuration.plain()
        dismiss.image = UIImage.scaledSymbol("xmark", style: .caption1, weight: .bold, color: UIColor(palette.fgDim))
        dismiss.contentInsets = .zero
        dismissButton.configuration = dismiss

        for view in entries.arrangedSubviews { view.removeFromSuperview() }
        let showsNames = Set(state.entries.map(\.extensionDisplayName)).count > 1
        for (index, entry) in state.entries.enumerated() {
            entries.addArrangedSubview(entryView(entry, showsName: showsNames && index > 0, palette: palette))
        }
    }

    private func entryView(
        _ entry: ExtensionNotifyChipStore.Entry,
        showsName: Bool,
        palette: ThemePalette
    ) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        if showsName {
            let name = ExtensionChromeFont.label(.caption2)
            name.text = "From extension · \(entry.extensionDisplayName)"
            name.textColor = UIColor(palette.fgDim)
            stack.addArrangedSubview(name)
        }
        let attributed = ExtensionNotifyChip.attributedMessage(entry.message)
        let message = ExtensionNativeLinkTextView()
        let text = NSMutableAttributedString(attributed)
        text.addAttributes([
            .font: UIFont.scaled(.footnote),
            .foregroundColor: UIColor(palette.fg),
        ], range: NSRange(location: 0, length: text.length))
        message.attributedText = text
        message.linkTextAttributes = [.foregroundColor: UIColor(palette.blue)]
        message.openURL = { [weak self] url in
            guard ExtensionNotifyChip.isHTTPURL(url) else { return }
            _ = self?.onOpenURL?(url)
        }
        stack.addArrangedSubview(message)
        if !ExtensionNotifyChip.containsHTTPLinks(attributed) {
            stack.isAccessibilityElement = true
            stack.accessibilityLabel = "From extension · \(entry.extensionDisplayName). \(entry.message)"
        }
        return stack
    }
}
