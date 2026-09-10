#if os(iOS)
@preconcurrency import AVFoundation
import Foundation

struct VoiceInputAudioRouteDataSource: Equatable {
    var name: String
    var orientation: AVAudioSession.Orientation?
    var supportedPolarPatterns: [AVAudioSession.PolarPattern]
}

struct VoiceInputAudioRouteInput: Equatable {
    var uid: String
    var portType: AVAudioSession.Port
    var dataSources: [VoiceInputAudioRouteDataSource]
}

struct VoiceInputAudioRoutePlan: Equatable {
    var category: AVAudioSession.Category
    var mode: AVAudioSession.Mode
    var options: AVAudioSession.CategoryOptions
    var preferredInputUID: String?
    var preferredDataSourceName: String?
    var preferredPolarPattern: AVAudioSession.PolarPattern?
}

enum VoiceInputAudioRoutePlanner {
    static func plan(
        availableInputs: [VoiceInputAudioRouteInput],
        bluetoothHighQualityRecordingAvailable: Bool
    ) -> VoiceInputAudioRoutePlan {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if bluetoothHighQualityRecordingAvailable {
            options.insert(.bluetoothHighQualityRecording)
        }

        // HFP, then wired headset, then built-in only when it is the sole port type.
        // Polar / data-source only for builtInMic. Front toward the user beats a
        // non-front cardioid (back cardioid aims away from the speaker).
        let preferredInput = availableInputs.first { $0.portType == .bluetoothHFP }
            ?? availableInputs.first { $0.portType == .headsetMic }
            ?? Self.builtInMicIfSolePort(in: availableInputs)

        var preferredDataSourceName: String?
        var preferredPolarPattern: AVAudioSession.PolarPattern?
        if preferredInput?.portType == .builtInMic, let input = preferredInput {
            if let frontCardioid = input.dataSources.first(where: {
                $0.orientation == .front && $0.supportedPolarPatterns.contains(.cardioid)
            }) {
                preferredDataSourceName = frontCardioid.name
                preferredPolarPattern = .cardioid
            } else if let front = input.dataSources.first(where: { $0.orientation == .front }) {
                preferredDataSourceName = front.name
            } else if let anyCardioid = input.dataSources.first(where: {
                $0.supportedPolarPatterns.contains(.cardioid)
            }) {
                preferredDataSourceName = anyCardioid.name
                preferredPolarPattern = .cardioid
            }
        }

        return VoiceInputAudioRoutePlan(
            category: .record,
            mode: .default,
            options: options,
            preferredInputUID: preferredInput?.uid,
            preferredDataSourceName: preferredDataSourceName,
            preferredPolarPattern: preferredPolarPattern
        )
    }

    private static func builtInMicIfSolePort(
        in availableInputs: [VoiceInputAudioRouteInput]
    ) -> VoiceInputAudioRouteInput? {
        guard !availableInputs.isEmpty,
              availableInputs.allSatisfy({ $0.portType == .builtInMic })
        else {
            return nil
        }
        return availableInputs.first
    }
}

extension VoiceInputAudioRouteInput {
    init(_ port: AVAudioSessionPortDescription) {
        self.init(
            uid: port.uid,
            portType: port.portType,
            dataSources: (port.dataSources ?? []).map(VoiceInputAudioRouteDataSource.init)
        )
    }
}

extension VoiceInputAudioRouteDataSource {
    init(_ source: AVAudioSessionDataSourceDescription) {
        self.init(
            name: source.dataSourceName,
            orientation: source.orientation,
            supportedPolarPatterns: source.supportedPolarPatterns ?? []
        )
    }
}
#endif
