import UIKit

/// Session-list bottom chrome shared by All Sessions and workspace lists.
/// Search lives in the navigation-bar drawer and reveals by pulling the list.
/// The leading Quick Session control is one toolbar capsule — optional leading
/// mic plus placeholder — matching the chat composer. Tapping the capsule
/// presents Quick Session; tapping the mic starts dictation there. The trailing
/// capsule is folder only so Files opens from the same side the browser pushes.
enum SessionInboxComposeChrome {
    static let compactBarPlaceholder = "Message"
    static let compactBarMicWidth: CGFloat = 44
    static let compactBarHitHeight: CGFloat = 44
    /// Trailing folder capsule plus bar gutters. The leading Message capsule
    /// uses the rest of the screen so it covers the session-row title.
    static let messageCapsuleFolderReserve: CGFloat = 120
    /// Bar gutters only, for a bottom bar with no trailing folder capsule.
    static let messageCapsuleSoloReserve: CGFloat = 40
    /// Narrowest expanded Message capsule on compact splits.
    static let messageCapsuleMinWidthFloor: CGFloat = 180

    /// Grow the Message capsule at compact width. Keep it intrinsic at regular
    /// width (iPad, the iPhone Duo inner display), and while now-playing shares
    /// the bottom bar.
    static func expandsMessageCapsule(
        horizontalSizeClass: UIUserInterfaceSizeClass?,
        hasActivePlayback: Bool
    ) -> Bool {
        guard !hasActivePlayback else { return false }
        return horizontalSizeClass != .regular
    }

    /// Finite min width so the leading capsule covers the title line without
    /// stretching regular iPad to the remaining bar width.
    static func messageCapsuleMinWidth(
        screenWidth: CGFloat,
        expands: Bool,
        reserve: CGFloat = messageCapsuleFolderReserve
    ) -> CGFloat? {
        guard expands else { return nil }
        guard screenWidth > 0 else { return messageCapsuleMinWidthFloor }
        return max(messageCapsuleMinWidthFloor, screenWidth - reserve)
    }

    /// Mic is a one-tap path into Quick Session. Hide it when now-playing
    /// already owns the bar.
    static func showsDictationShortcut(hasActivePlayback: Bool) -> Bool {
        !hasActivePlayback
    }

    /// Folder stays in the trailing capsule on both lists. Enabled whenever a
    /// server is connected. Workspace lists open workspace files; All Sessions
    /// opens the connected server's home directory.
    static func canOpenFiles(hasServer: Bool) -> Bool {
        hasServer
    }
}

/// All Sessions searches every workspace. A workspace list stays in that workspace.
enum SessionInboxSearchScope {
    static func workspaceId(scopedTo workspaceId: String?) -> String? {
        let trimmed = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Collapsed session-list compose launcher, the bottom bar's leading item. Not a
/// live text field: a tap presents Quick Session, which owns the real composer,
/// and the mic starts dictation there. One accessibility element, labeled "Start
/// Quick Session", with the mic as a custom action while the mic shows.
///
/// At compact width the capsule has a fixed width (`SessionInboxComposeChrome.messageCapsuleMinWidth`)
/// so it covers the row title under it; at regular width, or while now-playing
/// shares the bar, it is as wide as its content. A bar item reports that size as
/// the view's intrinsic size, so a change re-measures it.
@MainActor
final class SessionInboxMessageCapsule: UIControl {
    /// What the bar pass decides the capsule draws.
    struct Content: Equatable {
        var showsDictation: Bool
        var hasActivePlayback = false
        /// The list column's width, which sizes the capsule at compact width.
        var columnWidth: CGFloat = 0
        /// Width kept free beside the capsule: the folder capsule by default.
        var trailingReserve = SessionInboxComposeChrome.messageCapsuleFolderReserve
        var placeholder = SessionInboxComposeChrome.compactBarPlaceholder
    }

    private static let edgePadding: CGFloat = 16

    private let micButton = UIButton(type: .custom)
    private let placeholderLabel = UILabel()
    private var content: Content
    private let onDictate: () -> Void

    /// `onStart` runs for a tap on the capsule, `onDictate` for a tap on the mic.
    init(content: Content, onStart: @escaping () -> Void, onDictate: @escaping () -> Void) {
        self.content = content
        self.onDictate = onDictate
        super.init(frame: .zero)
        // A bar item sizes its custom view from its intrinsic size; with the
        // autoresizing mask on, the empty frame wins and the capsule collapses.
        translatesAutoresizingMaskIntoConstraints = false
        addAction(UIAction { _ in onStart() }, for: .touchUpInside)

        placeholderLabel.font = .scaled(.subheadline)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.numberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)

        // Drawn at its own point size, centered: the symbol is not scaled a second time
        // on top of the capsule's content-size category (see `updateMicImage`).
        micButton.imageView?.contentMode = .center
        updateMicImage()
        micButton.addAction(UIAction { [weak self] _ in self?.onDictate() }, for: .touchUpInside)
        // The capsule is the one accessibility element; the mic is its custom action.
        micButton.isAccessibilityElement = false
        micButton.accessibilityIdentifier = "workspace.quickSession.dictate"
        addSubview(micButton)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Start Quick Session")
        accessibilityIdentifier = "workspace.quickSession.start"
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]) {
            (capsule: SessionInboxMessageCapsule, _: UITraitCollection) in
            capsule.updateMicImage()
            capsule.invalidateIntrinsicContentSize()
        }
        apply(content, palette: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The mic at the `body` size the capsule's own category gives it. A bar caps the
    /// category it hands its items, and the placeholder follows that cap; a symbol sized
    /// with `UIFont.scaled` and `.scaled(...)` configuration came out about twice the
    /// size the old SwiftUI capsule drew it at, beside the same text.
    private func updateMicImage() {
        let size = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection).pointSize
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular, scale: .default)
        micButton.setImage(UIImage(systemName: "mic", withConfiguration: configuration), for: .normal)
    }

    /// Draws `content`; a theme palette recolors the mic and placeholder. The capsule
    /// re-measures only when what it draws changes.
    func apply(_ content: Content, palette: ThemePalette?) {
        let changed = content != self.content
        self.content = content
        placeholderLabel.text = content.placeholder
        micButton.isHidden = !content.showsDictation
        accessibilityCustomActions = content.showsDictation ? [
            UIAccessibilityCustomAction(name: String(localized: "Dictate Quick Session")) { [weak self] _ in
                self?.onDictate()
                return true
            },
        ] : nil
        if let palette {
            placeholderLabel.textColor = UIColor(palette.fgDim)
            micButton.tintColor = UIColor(palette.fg)
        }
        if changed {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// The fixed width at compact width; nil when the capsule is as wide as its content.
    var fixedWidth: CGFloat? {
        SessionInboxComposeChrome.messageCapsuleMinWidth(
            screenWidth: content.columnWidth,
            expands: SessionInboxComposeChrome.expandsMessageCapsule(
                horizontalSizeClass: traitCollection.horizontalSizeClass,
                hasActivePlayback: content.hasActivePlayback
            ),
            reserve: content.trailingReserve
        )
    }

    private var leadingInset: CGFloat {
        content.showsDictation ? SessionInboxComposeChrome.compactBarMicWidth : Self.edgePadding
    }

    override var intrinsicContentSize: CGSize {
        let height = SessionInboxComposeChrome.compactBarHitHeight
        if let fixedWidth { return CGSize(width: fixedWidth, height: height) }
        let label = placeholderLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: height))
        return CGSize(width: leadingInset + ceil(label.width) + Self.edgePadding, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(x: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: isRTL ? bounds.width - x - width : x, y: 0, width: width, height: bounds.height)
        }
        micButton.frame = frame(x: 0, width: SessionInboxComposeChrome.compactBarMicWidth)
        let labelWidth = max(0, bounds.width - leadingInset - Self.edgePadding)
        placeholderLabel.frame = frame(x: leadingInset, width: labelWidth)
    }
}
