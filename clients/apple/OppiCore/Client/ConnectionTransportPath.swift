import Foundation

/// Preferred transport path selected for a server connection.
enum ConnectionTransportPath: String, Sendable, Equatable {
    case paired
    case lan
}
