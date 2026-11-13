import CoreGraphics

/// What this build of the app can do where it runs: the one owner of the
/// differences between the iOS app and its Mac Catalyst build.
///
/// Code asks here instead of testing the platform. `targetEnvironment(macCatalyst)`
/// and `isMacCatalystApp` appear only in this file and in the few files that
/// must hide an iOS-only API from the Catalyst compiler, each named with its
/// reason in `scripts/uikit-structure-guard.ts`. `userInterfaceIdiom` is never
/// a layout signal (`AdaptiveWidth`).
enum PlatformCapabilities {
    #if targetEnvironment(macCatalyst)
    private static let isMacCatalyst = true
    #else
    private static let isMacCatalyst = false
    #endif

    /// Live Activities. The SDK the app builds with marks ActivityKit's
    /// `Activity` unavailable on Mac Catalyst; Apple lists it for Catalyst
    /// 27.3, which is still in beta.
    static let liveActivities = !isMacCatalyst

    /// Oppi's own Tailscale node. TailscaleKit has no Catalyst build, and a Mac
    /// reaches its tailnet through the Tailscale app, so a Tailscale name
    /// resolves and connects like any other host there.
    static let inAppTailnet = !isMacCatalyst

    /// The app's folders under `~/Library` are shared with every other app.
    /// The Mac build is not sandboxed (it ships with Developer ID and will run
    /// the server), so its Library is the user's own, not a container.
    static let sharesUserLibrary = isMacCatalyst

    /// Telemetry names this build's client kind `mac` and reads the machine's
    /// model from `hw.model`; on the Mac `hw.machine` names only the CPU
    /// (`arm64`). Uploads from the Mac then never mix with the iPad's.
    static let reportsAsMac = isMacCatalyst

    /// The smallest window: the sidebar's minimum (320 pt, `WorkspaceShellController`)
    /// beside one chat pane at its minimum (375 pt, `PaneMinimumSize.chat`); a
    /// companion beside it needs a wider window, else it opens over the chat
    /// (`PaneWidthPolicy.fitsBeside`). nil where the system
    /// sizes the window: the iPhone, and iPad windowing keeps its own limits.
    static let minimumWindowSize: CGSize? = isMacCatalyst ? CGSize(width: 700, height: 500) : nil

    /// The most pane leaves a window keeps live at once; more go to overflow
    /// (`PanePresentation.resolve`). The iPad mini holds four within its
    /// memory budget; on the Mac the window's width binds first.
    static let livePaneLimit = isMacCatalyst ? 8 : 4
}
