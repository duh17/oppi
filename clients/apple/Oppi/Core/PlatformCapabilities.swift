/// What this build of the app can do where it runs: the one owner of the
/// differences between the iOS app and its Mac Catalyst build.
///
/// Code asks here instead of testing the platform.
enum PlatformCapabilities {
    #if targetEnvironment(macCatalyst)
    private static let isMacCatalyst = true
    #else
    private static let isMacCatalyst = false
    #endif

    /// The app's folders under `~/Library` are shared with every other app.
    /// The Mac build is not sandboxed (it ships with Developer ID and will run
    /// the server), so its Library is the user's own, not a container.
    static let sharesUserLibrary = isMacCatalyst
}
