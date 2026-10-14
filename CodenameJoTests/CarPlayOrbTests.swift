// coverage-target: CodenameJo/CarPlay/CarPlayOrb.swift

import UIKit
import XCTest
@testable import CodenameJo

/// The car's bead, pre-rendered into an animated `UIImage` because `CPVoiceControlState`
/// takes frames rather than a view. Three properties are load-bearing and none of them
/// can be seen by looking at a head unit: the sequence ping-pongs so the loop has no
/// seam, it is a function of a fixed clock rather than of `Date` so two renders a moment
/// apart are the same animation, and a muted call must not keep a live call's motion.
@MainActor
final class CarPlayOrbTests: XCTestCase {

    private func image(
        state: SessionState = .listening,
        inCall: Bool = true,
        muted: Bool = false,
        style: UIUserInterfaceStyle = .dark
    ) throws -> UIImage {
        try XCTUnwrap(
            CarPlayOrb.animatedImage(state: state, inCall: inCall, muted: muted, style: style),
            "the car orb rendered nothing")
    }

    private func frames(_ image: UIImage) throws -> [UIImage] {
        try XCTUnwrap(image.images, "the car orb returned a still rather than a sequence")
    }

    /// Twenty distinct renders forward, then the same run backwards with both endpoints
    /// dropped so neither turnaround frame is held for two frame-times: 20 + 18.
    func testTheSequencePingPongsWithoutRepeatingItsEndpoints() throws {
        XCTAssertEqual(try frames(try image()).count, 38)
    }

    /// Two seconds of real motion, doubled by the reverse leg — inside the template's
    /// documented 0.3–5 s window, which the system enforces.
    func testTheVisibleLoopIsFourSeconds() throws {
        XCTAssertEqual(try image().duration, 4.0, accuracy: 0.001)
    }

    /// Two points under `CPVoiceControlState`'s 150-point maximum, so the car never
    /// rescales the bead.
    func testTheImageFitsTheCarTemplateWithoutRescaling() throws {
        let size = try image().size
        XCTAssertEqual(size.width, 148, accuracy: 0.5)
        XCTAssertEqual(size.height, 148, accuracy: 0.5)
        XCTAssertLessThan(size.width, 150)
    }

    /// The sequence starts at zero rather than at `Date`, so the same state asked for
    /// twice is the same animation and not two arbitrary slices of one.
    func testTheSameStateRendersTheSameAnimationTwice() throws {
        let first = try frames(try image())[0].pngData()
        let second = try frames(try image())[0].pngData()
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    /// If the frames were identical the ping-pong would be 38 copies of one bitmap and
    /// the car would show a still.
    func testTheSequenceActuallyMoves() throws {
        let sequence = try frames(try image())
        XCTAssertNotEqual(sequence[0].pngData(), sequence[10].pngData())
    }

    /// The near-still grey bead is what says the call cannot hear you. A muted call that
    /// kept the live gold motion would be the screen's worst lie.
    func testAMutedCallDoesNotLookLikeALiveOne() throws {
        let live = try frames(try image(muted: false))[0].pngData()
        let muted = try frames(try image(muted: true))[0].pngData()
        XCTAssertNotNil(live)
        XCTAssertNotEqual(live, muted)
    }

    /// `inCall` is passed through but the car's mood is decided by the session state and
    /// the mute flag alone — there is no finger on a car screen for `holding` to mean
    /// anything about. Pinning it here so a future "fix" that consults it is visible.
    func testWhetherACallIsUpDoesNotChangeTheCarBead() throws {
        let inCall = try frames(try image(inCall: true))[0].pngData()
        let outOfCall = try frames(try image(inCall: false))[0].pngData()
        XCTAssertEqual(inCall, outOfCall)
    }

    /// A head unit picks light or dark from the vehicle, not from the phone, so the
    /// appearance has to reach the render.
    func testTheCarsOwnAppearanceReachesTheRender() throws {
        let dark = try frames(try image(style: .dark))[0].pngData()
        let light = try frames(try image(style: .light))[0].pngData()
        XCTAssertNotNil(dark)
        XCTAssertNotEqual(dark, light)
    }
}
