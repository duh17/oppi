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
}
