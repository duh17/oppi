import Foundation

/// Read and write seams for one document. The live adapter calls
/// `GET`/`PUT /files/current` with the owner's origin (`workspace`, `skill`, or
/// `pi`); a record's prompt has its own route. Tests supply scripted closures.
struct WorkspaceFileEditTransport: Sendable {
    var read: @Sendable (WorkspaceFileEditIdentity) async -> WorkspaceFileReadOutcome
    var write: @Sendable (
        WorkspaceFileEditIdentity,
        Data,
        WorkspaceFileWriteCondition
    ) async -> WorkspaceFileWriteOutcome
}

extension WorkspaceFileEditTransport {
    static func api(_ api: APIClient) -> WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { identity in
                await api.readFileForEditingOutcome(identity)
            },
            write: { identity, bytes, condition in
                await api.writeEditedFile(identity, bytes: bytes, condition: condition)
            }
        )
    }
}
