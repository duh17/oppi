import Foundation

/// Collision-safe owned copies of composer media that must outlive Photos
/// provider temp files and draft-sidecar clearance during send.
enum PendingComposerFileStore: Sendable {
    private static let directoryName = "PendingComposerFiles"

    nonisolated static func directoryURL(fileManager: FileManager = .default) throws -> URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: directoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try configureProtection(url, fileManager: fileManager)
        return url
    }

    /// Copy `sourceURL` into owned storage before a provider callback returns.
    nonisolated static func copyFile(
        from sourceURL: URL,
        displayName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try directoryURL(fileManager: fileManager)
        let uniqueName = "\(UUID().uuidString)-\(safeFileName(displayName))"
        let destination = directory.appending(path: uniqueName, directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try configureProtection(destination, fileManager: fileManager)
        return destination
    }

    nonisolated static func isOwned(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let ownedDirectory: URL
        do {
            ownedDirectory = try directoryURL(fileManager: fileManager)
        } catch {
            return false
        }
        let ownedPath = ownedDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == ownedPath || candidate.hasPrefix(ownedPath.hasSuffix("/") ? ownedPath : ownedPath + "/")
    }

    nonisolated static func remove(_ url: URL, fileManager: FileManager = .default) {
        guard isOwned(url, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: url)
    }

    nonisolated private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:").union(.newlines)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "attachment" : trimmed
    }

    nonisolated private static func configureProtection(_ url: URL, fileManager: FileManager) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)

        #if os(iOS)
        try fileManager.setAttributes(
            [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
