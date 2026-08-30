enum SessionActionPolicy: Sendable {
    static func canStop(_ status: SessionStatus) -> Bool {
        switch status {
        case .starting, .ready, .busy:
            true
        case .stopping, .stopped, .error:
            false
        }
    }

    static func canDelete(_ status: SessionStatus) -> Bool {
        switch status {
        case .stopped, .error:
            true
        case .starting, .ready, .busy, .stopping:
            false
        }
    }
}
