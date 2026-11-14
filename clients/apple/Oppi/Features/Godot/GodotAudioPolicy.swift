import AVFoundation
import Observation
import UIKit

/// The game's sound (design §9). Godot sets up the audio session in its own
/// app delegate, which never runs inside Oppi, so this owns the game's part
/// of the app's one session:
///
/// - The game plays as ambient sound: it mixes with other apps' audio, and
///   the Ring/Silent switch silences it. The session takes that category
///   when the game starts, when the app returns to the foreground, after an
///   interruption ends, and when the microphone is released, but never while
///   another of Oppi's owners holds it: dictation and Live Voice (the
///   microphone) or read-aloud playback. Those set their own categories, and
///   Live Voice's session belongs to CallKit.
/// - The game is silent while the person muted it, and while the microphone
///   is held, so it never plays into a recording.
@MainActor
final class GodotAudioPolicy {
    /// Called with the new answer whenever `isMuted` changes.
    var onChange: ((Bool) -> Void)?

    var personMuted = false {
        didSet { update() }
    }

    private(set) var isMuted = false
    /// A game runs: the session is the game's to claim when free.
    private var gameRuns = false
    private let voice: VoiceInputManager
    private var observers: [NSObjectProtocol] = []

    init(voice: VoiceInputManager = .shared) {
        self.voice = voice
        observe()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
                MainActor.assumeIsolated { if ended { self?.claimSession() } }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimSession() }
            },
        ]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Pure: whether the game is silent.
    static func isMuted(personMuted: Bool, microphoneHeld: Bool) -> Bool {
        personMuted || microphoneHeld
    }

    /// The engine opened its audio output.
    func gameDidStart() {
        gameRuns = true
        claimSession()
    }

    /// Ambient and active, unless one of Oppi's other audio owners holds the session.
    private func claimSession() {
        guard gameRuns, !microphoneHeld, !AudioPlayerService.isProcessPlaybackActiveForCapture else { return }
        let session = AVAudioSession.sharedInstance()
        if session.category != .ambient { try? session.setCategory(.ambient) }
        try? session.setActive(true)
    }

    private var microphoneHeld: Bool {
        voice.ownsCaptureAudioSession || voice.liveVoiceCalls?.ownsMicrophone == true
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        let held = microphoneHeld
        let muted = Self.isMuted(personMuted: personMuted, microphoneHeld: held)
        guard muted != isMuted else { return }
        isMuted = muted
        onChange?(muted)
        // The microphone came free: the session is the game's again.
        if !held { claimSession() }
    }
}
