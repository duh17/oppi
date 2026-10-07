import Foundation
import OSLog

private let fileIndexStoreLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "FileIndexStore")

extension APIClient: WorkspaceFileIndexFetching {}

extension FileIndexStoreEnvironment {
    /// `serverId` resolves the owning server when a read or write happens. With no
    /// server (for example, a connection that was torn down) nothing is read or written.
    static func app(
        serverId: @escaping @MainActor @Sendable () -> String?,
        cache: FileBrowserCache = .shared
    ) -> FileIndexStoreEnvironment {
        FileIndexStoreEnvironment(
            loadCachedFileIndex: { workspaceId in
                guard let serverId = await serverId() else { return nil }
                return await cache.fileIndex(workspaceId: workspaceId, serverId: serverId)
            },
            cacheFileIndex: { paths, workspaceId in
                guard let serverId = await serverId() else { return }
                await cache.cacheFileIndex(paths, workspaceId: workspaceId, serverId: serverId)
            },
            logDebug: { message in
                fileIndexStoreLogger.debug("\(message)")
            },
            logWarning: { message in
                fileIndexStoreLogger.warning("\(message)")
            }
        )
    }
}
