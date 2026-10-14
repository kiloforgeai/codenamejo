// coverage-target: CodenameJo/Onboarding/LoopingVideoBackground.swift

import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import CodenameJo

/// The welcome screen's clip. `makeUIView` takes a representable context that cannot be
/// built outside SwiftUI, so what is checked here is everything around it: the backing
/// layer the gravity is set on, the resource lookup that decides whether a player is wired
/// at all, the coordinator that owns the player, and the teardown that stops it.
@MainActor
final class LoopingVideoBackgroundTests: XCTestCase {

    // MARK: - The backing layer

    /// `AVPlayerLayer` as the view's own layer is the whole reason this is a
    /// `UIViewRepresentable`: `videoGravity` is set on `playerLayer`, so if that were a
    /// sublayer the clip would letterbox instead of filling the screen.
    func testThePlayerLayerIsTheViewsOwnLayer() {
        let view = LoopingVideoBackground.PlayerView()
        XCTAssertTrue(view.layer is AVPlayerLayer)
        XCTAssertTrue(view.playerLayer === view.layer)
    }

    func testTheLayerClassIsDeclaredRatherThanAddedAtRuntime() {
        XCTAssertTrue(LoopingVideoBackground.PlayerView.layerClass === AVPlayerLayer.self)
    }

    /// Nothing is attached until `makeUIView` wires one, so a freshly made view is silent.
    func testAFreshPlayerViewHasNoPlayer() {
        XCTAssertNil(LoopingVideoBackground.PlayerView().playerLayer.player)
    }

    /// The gravity survives being set on the view's own layer — the one property the
    /// representable configures before it looks for the clip.
    func testTheFillGravitySticksToTheViewsLayer() {
        let view = LoopingVideoBackground.PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspectFill)
    }

    // MARK: - The clip

    /// `makeUIView` returns a player-less view when the resource is missing, so the name
    /// the welcome screen passes has to resolve in the shipped bundle or the screen is a
    /// blank rectangle with no error anywhere.
    func testTheWelcomeClipIsInTheBundleUnderTheNameTheScreenAsksFor() {
        XCTAssertNotNil(Bundle.main.url(forResource: "welcomeloop", withExtension: "mov"))
    }

    /// The default extension is what the one caller relies on; it passes a bare name.
    func testTheDefaultFileExtensionIsMov() {
        XCTAssertEqual(LoopingVideoBackground(resource: "welcomeloop").fileExtension, "mov")
    }

    func testAMissingClipIsLookedUpAsNilRatherThanGuessedAt() {
        XCTAssertNil(Bundle.main.url(forResource: "welcomeloop", withExtension: "mp4"))
        XCTAssertNil(Bundle.main.url(forResource: "no-such-clip", withExtension: "mov"))
    }

    // MARK: - The coordinator

    /// Two backgrounds on screen at once must not share a player: a coordinator per view
    /// is what keeps one screen's teardown from pausing another's clip.
    func testEachBackgroundGetsItsOwnCoordinator() {
        let background = LoopingVideoBackground(resource: "welcomeloop")
        XCTAssertFalse(background.makeCoordinator() === background.makeCoordinator())
    }

    func testAFreshCoordinatorOwnsNothing() {
        let coordinator = LoopingVideoBackground.Coordinator()
        XCTAssertNil(coordinator.player)
        XCTAssertNil(coordinator.looper)
    }

    /// The looper is what re-enqueues the item; `makeUIView` builds it and parks it on the
    /// coordinator, because nothing else holds it and a released looper plays once.
    func testTheCoordinatorCanHoldTheLooperAndThePlayerTogether() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "welcomeloop", withExtension: "mov"))
        let coordinator = LoopingVideoBackground.Coordinator()
        let queue = AVQueuePlayer()
        let looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        coordinator.player = queue
        coordinator.looper = looper

        XCTAssertTrue(coordinator.looper === looper)
        XCTAssertTrue(coordinator.player === queue)
        XCTAssertNotEqual(looper.status, .failed)
    }

    // MARK: - Teardown

    /// Leaving the screen pauses the clip. Driven through the static entry point SwiftUI
    /// calls, with the coordinator it would hand over.
    func testDismantlingPausesTheClip() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "welcomeloop", withExtension: "mov"))
        let coordinator = LoopingVideoBackground.Coordinator()
        let queue = AVQueuePlayer(items: [AVPlayerItem(url: url)])
        queue.isMuted = true
        coordinator.player = queue
        queue.play()
        XCTAssertNotEqual(queue.timeControlStatus, .paused,
                          "The fixture has to be running for a pause to mean anything")

        LoopingVideoBackground.dismantleUIView(
            LoopingVideoBackground.PlayerView(), coordinator: coordinator)
        XCTAssertEqual(queue.timeControlStatus, .paused)
        XCTAssertEqual(queue.rate, 0)
    }

    /// The teardown path for the case above where the resource was missing: there is no
    /// player, and `coordinator.player?.pause()` has to be the whole story.
    func testDismantlingAPlayerLessBackgroundIsHarmless() {
        let coordinator = LoopingVideoBackground.Coordinator()
        LoopingVideoBackground.dismantleUIView(
            LoopingVideoBackground.PlayerView(), coordinator: coordinator)
        XCTAssertNil(coordinator.player)
    }
}
