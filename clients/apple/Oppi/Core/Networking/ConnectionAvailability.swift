/// What a connection is doing while it has no API client: whether an attempt is
/// on its way by itself, or whether nothing brings a client back without the
/// person. The words a screen shows for it live with the screen's states
/// (`LoadStateContent.swift`): this is the connection's fact, not its copy.
enum ConnectionAvailability: Equatable {
    /// An attempt is on its way now or on a timer: a route rebuild between its
    /// teardown and its commit, a setup pass running, or a failure that waits
    /// retry.
    case reconnecting
    /// Nothing is coming without the person: a terminal answer, a failure only a
    /// boundary or a Retry restarts, or no server behind the connection at all.
    case offline
}
