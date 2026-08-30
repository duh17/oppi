import Foundation

/// Preferred transport path selected for a server connection.
enum ConnectionTransportPath: String, Sendable, Equatable {
    case paired
    case lan
    /// Owner Unix socket used by the Mac live session window.
    case unix
}
