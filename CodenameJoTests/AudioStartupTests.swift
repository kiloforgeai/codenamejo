import XCTest
@testable import CodenameJo

final class AudioStartupTests: XCTestCase {
    @MainActor
    func testTeardownDoesNotConsumeAnotherOwnersActivation() async {
        let rtc = RTCAudioSession.sharedInstance()
        let count = rtc.activationCount
        let audio = FullDuplexAudioSession(mode: .voiceChat)
        let released = expectation(description: "Both route releases finished")
        released.expectedFulfillmentCount = 2
        audio.deactivate { released.fulfill() }
        audio.deactivate { released.fulfill() }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(rtc.activationCount, count)
    }

    func testQuietAndMutedBuffersStillProveCaptureStarted() {
        let meter = MicLevelTap()
        XCTAssertFalse(meter.hasCapturedAudio)
        meter.setMuted(true)
        meter.recordCapturePeak(0)
        XCTAssertTrue(meter.hasCapturedAudio)
        XCTAssertEqual(meter.level, 0)
        XCTAssertTrue(meter.hasCapturedAudio, "Reading the meter must not consume startup evidence")
        XCTAssertFalse(MicLevelTap().hasCapturedAudio, "A new dial needs its own capture evidence")
    }

    func testAudioUnitFailureReachesTheCallOnMainThread() async {
        let failure = expectation(description: "Audio failure surfaced")
        let observer = WebRTCSessionObserver(onSessionConfigured: {}, onFailure: { message in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(message.contains("dial again"))
            failure.fulfill()
        })
        observer.audioSession(RTCAudioSession.sharedInstance(),
                              audioUnitStartFailedWithError: NSError(domain: "test", code: -1))
        await fulfillment(of: [failure], timeout: 1)
    }

    func testActivationFailureIsSurfacedButDeactivationIsNot() async {
        let failure = expectation(description: "Only activation failure surfaced")
        failure.expectedFulfillmentCount = 1
        failure.assertForOverFulfill = true
        let observer = WebRTCSessionObserver(onSessionConfigured: {}, onFailure: { _ in
            failure.fulfill()
        })
        let error = NSError(domain: "test", code: -1)
        observer.audioSession(RTCAudioSession.sharedInstance(), failedToSetActive: false, error: error)
        observer.audioSession(RTCAudioSession.sharedInstance(), failedToSetActive: true, error: error)
        await fulfillment(of: [failure], timeout: 1)
    }
}
