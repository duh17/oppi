import Foundation

/// The app's own folders in Application Support and Caches.
///
/// iOS gives the app a container, so the system folders already belong to Oppi
/// alone. The Mac build is not sandboxed (`PlatformCapabilities.sharesUserLibrary`):
/// its Application Support and Caches are the user's, shared with every other
/// app, so Oppi keeps its files in a folder named for its bundle identifier
/// inside each, as Mac apps do. A store that needs one of these folders asks
/// here rather than writing beside other apps' files.
enum AppLibrary {
    static func applicationSupport(fileManager: FileManager = .default) -> URL {
        folder(
            in: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            sharesUserLibrary: PlatformCapabilities.sharesUserLibrary,
            bundleIdentifier: AppIdentifiers.subsystem
        )
    }

    static func caches(fileManager: FileManager = .default) -> URL {
        folder(
            in: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            sharesUserLibrary: PlatformCapabilities.sharesUserLibrary,
            bundleIdentifier: AppIdentifiers.subsystem
        )
    }

    /// `base` itself in a container; Oppi's folder inside it in a shared Library.
    static func folder(in base: URL, sharesUserLibrary: Bool, bundleIdentifier: String) -> URL {
        sharesUserLibrary ? base.appending(path: bundleIdentifier, directoryHint: .isDirectory) : base
    }
}
