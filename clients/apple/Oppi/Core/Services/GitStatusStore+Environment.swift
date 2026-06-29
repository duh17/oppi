import Foundation
import OSLog

private let gitStatusStoreLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "GitStatusStore")

extension APIClient: WorkspaceGitStatusFetching {}

extension GitStatusStoreEnvironment {
    static let app = GitStatusStoreEnvironment(
        logWarning: { message in
            gitStatusStoreLogger.warning("\(message)")
        }
    )
}
