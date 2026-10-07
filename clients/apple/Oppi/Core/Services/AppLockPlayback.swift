import AVKit

/// Every live audio player and video controller, so App Lock can stop
/// playback from one place: spoken replies and video are session content.
///
/// Players register when created; entries are weak and drop out on release.
@MainActor
enum AppLockPlayback {
    private static let audioPlayers = NSHashTable<AudioPlayerService>.weakObjects()
    private static let videoControllers = NSHashTable<AVPlayerViewController>.weakObjects()

    static func register(_ player: AudioPlayerService) {
        audioPlayers.add(player)
    }

    /// Also applies the current Picture in Picture rule (off while App Lock is on).
    static func register(_ controller: AVPlayerViewController) {
        videoControllers.add(controller)
        applyPictureInPictureRule(to: controller, allowed: !AppLockService.shared.isEnabled)
    }

    /// App Lock locked, or a timed lock became due while playback kept Oppi
    /// running in the background.
    static func stopAll() {
        for player in audioPlayers.allObjects {
            player.stop()
        }
        for controller in videoControllers.allObjects {
            // AVKit has no public call to close a running Picture in Picture
            // window; pausing and disallowing it is the closest control.
            controller.player?.pause()
            applyPictureInPictureRule(to: controller, allowed: false)
        }
    }

    /// App Lock turned on.
    static func disablePictureInPicture() {
        for controller in videoControllers.allObjects {
            applyPictureInPictureRule(to: controller, allowed: false)
        }
    }

    private static func applyPictureInPictureRule(to controller: AVPlayerViewController, allowed: Bool) {
        controller.allowsPictureInPicturePlayback = allowed
        controller.canStartPictureInPictureAutomaticallyFromInline = allowed
    }
}
