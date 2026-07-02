import Foundation

enum MacSessionActionPolicy: Sendable {
    static func canStop(_ status: SessionStatus) -> Bool {
        switch status {
        case .starting, .ready, .busy:
            return true
        case .stopping, .stopped, .error:
            return false
        }
    }

    static func canDelete(_ status: SessionStatus) -> Bool {
        switch status {
        case .stopped, .error:
            return true
        case .starting, .ready, .busy, .stopping:
            return false
        }
    }
}
