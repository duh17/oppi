@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "VoiceInput")

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
    static let recordingCategoryOptions: AVAudioSession.CategoryOptions = VoiceInputAudioRoutePlanner.plan(
        availableInputs: [],
        bluetoothHighQualityRecordingAvailable: {
            if #available(iOS 26.0, *) { true } else { false }
        }()
    ).options
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
        let bluetoothHighQualityRecordingAvailable: Bool
        if #available(iOS 26.0, *) {
            bluetoothHighQualityRecordingAvailable = true
        } else {
            bluetoothHighQualityRecordingAvailable = false
        }
        let plan = VoiceInputAudioRoutePlanner.plan(
            availableInputs: (session.availableInputs ?? []).map(VoiceInputAudioRouteInput.init),
            bluetoothHighQualityRecordingAvailable: bluetoothHighQualityRecordingAvailable
        )
        Self.apply(plan, to: session)
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

    #if os(iOS)
    // setPreferredInput after setCategory, mode, and setActive.
    // setPreferredPolarPattern, then setPreferredDataSource.
    private static func apply(_ plan: VoiceInputAudioRoutePlan, to session: AVAudioSession) {
        guard let uid = plan.preferredInputUID else { return }
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else {
            logger.warning("Preferred input \(uid, privacy: .public) is not in availableInputs")
            return
        }
        do {
            try session.setPreferredInput(port)
        } catch {
            logger.warning("setPreferredInput failed: \(error.localizedDescription, privacy: .public)")
        }

        guard let dataSourceName = plan.preferredDataSourceName else { return }
        let resolvedPort = session.preferredInput ?? port
        guard let dataSource = resolvedPort.dataSources?.first(where: {
            $0.dataSourceName == dataSourceName
        }) else {
            logger.warning(
                "Preferred data source \(dataSourceName, privacy: .public) is not available"
            )
            return
        }
        if let polar = plan.preferredPolarPattern {
            do {
                try dataSource.setPreferredPolarPattern(polar)
            } catch {
                logger.warning(
                    "setPreferredPolarPattern failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        do {
            try resolvedPort.setPreferredDataSource(dataSource)
        } catch {
            logger.warning(
                "setPreferredDataSource failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    #endif

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
