import Foundation

/// Frame-rate and freeze policy for a visible orb.
enum OrbDisplayPolicy: Sendable {
    static let activeFramesPerSecond = 60
    static let constrainedFramesPerSecond = 30
    static let reduceMotionTime: Double = 0.6

    static func preferredFramesPerSecond(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Int {
        if isLowPowerModeEnabled { return constrainedFramesPerSecond }
        switch thermalState {
        case .serious, .critical:
            return constrainedFramesPerSecond
        default:
            return activeFramesPerSecond
        }
    }
}
