import AVFoundation
import SwiftUI
import UIKit

/// A silent, auto-playing, full-bleed clip that cuts back to its first frame at the end.
/// `AVPlayerLayer`, since `VideoPlayer` adds transport controls and fits instead of fills.
struct LoopingVideoBackground: UIViewRepresentable {
    let resource: String
    var fileExtension = "mov"

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else {
            return view
        }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        // Keep the looper alive; it is what re-enqueues the item without a gap. The clip
        // runs to its end and cuts straight back to frame one — no reverse, no blend.
        context.coordinator.looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        context.coordinator.player = queue
        view.playerLayer.player = queue
        // Honour the system's video-autoplay switch; paused at zero still shows frame one.
        if UIAccessibility.isVideoAutoplayEnabled {
            queue.play()
        }
        context.coordinator.observeForeground()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// iOS pauses the player when the app backgrounds; nothing resumes it on return.
    @MainActor
    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        private var foreground: NSObjectProtocol?

        func observeForeground() {
            foreground = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard UIAccessibility.isVideoAutoplayEnabled else { return }
                    self?.player?.play()
                }
            }
        }

        deinit {
            if let foreground { NotificationCenter.default.removeObserver(foreground) }
        }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
