import SwiftUI

/// Chrome policy for leaving the workspace session list.
///
/// The workspace detail screen owns a bottom toolbar with the file browser,
/// skills, and policy controls. When a session row starts pushing `ChatView`,
/// hide that toolbar immediately from the source screen instead of waiting for
/// the destination's `.bottomBar` visibility to resolve after the push.
enum WorkspaceSessionNavigationChromePolicy {
    static func shouldHideBottomBar(isOpeningSession: Bool) -> Bool {
        isOpeningSession
    }

    static func bottomBarVisibility(isOpeningSession: Bool) -> Visibility {
        shouldHideBottomBar(isOpeningSession: isOpeningSession) ? .hidden : .automatic
    }
}
