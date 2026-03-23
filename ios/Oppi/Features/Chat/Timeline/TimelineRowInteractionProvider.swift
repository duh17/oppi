import UIKit

/// Protocol for timeline row content views that support double-tap copy
/// and context menu interactions.
///
/// Provides default implementations for:
/// - Assembling a Copy + Fork context menu from capabilities
/// - Performing copy with haptic + flash feedback
/// - Installing gesture recognizers and context menu delegate
///
/// Rows with custom interaction behavior (e.g. thinking row's full-screen
/// double-tap) can adopt the protocol selectively or override specific
/// computed properties.
@MainActor
protocol TimelineRowInteractionProvider: AnyObject {
    /// The primary text to copy. Return `nil` to disable copy.
    var copyableText: String? { get }

    /// The view to flash for copy feedback (typically the bubble container).
    var interactionFeedbackView: UIView { get }

    /// Whether this row supports the "Fork from here" action.
    var supportsFork: Bool { get }

    /// Closure invoked when the user taps "Fork from here".
    var forkAction: (() -> Void)? { get }

    /// Extra menu actions appended after Copy and Fork.
    var additionalMenuActions: [UIAction] { get }
}

// MARK: - Default Implementations

extension TimelineRowInteractionProvider {
    var supportsFork: Bool { false }
    var forkAction: (() -> Void)? { nil }
    var additionalMenuActions: [UIAction] { [] }

    /// Copy `copyableText` to the pasteboard with haptic + flash feedback.
    func performCopy() {
        guard let text = copyableText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TimelineCopyFeedback.copy(
            text,
            feedbackView: interactionFeedbackView,
            trimWhitespaceAndNewlines: true
        )
    }

    /// Build a context menu from the row's declared capabilities.
    ///
    /// Returns `nil` when no actions are available, which tells UIKit
    /// to skip the menu presentation entirely.
    func buildContextMenu() -> UIMenu? {
        var actions: [UIMenuElement] = []

        if let text = copyableText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actions.append(
                UIAction(
                    title: String(localized: "Copy"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in
                    self?.performCopy()
                }
            )
        }

        if supportsFork, let onFork = forkAction {
            actions.append(
                UIAction(
                    title: String(localized: "Fork from here"),
                    image: UIImage(systemName: "arrow.triangle.branch")
                ) { _ in
                    onFork()
                }
            )
        }

        actions.append(contentsOf: additionalMenuActions)

        guard !actions.isEmpty else { return nil }
        return UIMenu(title: "", children: actions)
    }
}

// MARK: - Interaction Handlers

/// Retains the target objects for gesture recognizers and context menu
/// interactions installed by `TimelineRowInteractionInstaller`.
struct TimelineRowInteractionHandlers {
    let doubleTapHandler: TimelineRowDoubleTapHandler
    let contextMenuHandler: TimelineRowContextMenuHandler
    let gesture: UITapGestureRecognizer
}

/// Target for the double-tap gesture. Must be an `NSObject` so UIKit
/// can dispatch the `@objc` action through target-action.
@MainActor
final class TimelineRowDoubleTapHandler: NSObject {
    weak var provider: (any TimelineRowInteractionProvider)?

    @objc func handleDoubleTap() {
        provider?.performCopy()
    }
}

/// Standalone `UIContextMenuInteractionDelegate` that reads the menu
/// from the provider's `buildContextMenu()`.
@MainActor
final class TimelineRowContextMenuHandler: NSObject, UIContextMenuInteractionDelegate {
    weak var provider: (any TimelineRowInteractionProvider)?

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = provider?.buildContextMenu() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}

// MARK: - Installation Helper

enum TimelineRowInteractionInstaller {
    /// Install double-tap copy gesture and context menu interaction on the
    /// given view, wired to the provider.
    ///
    /// The caller must retain the returned `TimelineRowInteractionHandlers`
    /// for the lifetime of the view — the handlers are weak-referenced by
    /// the gesture/interaction.
    @MainActor
    static func install(
        on view: UIView,
        provider: any TimelineRowInteractionProvider,
        cancelsTouchesInView: Bool = false
    ) -> TimelineRowInteractionHandlers {
        let doubleTapHandler = TimelineRowDoubleTapHandler()
        doubleTapHandler.provider = provider

        let gesture = DoubleTapCopyGesture.makeGesture(
            target: doubleTapHandler,
            action: #selector(TimelineRowDoubleTapHandler.handleDoubleTap),
            cancelsTouchesInView: cancelsTouchesInView
        )
        view.addGestureRecognizer(gesture)

        let contextMenuHandler = TimelineRowContextMenuHandler()
        contextMenuHandler.provider = provider
        view.addInteraction(UIContextMenuInteraction(delegate: contextMenuHandler))

        return TimelineRowInteractionHandlers(
            doubleTapHandler: doubleTapHandler,
            contextMenuHandler: contextMenuHandler,
            gesture: gesture
        )
    }
}
