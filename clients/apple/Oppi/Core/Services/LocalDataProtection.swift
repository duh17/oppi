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
            let result = upgradeFiles(
                under: storageRoots(fileManager: fileManager),
                excluding: excludedPaths(fileManager: fileManager),
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

    /// Upgrades each root and everything below it, skipping symlinks and the
    /// excluded directories' subtrees.
    private static func upgradeFiles(
        under roots: [URL],
        excluding excluded: Set<String>,
        fileManager: FileManager
    ) -> UpgradeResult {
        var result = UpgradeResult()
        for root in roots where fileManager.fileExists(atPath: root.path) {
            upgradeItem(atPath: root.path, fileManager: fileManager, result: &result)
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
                result.failed += 1
                continue
            }

            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                if excluded.contains(path) {
                    enumerator.skipDescendants()
                    continue
                }
                upgradeItem(atPath: path, fileManager: fileManager, result: &result)
            }
            result.failed += enumerationFailures
        }
        return result
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

    private static func storageRoots(fileManager: FileManager) -> [URL] {
        var roots = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fileManager.temporaryDirectory,
        ].compactMap { $0 }
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier) {
            roots.append(group)
        }
        return roots
    }

    /// Shared `UserDefaults` plists belong to cfprefsd, not to Oppi's stores.
    private static func excludedPaths(fileManager: FileManager) -> Set<String> {
        guard let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier) else {
            return []
        }
        return [group.appending(path: "Library/Preferences", directoryHint: .isDirectory).standardizedFileURL.path]
    }
}
