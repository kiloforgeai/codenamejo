import XCTest
@testable import CodenameJo

final class LiveFarewellPlaybackTests: XCTestCase {
    func testAcknowledgmentAndSilenceCannotFinishTheFarewell() {
        var playback = LiveFarewellPlayback()
        playback.appendTranscript("Okay, I'll handle that.", at: 1)
        XCTAssertFalse(playback.observePlayback(0.2, at: 2))
        XCTAssertFalse(playback.observePlayback(0, at: 5))
    }

    func testWaitsForCompleteWordsAudioAndQuietTailAndOnlyFinishesOnce() {
        var playback = LiveFarewellPlayback()
        playback.appendTranscript("Goodbye,", at: 1)
        XCTAssertFalse(playback.observePlayback(0.2, at: 2))
        XCTAssertFalse(playback.observePlayback(0, at: 3))
        playback.appendTranscript(" take care.", at: 4)
        XCTAssertFalse(playback.observePlayback(0, at: 5), "Earlier audio is not the farewell")
        XCTAssertFalse(playback.observePlayback(0.2, at: 6))
        XCTAssertFalse(playback.observePlayback(0, at: 6.9), "A brief pause is not completion")
        XCTAssertTrue(playback.observePlayback(0, at: 7.3))
        XCTAssertFalse(playback.observePlayback(0, at: 8))
    }

    func testGeneratedWordsWithoutPlaybackDoNotFinish() {
        var playback = LiveFarewellPlayback()
        playback.appendTranscript("Goodbye, take care.", at: 1)
        XCTAssertFalse(playback.observePlayback(0, at: 20))
    }
}
