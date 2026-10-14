import XCTest
@testable import CodenameJo

// coverage-target: CodenameJo/Services/FullDuplex/ConnectCue.swift

/// The numbers `FullDuplexVoiceClient` and `DialTiming` read off `ConnectCue`. Only the
/// derived constants are exercised — building an instance would stand an `AVAudioEngine`
/// up, which is the audio path and not a unit test's business.
@MainActor
final class ConnectCueTimingTests: XCTestCase {

    /// The mic is held deaf for the cue plus the slack after it, and nothing else. If the
    /// window ever stopped covering the cue, server VAD would hear the cue as the user.
    func testTheDeafWindowIsExactlyTheCuePlusItsTail() {
        XCTAssertEqual(ConnectCue.micDeafWindow, ConnectCue.duration + ConnectCue.tail)
        XCTAssertEqual(ConnectCue.tail, .milliseconds(150))
        XCTAssertGreaterThan(ConnectCue.micDeafWindow, ConnectCue.duration)
    }

    /// `DialTiming` adds this to a figure measured before the window opens, so it has to
    /// be the same 750 ms the `Duration` above describes — derived, not a third copy.
    func testTheMillisecondFormIsTheSameWindow() {
        let components = ConnectCue.micDeafWindow.components
        let expected = Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000

        XCTAssertEqual(ConnectCue.micDeafWindowMs, expected, accuracy: 0.000_001)
        // 0.60 s + 150 ms, to within the rounding a `Duration` built from a `Double`
        // carries — the value is attosecond-exact, not decimally exact.
        XCTAssertEqual(ConnectCue.micDeafWindowMs, 750, accuracy: 0.001)
    }

    /// The end cue is the same instrument inverted: the same two offsets, the frequencies
    /// the other way round. A second interval or a different length would be a second
    /// sound to learn.
    func testTheEndCueInvertsTheConnectCue() {
        let rising = ConnectCue.risingFifth
        let falling = ConnectCue.fallingFifth

        XCTAssertEqual(rising.count, 2)
        XCTAssertEqual(falling.count, rising.count)
        XCTAssertEqual(rising.map(\.at), falling.map(\.at))
        XCTAssertEqual(falling.map(\.frequency), rising.map(\.frequency).reversed())
        XCTAssertLessThan(rising[0].frequency, rising[1].frequency, "a rise opens")
        XCTAssertGreaterThan(falling[0].frequency, falling[1].frequency, "a fall closes")
        // Both notes start inside the rendered cue, which is what makes it a one-shot
        // that always plays to completion.
        let length = Double(ConnectCue.duration.components.seconds)
            + Double(ConnectCue.duration.components.attoseconds) / 1e18
        XCTAssertTrue(rising.allSatisfy { $0.at >= 0 && $0.at < length })
    }
}
