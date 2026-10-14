// coverage-target: CodenameJo/Views/SpeechIndicator.swift

import SwiftUI
import XCTest
@testable import CodenameJo

/// The level meter on the voice screen. It sits in a column above the orb, so the one
/// thing it must never do is resize: a meter whose row grew with loudness would push the
/// orb around while someone is talking into it. Everything below drives the published
/// level the view reads — including the values the gate and the clip exist for — and
/// measures the row it asks for.
///
/// Levels are set directly on a `VoiceMetering` rather than captured from a microphone;
/// nothing here starts a call or an audio session.
@MainActor
final class SpeechIndicatorRowTests: XCTestCase {

    private func metering(mic: Double = 0, capture: Double = 0) -> VoiceMetering {
        let metering = VoiceMetering()
        metering.levels.mic = mic
        metering.levels.capture = capture
        return metering
    }

    private func size(_ metering: VoiceMetering, width: CGFloat = 320) -> CGSize {
        UIHostingController(rootView: SpeechIndicator(metering: metering).frame(width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    // MARK: - The row does not move

    /// A silent room: the thread is a hairline, and the row is already its full height.
    func testASilentRoomStillAsksForTheWholeRow() {
        let silent = size(metering())
        XCTAssertGreaterThan(silent.height, 0,
                             "A meter that vanishes in silence reads as a meter that died")
    }

    /// The gate's own boundary. 0.05 is the noise floor; a level under it is the room.
    func testTheRowIsTheSameHeightUnderTheNoiseFloorAsAtSilence() {
        XCTAssertEqual(size(metering(mic: 0.049)).height, size(metering()).height, accuracy: 0.5)
    }

    /// Full excursion, and past it. Speech reaches well beyond `fullScale`, which clips
    /// rather than extends — so a shout cannot make the row taller either.
    func testLoudSpeechDoesNotChangeTheRowsHeight() {
        let silent = size(metering()).height
        for level in [0.05, 0.2, 0.45, 0.85, 1.0, 4.0] {
            XCTAssertEqual(size(metering(mic: level)).height, silent, accuracy: 0.5,
                           "A level of \(level) resized the row")
        }
    }

    /// A publisher that reports a negative level is reporting nonsense, and the gate's
    /// `max(_, 0)` is what keeps a curve out of it. The row has to survive it unchanged.
    func testANegativeLevelIsTreatedAsSilenceRatherThanDrawnAsOne() {
        XCTAssertEqual(size(metering(mic: -1)).height, size(metering()).height, accuracy: 0.5)
    }

    // MARK: - Which number it reads

    /// `heard` prefers WebRTC's own track level and falls back to the capture tap, which is
    /// the only number there is for most of the dial. Either source has to produce the
    /// same row.
    func testTheCaptureTapAndTheTrackLevelProduceTheSameRow() {
        XCTAssertEqual(size(metering(capture: 0.6)).height,
                       size(metering(mic: 0.6)).height, accuracy: 0.5)
    }

    /// `mic > 0` wins outright: once the call is up, the capture tap is not consulted and
    /// a stale tap reading cannot override the track.
    func testTheTrackLevelWinsOverTheCaptureTapOnceTheCallIsUp() {
        let levels = AudioLevels(mic: 0.3, capture: 0.9)
        XCTAssertEqual(levels.heard, 0.3, accuracy: 0.0001)
        XCTAssertEqual(size(metering(mic: 0.3, capture: 0.9)).height,
                       size(metering(mic: 0.3)).height, accuracy: 0.5)
    }

    // MARK: - Width

    /// It fills whatever column it is given — the thread spans the row from the first
    /// frame rather than growing in from the left.
    func testTheThreadFillsTheWidthItIsGiven() {
        XCTAssertEqual(size(metering(mic: 0.5), width: 200).width, 200, accuracy: 0.5)
        XCTAssertEqual(size(metering(mic: 0.5), width: 360).width, 360, accuracy: 0.5)
    }

    /// A column narrow enough to be a sliver is still a row, not a crash: the curve is
    /// built from a fixed point count whatever the step between them works out at.
    func testAVeryNarrowColumnStillDrawsARow() {
        let narrow = size(metering(mic: 0.5), width: 1)
        XCTAssertEqual(narrow.height, size(metering(mic: 0.5)).height, accuracy: 0.5)
    }

    /// Re-rendering after a level change leaves the row where it was. This is the case the
    /// invariant is actually about: the publisher ticks ten times a second for the length
    /// of a call, and every tick re-runs the body.
    func testAStreamOfLevelsNeverMovesTheRow() {
        let metering = VoiceMetering()
        let host = UIHostingController(rootView: SpeechIndicator(metering: metering))
        let proposal = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        let first = host.sizeThatFits(in: proposal).height
        for level in [0.0, 0.9, 0.02, 0.45, 0.7, 0.0] {
            metering.levels.mic = level
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            XCTAssertEqual(host.sizeThatFits(in: proposal).height, first, accuracy: 0.5)
        }
    }
}
