@preconcurrency import AVFoundation
import Foundation
import Speech

@MainActor
protocol VoiceInputSystemAccessing {
    var hasPermissions: Bool { get }
    var hasMicPermission: Bool { get }
    func requestPermissions() async -> Bool
    func requestMicPermission() async -> Bool
    func activateAudioSession() throws
    func deactivateAudioSession()
}

@MainActor
struct VoiceInputSystemAccess: VoiceInputSystemAccessing {
    static let live = Self()

    #if os(iOS)
    static let recordingCategory: AVAudioSession.Category = .record
    static let recordingMode: AVAudioSession.Mode = .default
    static let recordingCategoryOptions: AVAudioSession.CategoryOptions = [
        .allowBluetoothHFP,
    ]
    #endif

    var hasPermissions: Bool {
        let mic = AVAudioApplication.shared.recordPermission == .granted
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        return mic && speech
    }

    var hasMicPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func requestPermissions() async -> Bool {
        let mic = await Self.requestMicPermission()
        guard mic else { return false }

        let speech = await Self.requestSpeechPermission()
        return speech
    }

    func requestMicPermission() async -> Bool {
        await Self.requestMicPermission()
    }

    func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            Self.recordingCategory,
            mode: Self.recordingMode,
            options: Self.recordingCategoryOptions
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try Self.preferBluetoothHandsFreeInputIfAvailable(session)
        #endif
    }

    func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    private static func preferBluetoothHandsFreeInputIfAvailable(_ session: AVAudioSession) throws {
        guard let bluetoothInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
            return
        }
        try session.setPreferredInput(bluetoothInput)
    }

    nonisolated private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
