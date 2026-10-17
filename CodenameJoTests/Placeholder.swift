// Prefire generates snapshot tests at CI time — this file is a placeholder so
// the test target has something to compile before PreviewTests.swift exists.
import AVFoundation
import XCTest
@testable import CodenameJo

final class AutomaticAudioRoutingTests: XCTestCase {
    func testBuiltInRouteUsesSpeakerFarAndReceiverNear() {
        XCTAssertTrue(AudioRoute.shouldForceBuiltInSpeaker(
            outputs: [.builtInSpeaker], isHeldToEar: false))
        XCTAssertFalse(AudioRoute.shouldForceBuiltInSpeaker(
            outputs: [.builtInSpeaker], isHeldToEar: true))
    }

    func testConnectedAccessoryAlwaysWins() {
        XCTAssertFalse(AudioRoute.shouldForceBuiltInSpeaker(
            outputs: [.bluetoothHFP], isHeldToEar: false))
        XCTAssertFalse(AudioRoute.shouldForceBuiltInSpeaker(
            outputs: [.bluetoothHFP], isHeldToEar: true))
    }

    func testWebRTCConfigurationLeavesReceiverAvailable() {
        XCTAssertFalse(FullDuplexAudioSession.webRTCCategoryOptions.contains(.defaultToSpeaker))
        XCTAssertEqual(FullDuplexTuning.voiceMode, .voiceChat)
    }
}
