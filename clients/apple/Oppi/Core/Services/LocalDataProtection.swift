import Foundation
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "DataProtection")

/// At-rest policy for everything the iOS app stores on disk.
///
/// iOS encrypts every file with its own key; the Data Protection class decides
/// when that key is usable. Oppi uses Class B (`completeUnlessOpen`): existing
/// files cannot be opened while the device is locked, but the app can still
/// create new files after lock, which background audio and agent keep-alive
/// need. Keychain items are separately `WhenUnlockedThisDeviceOnly`.
///
/// The `com.apple.developer.default-data-protection` entitlement applies this
/// class to new files. Builds before that entitlement left files at the system
/// default, Class C, which stays readable from first unlock until reboot, so a
/// one-time pass upgrades what is already on disk. It never weakens a class.
///
/// The pass walks only Oppi's own folders (`storageRoots`). On iOS those are
/// the app's container. The Mac build is not sandboxed, so its Application
/// Support, Caches and temporary folder are the user's, shared with every other
/// app: there the pass walks Oppi's folders inside them (`AppLibrary`) and the
/// app group, and never the shared folders themselves.
enum LocalDataProtection {
    static let fileProtection = FileProtectionType.completeUnlessOpen

    /// Bump when `fileProtection` gets stronger so stored files are upgraded again.
    private static let upgradeGeneration = 1
    private static let upgradeGenerationKey = "localDataProtectionUpgradeGeneration"

    private struct UpgradeResult {
        var checked = 0
        var upgraded = 0
        var failed = 0
    }

    /// Runs off the main actor. A pass with failures is retried next launch.
    @MainActor
    static func upgradeStoredFilesIfNeeded() {
        guard UserDefaults.standard.integer(forKey: upgradeGenerationKey) < upgradeGeneration else { return }

        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let layout = StorageLayout.current(fileManager: fileManager)
            let result = upgradeFiles(
                under: storageRoots(layout),
                excluding: excludedPaths(appGroup: layout.appGroup),
                fileManager: fileManager
            )
            logger.notice(
                "Data protection upgrade checked=\(result.checked, privacy: .public) upgraded=\(result.upgraded, privacy: .public) failed=\(result.failed, privacy: .public)"
            )
            guard result.failed == 0 else { return }
            await MainActor.run {
                UserDefaults.standard.set(upgradeGeneration, forKey: upgradeGenerationKey)
            }
        }
    }

    /// The system folders the app was given, and whether they are its own.
    struct StorageLayout {
        /// The system's Application Support, Caches and temporary folders: the
        /// app's container on iOS, the user's on the unsandboxed Mac build.
        var applicationSupport: URL
        var caches: URL
        var temporary: URL
        var appGroup: URL?
        var bundleIdentifier: String
        /// `PlatformCapabilities.sharesUserLibrary`.
        var sharesUserLibrary: Bool

        static func current(fileManager: FileManager) -> Self {
            Self(
                applicationSupport: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                caches: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                temporary: fileManager.temporaryDirectory,
                appGroup: fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier),
                bundleIdentifier: AppIdentifiers.subsystem,
                sharesUserLibrary: PlatformCapabilities.sharesUserLibrary
            )
        }
    }

    /// The folders the pass walks. In a shared Library only Oppi's own folders
    /// count, and the temporary folder (`$TMPDIR`, every app's) not at all.
    static func storageRoots(_ layout: StorageLayout) -> [URL] {
        var roots = [layout.applicationSupport, layout.caches].map {
            AppLibrary.folder(in: $0, sharesUserLibrary: layout.sharesUserLibrary, bundleIdentifier: layout.bundleIdentifier)
        }
        if !layout.sharesUserLibrary {
            roots.append(layout.temporary)
        }
        if let group = layout.appGroup {
            roots.append(group)
        }
        return roots
    }

    /// Upgrades each root and everything below it, skipping symlinks and the
    /// excluded directories' subtrees.
    private static func upgradeFiles(
        under roots: [URL],
        excluding excluded: Set<String>,
        fileManager: FileManager
    ) -> UpgradeResult {
        var result = UpgradeResult()
        let enumerationFailures = walk(roots, excluding: excluded, fileManager: fileManager) { path in
            upgradeItem(atPath: path, fileManager: fileManager, result: &result)
        }
        result.failed += enumerationFailures
        return result
    }

    /// Calls `visit` with each root and every path below it, without entering
    /// the excluded directories or following a symlink. Returns the number of
    /// failures enumeration reported, and a root it could not enumerate.
    static func walk(
        _ roots: [URL],
        excluding excluded: Set<String>,
        fileManager: FileManager,
        visit: (String) -> Void
    ) -> Int {
        var failures = 0
        for root in roots where fileManager.fileExists(atPath: root.path) {
            visit(root.path)
            var enumerationFailures = 0
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, error in
                    enumerationFailures += 1
                    logger.error("Data protection enumeration failed: \(error.localizedDescription, privacy: .public)")
                    return true
                }
            ) else {
                failures += 1
                continue
            }

            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                if excluded.contains(path) {
                    enumerator.skipDescendants()
                    continue
                }
                visit(path)
            }
            failures += enumerationFailures
        }
        return failures
    }

    /// Only unprotected, Class C, or unreported files move to the policy class.
    private static func needsUpgrade(_ current: FileProtectionType?) -> Bool {
        guard let current else { return true }
        return current != .complete && current != .completeUnlessOpen
    }

    private static func upgradeItem(atPath path: String, fileManager: FileManager, result: inout UpgradeResult) {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: path)
        } catch {
            if fileManager.fileExists(atPath: path) {
                result.failed += 1
                logger.error("Data protection attribute read failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return }
        result.checked += 1
        guard needsUpgrade(attributes[.protectionKey] as? FileProtectionType) else { return }
        do {
            try fileManager.setAttributes([.protectionKey: fileProtection], ofItemAtPath: path)
            result.upgraded += 1
        } catch {
            // A store may replace or prune the file during the pass; only a
            // file that still exists counts as a failure.
            guard fileManager.fileExists(atPath: path) else { return }
            result.failed += 1
            logger.error("Data protection upgrade failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shared `UserDefaults` plists belong to cfprefsd, not to Oppi's stores. Push state stays
    /// `completeUntilFirstUserAuthentication` by design: the Notification Service Extension
    /// opens it while the phone is locked (`PushSharedStore`).
    static func excludedPaths(appGroup: URL?) -> Set<String> {
        guard let group = appGroup else { return [] }
        return [
            group.appending(path: "Library/Preferences", directoryHint: .isDirectory).standardizedFileURL.path,
            group.appending(path: PushSharedStore.stateDirectoryName, directoryHint: .isDirectory).standardizedFileURL.path,
        ]
    }
}
