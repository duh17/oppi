import Darwin
import Foundation

/// OS advisory `flock` serialization for paired-server credential
/// read-modify-write across processes (main app vs. share extension vs. App
/// Intents). A process-local `NSLock` cannot serialize separate processes.
///
/// The lock file lives in a caller-supplied container directory: the shared
/// app-group container in production, a shared temp directory in two-process
/// tests. The lock is per-server so unrelated servers do not contend.
///
/// `flock` is associated with the open file description, so two independent
/// `open()` calls — including two calls in the same process — contend correctly.
enum CrossProcessFileLock {
    enum LockError: LocalizedError {
        case appGroupUnavailable
        case openFailed
        case acquireFailed

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "The shared app-group container is unavailable"
            case .openFailed:
                return "Could not open the credential lock file"
            case .acquireFailed:
                return "Could not acquire the cross-process credential lock"
            }
        }
    }

    static func lockURL(serverId: String, container: URL) -> URL {
        container
            .appendingPathComponent(".oppi-credential-locks", isDirectory: true)
            .appendingPathComponent("\(serverId).lock")
    }

    static func appGroupContainer(identifier: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw LockError.appGroupUnavailable
        }
        return container
    }

    /// Run `body` while holding an exclusive advisory lock for `serverId`.
    /// Fails closed if the lock cannot be acquired rather than proceeding
    /// unsynchronized.
    static func withLock<T>(
        serverId: String,
        container: URL,
        _ body: () throws -> T
    ) throws -> T {
        let url = lockURL(serverId: serverId, container: container)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw LockError.openFailed }
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            throw LockError.acquireFailed
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    /// Run `body` while holding an exclusive advisory lock on the file at `url`, in a
    /// directory that already exists, for state a process may need while the phone is locked.
    ///
    /// A new file inherits its directory's protection class, and a file whose class has
    /// been made stronger than `protection` cannot be opened again while the phone is locked.
    /// So the process that creates the lock file sets `protection` on it, and a process that
    /// opens one reporting another class sets it again. Either way the class changes in place:
    /// the file is never replaced, since a process holding the old file would no longer
    /// exclude one locking the new one.
    ///
    /// Throws `POSIXError` with the `open` or `flock` errno.
    static func withLock<T>(
        fileAt url: URL,
        protection: URLFileProtection,
        classes: FileClasses = .fileSystem,
        _ body: () throws -> T
    ) throws -> T {
        let fd = try openLockFile(at: url, protection: protection, classes: classes)
        guard flock(fd, LOCK_EX) == 0 else {
            let error = POSIXError.current
            close(fd)
            throw error
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    private static func openLockFile(at url: URL, protection: URLFileProtection, classes: FileClasses) throws -> Int32 {
        // Two tries: another process may create the file between the two opens.
        for _ in 0..<2 {
            let created = open(url.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
            if created >= 0 {
                classes.set(protection, url)
                return created
            }
            guard errno == EEXIST else { throw POSIXError.current }
            let existing = open(url.path, O_RDWR)
            if existing >= 0 {
                // Nil where the file system reports no class.
                if let current = classes.read(url), current != protection {
                    classes.set(protection, url)
                }
                return existing
            }
            guard errno == ENOENT else { throw POSIXError.current }
        }
        throw POSIXError(.ENOENT)
    }

    /// How the lock reads and sets a file's protection class. Tests substitute it: whether the
    /// Simulator lets a process weaken a class or open a Class B file depends on its keybag
    /// state, which a test cannot set.
    struct FileClasses {
        var read: (URL) -> URLFileProtection?
        var set: (URLFileProtection, URL) -> Void

        /// The class the file system reports now (past any cached resource value), and a best
        /// effort change through the documented way to change an existing file's class. That
        /// can fail while the phone is locked; the next open while unlocked sets it again.
        static var fileSystem: FileClasses {
            FileClasses(
                read: { url in
                    try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileProtectionKey]).fileProtection
                },
                set: { protection, url in
                    try? (url as NSURL).setResourceValue(protection, forKey: .fileProtectionKey)
                }
            )
        }
    }
}

private extension POSIXError {
    /// The error for the current `errno`.
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
