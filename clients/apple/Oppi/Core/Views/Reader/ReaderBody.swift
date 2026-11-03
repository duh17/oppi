import UIKit

/// A full-screen reader body: the view `FullScreenCodeContent.makeFullScreenBody`
/// builds and `FullScreenCodeViewController` installs under its chrome. Each
/// requirement answers a question the controller asks of two or more bodies; the
/// extension below gives every other body the empty answer, so the controller
/// never casts to a concrete body to ask it.
@MainActor
protocol ReaderBody: UIView {
    /// Viewing Options (text size, wrapping, spacing), applied in place.
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences)

    /// The reading position the reader hands back when it leaves or rebuilds the
    /// body (Markdown, live Markdown). Nil when the body keeps none, or when a
    /// restore it was given has not settled, so offset 0 is never read as `.top`.
    var viewportIntent: FullScreenMarkdownViewportIntent? { get }

    /// Scrolls to `intent`. False when the body keeps no reading position, so the
    /// reader holds the intent for a later body.
    @discardableResult
    func restoreViewport(_ intent: FullScreenMarkdownViewportIntent) -> Bool

    /// What Copy copies when the body, not the content, owns the text: a book
    /// chapter changes under the reader, so its content's text would be stale.
    var liveCopyText: String? { get }

    /// What the reader's Pick menu and Comment button act on (HTML elements,
    /// Mermaid objects).
    var picker: (any ReaderPicking)? { get }

    /// Whether Annotate can draw over this body (HTML, LaTeX, Mermaid).
    var annotateAvailability: ReaderAnnotateAvailability { get }

    /// The rendered view as an image for Annotate. Throws
    /// `PaperMarkupCanvasSession.SnapshotError.notReady` until there is one.
    func renderedSnapshot() async throws -> UIImage
}

enum ReaderAnnotateAvailability: Equatable {
    /// Text bodies: no Annotate control.
    case unavailable
    /// The rendered view is still loading: Annotate shows, disabled.
    case loading
    case ready
}

extension ReaderBody {
    var liveCopyText: String? { nil }

    var viewportIntent: FullScreenMarkdownViewportIntent? { nil }

    @discardableResult
    func restoreViewport(_ intent: FullScreenMarkdownViewportIntent) -> Bool { false }

    var picker: (any ReaderPicking)? { nil }

    var annotateAvailability: ReaderAnnotateAvailability { .unavailable }

    func renderedSnapshot() async throws -> UIImage {
        throw PaperMarkupCanvasSession.SnapshotError.notReady
    }
}

/// Picks a target inside a rendered body for a comment, driven by the reader's
/// floating Pick and Comment controls instead of the picker's own chrome.
@MainActor
protocol ReaderPicking: AnyObject {
    /// True while the reader's floating controls stand in for the picker's own.
    var usesExternalPickControls: Bool { get set }
    /// Called with (picking, has selection) whenever either changes, and when
    /// what can be picked changes (a page finishing its load, a diagram's layout).
    var onPickStateChange: ((Bool, Bool) -> Void)? { get set }
    var onSelectionGeometryChange: (() -> Void)? { get set }
    var hasSelection: Bool { get }
    /// The selected target's frame in `view`, or nil when it is off screen.
    func selectedTargetRect(in view: UIView) -> CGRect?
    /// The Pick menu: enter or leave pick mode, then the picker's own refinements.
    /// Empty when nothing can be picked, which disables the Pick control.
    func pickMenuActions() -> [UIAction]
    func commentOnSelection()
}

extension ReaderPicking {
    /// The Pick menu's first action: Browse while picking, else `pickTitle`.
    func pickModeAction(isPicking: Bool, pickTitle: String, toggle: @escaping @MainActor () -> Void) -> UIAction {
        UIAction(
            title: isPicking ? "Browse" : pickTitle,
            image: UIImage(systemName: isPicking ? "hand.draw" : "cursorarrow.rays")
        ) { _ in toggle() }
    }
}
