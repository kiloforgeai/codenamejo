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

final class DailyMailNotificationsTests: XCTestCase {
    func testMissingOrInvalidMinuteUsesNineAM() {
        XCTAssertEqual(
            DailyMailNotifications.resolvedMinuteOfDay(nil),
            9 * 60)
        XCTAssertEqual(
            DailyMailNotifications.resolvedMinuteOfDay(-1),
            9 * 60)
        XCTAssertEqual(
            DailyMailNotifications.resolvedMinuteOfDay(24 * 60),
            9 * 60)
    }

    func testPickerRoundTripUsesTheProvidedDeviceTimeZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let minute = 8 * 60 + 35
        let date = DailyMailNotifications.pickerDate(
            minuteOfDay: minute,
            timeZone: zone)

        XCTAssertEqual(
            DailyMailNotifications.minuteOfDay(from: date, timeZone: zone),
            minute)
    }

    func testMissingOrInvalidTimeZoneUsesTheDeviceTimeZone() throws {
        let current = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        XCTAssertEqual(
            DailyMailNotifications.resolvedTimeZoneIdentifier(nil, current: current),
            current.identifier)
        XCTAssertEqual(
            DailyMailNotifications.resolvedTimeZoneIdentifier("not/a-zone", current: current),
            current.identifier)
        XCTAssertEqual(
            DailyMailNotifications.resolvedTimeZoneIdentifier(
                "Europe/London", current: current),
            "Europe/London")
    }

    func testProfileEncodesTheBrokerScheduleContract() throws {
        var profile = UserProfile()
        profile.dailyMailNotifications = true
        profile.dailyMailNotificationMinuteOfDay = 17 * 60 + 45
        profile.dailyMailNotificationTimeZone = "America/Chicago"

        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["dailyMailNotifications"] as? Bool, true)
        XCTAssertEqual(json["dailyMailNotificationMinuteOfDay"] as? Int, 17 * 60 + 45)
        XCTAssertEqual(json["dailyMailNotificationTimeZone"] as? String, "America/Chicago")
    }
}
