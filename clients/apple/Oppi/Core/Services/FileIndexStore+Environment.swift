import Foundation
import OSLog

private let fileIndexStoreLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "FileIndexStore")

extension APIClient: WorkspaceFileIndexFetching {}

extension FileIndexStoreEnvironment {
    static let app = FileIndexStoreEnvironment(
        loadCachedFileIndex: { workspaceId in
            await FileBrowserCache.shared.fileIndex(workspaceId: workspaceId)
        },
        cacheFileIndex: { paths, workspaceId in
            await FileBrowserCache.shared.cacheFileIndex(paths, workspaceId: workspaceId)
        },
        logDebug: { message in
            fileIndexStoreLogger.debug("\(message)")
        },
        logWarning: { message in
            fileIndexStoreLogger.warning("\(message)")
        }
    )
}
