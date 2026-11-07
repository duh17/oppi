import UIKit

/// The one owner of "is this layout wide or compact?". Regular width means an
/// iPad, or the iPhone Duo's inner display; the Duo's idiom is `.phone`, so
/// `userInterfaceIdiom` is never a layout signal (`uikit-structure-guard`
/// counts both it and a raw `horizontalSizeClass ==` read outside this file).
///
/// Wide gets the trailing column for side panels (Files, Git, Outline,
/// Context, the reader), a full-window cover for document viewers, and the
/// larger chrome. Compact, including the Duo's cover display, keeps the sheet
/// or the push stack so a column never adapts into a second one. A rotation
/// must not turn an open column into a sheet, so a vertical toolbar rail does
/// not make a layout narrow.
///
/// Two questions stay elsewhere on purpose: the shell's split-or-stack choice
/// (`WorkspaceNavigationPresentation.resolve`, which also needs the vertical
/// class and the aspect ratio) and the Duo's vertical rail (`SystemVerticalBar`,
/// a bar placement, not a width).
enum AdaptiveWidth {
    /// This view's own layout and presentation choices. Inside a trailing
    /// column it is false: the column forces compact so a panel lays out like
    /// an inspector.
    static func isWide(_ traits: UITraitCollection) -> Bool {
        isWide(traits.horizontalSizeClass)
    }

    static func isWide(_ sizeClass: UIUserInterfaceSizeClass) -> Bool {
        sizeClass == .regular
    }

    /// System chrome that follows the window and ignores a trait override, such
    /// as the search bar's Cancel button. A panel inside a trailing column reads
    /// compact through `isWide` but sits in a wide window.
    @MainActor
    static func windowIsWide(_ view: UIView) -> Bool {
        isWide(view.window?.windowScene?.traitCollection ?? view.window?.traitCollection ?? view.traitCollection)
    }
}
