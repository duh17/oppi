import AVFoundation
import MediaPlayer

/// Process-wide inputs that reach whichever player owns playback: lock-screen and
/// Control Center commands, and the system's own audio-session events.
extension AudioPlayerService {
    private static var remoteCommandTargetsInstalled = false
    private static var audioSessionObserversInstalled = false

    /// AVAudioSession is process-wide, so one observer pair serves whichever
    /// player owns playback. Installed for the process lifetime.
    static func installAudioSessionObserversIfNeeded() {
        guard !audioSessionObserversInstalled else { return }
        audioSessionObserversInstalled = true
        let center = NotificationCenter.default
        _ = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            MainActor.assumeIsolated {
                Self.activePlaybackOwner?.handleInterruption(type, options: options)
            }
        }
        _ = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            // Dictation's category and input switches arrive with other reasons
            // (VoiceInputManager relies on the same distinction); only a vanished
            // output pauses playback.
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                Self.activePlaybackOwner?.handleOutputRouteLost()
            }
        }
    }

    static func setRemoteSeekingEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
    }

    static func installRemoteCommandTargetsIfNeeded() {
        guard !remoteCommandTargetsInstalled else { return }
        remoteCommandTargetsInstalled = true

        let center = MPRemoteCommandCenter.shared()
        let stopHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in
            Task { @MainActor in
                Self.activePlaybackOwner?.stop()
            }
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.changePlaybackRateCommand.supportedPlaybackRates = AudioPlaybackRate.options.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor in
                Self.activePlaybackOwner?.setPlaybackRate(rate)
            }
            return .success
        }
        center.playCommand.addTarget { _ in
            Task { @MainActor in
                Self.activePlaybackOwner?.resume()
            }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in
                Self.activePlaybackOwner?.pause()
            }
            return .success
        }
        center.stopCommand.addTarget(handler: stopHandler)
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                guard let owner = Self.activePlaybackOwner else { return }
                if owner.isPaused {
                    owner.resume()
                } else {
                    owner.pause()
                }
            }
            return .success
        }
        center.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in
                Self.activePlaybackOwner?.skip(by: interval)
            }
            return .success
        }
        center.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in
                Self.activePlaybackOwner?.skip(by: -abs(interval))
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in
                guard let owner = Self.activePlaybackOwner,
                      let time = AudioPlaybackSeek.clampedTime(position, duration: owner.duration) else {
                    return
                }
                owner.seek(to: time)
            }
            return .success
        }
    }
}
