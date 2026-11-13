import UIKit

/// The static "agent is working" icon for every surface outside the chat
/// timeline: Thread strips, the workspace sidebar, extension panels (activity
/// rows, a widget pill, `working` surface icons), notebook calls, the
/// terminal's program status, and schedules. Only the chat timeline animates
/// working: the focused chat's working row and its jump-to-bottom button keep
/// `WorkingSpinnerUIView`. Session rows say "Working" in words instead.
///
/// One SF Symbol, `play.circle.fill`, in the theme's accent blue: the icon a
/// running activity row drew before surfaces shared a working mark. It never
/// animates, so Reduce Motion needs nothing more.
///
/// The view is as wide and tall as `textStyle`'s line, so it stands in for a
/// word on that line without changing the line's height, and the symbol
/// follows Dynamic Type. It is not an accessibility element; the element that
/// contains it speaks `spokenLabel`.
final class WorkingMarkView: UIImageView {
    /// What VoiceOver says for a working agent wherever this mark shows.
    static let spokenLabel = String(localized: "Working")
    /// The symbol drawn for working.
    nonisolated static let symbolName = "play.circle.fill"

    private let textStyle: UIFont.TextStyle

    /// The mark's side: the line height of its text style at this view's text size.
    var side: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection).lineHeight)
    }

    init(textStyle: UIFont.TextStyle) {
        self.textStyle = textStyle
        super.init(image: UIImage(systemName: Self.symbolName))
        preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: textStyle)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityLabel = Self.spokenLabel
        contentMode = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: side, height: side)
    }

    /// Draws in `palette`'s accent blue.
    func apply(palette: ThemePalette) {
        tintColor = palette.ui.blue
    }
}
