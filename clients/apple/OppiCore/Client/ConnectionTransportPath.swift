import Foundation

/// Preferred transport path selected for a server connection.
enum ConnectionTransportPath: String, Sendable, Equatable {
    case paired
    case lan
    /// The server's owner Unix socket (`~/.config/oppi/run/oppi.sock`). No
    /// shipping client connects through it today; telemetry keeps the value.
    case unix
}
