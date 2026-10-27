import Foundation

/// Each event narrows `transport` to its own enum with the same three cases.
/// These mappings are exhaustive switches: a new `ConnectionTransportPath`
/// case fails to compile here instead of being recorded as `paired`.
extension ConnectionTransportPath {
    var commandTransport: AppCommand.Transport {
        switch self {
        case .paired: .paired
        case .lan: .lan
        case .unix: .unix
        }
    }

    var commandResolveLagTransport: AppCommandResolveLag.Transport {
        switch self {
        case .paired: .paired
        case .lan: .lan
        case .unix: .unix
        }
    }

    var queueSyncTransport: AppQueueSync.Transport {
        switch self {
        case .paired: .paired
        case .lan: .lan
        case .unix: .unix
        }
    }

    var messageQueueAckTransport: AppMessageQueueAck.Transport {
        switch self {
        case .paired: .paired
        case .lan: .lan
        case .unix: .unix
        }
    }
}

extension CommandMetricClassification.Outcome {
    var commandStatus: AppCommand.Status {
        switch self {
        case .ok: .ok
        case .cancelled: .cancelled
        case .error: .error
        }
    }

    var queueSyncStatus: AppQueueSync.Status {
        switch self {
        case .ok: .ok
        case .cancelled: .cancelled
        case .error: .error
        }
    }
}
