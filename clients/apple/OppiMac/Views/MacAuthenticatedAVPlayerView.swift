import AVKit
import SwiftUI

/// `AVPlayerView` that plays a local/remote URL or an owner Unix-socket source.
///
/// Owner media never becomes an `http://127.0.0.1` URL. AVPlayer sees either a
/// file URL, a user-initiated remote URL without `sk_`, or `oppi-media://`.
struct MacAuthenticatedAVPlayerView: NSViewRepresentable {
    var playback: MacAVPlayback
    var controlsStyle: AVPlayerViewControlsStyle = .inline

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.videoGravity = .resizeAspect
        apply(playback, to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.controlsStyle = controlsStyle
        apply(playback, to: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.session?.teardown()
        coordinator.session = nil
        coordinator.identity = nil
    }

    private func apply(
        _ playback: MacAVPlayback,
        to view: AVPlayerView,
        coordinator: Coordinator
    ) {
        let identity = playback.identity
        guard coordinator.identity != identity || view.player == nil else { return }
        coordinator.identity = identity
        coordinator.session?.teardown()
        coordinator.session = nil
        view.player?.pause()
        switch playback {
        case .idle:
            view.player = AVPlayer()
        case .fileURL(let url):
            guard MacAVPlaybackURLPolicy.allows(url) else {
                view.player = AVPlayer()
                return
            }
            view.player = AVPlayer(url: url)
        case .ownerSocket(let source):
            let session = MacAuthenticatedMediaPlaybackSession(source: source)
            coordinator.session = session
            view.player = session.player
        }
    }

    final class Coordinator {
        var identity: String?
        var session: MacAuthenticatedMediaPlaybackSession?
    }
}
